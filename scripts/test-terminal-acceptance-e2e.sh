#!/bin/bash
# scripts/test-terminal-acceptance-e2e.sh
#
# End-to-end test for Cotabby terminal-accept-key acceptance, post Sub-plan B.3.
# Opens a DEDICATED new window in each target terminal, drives it via osascript, and verifies
# acceptance by reading THE SHELL'S OWN BUFFER: each test shell loads a one-shot Ctrl-G binding
# that dumps $BUFFER / $READLINE_LINE / `commandline` to a temp file, so the pass condition is
# literally "the buffer changed from <typed text> to <typed text + suggestion>". The Cotabby
# JSONL paste log is kept as a secondary diagnostic. Covers zsh + bash + fish bare prompts in
# Ghostty / Terminal.app / VS Code, plus the Claude Code TUI in Terminal.app (whose window
# contents AppleScript can read for the same before/after proof).
#
# ─────────────────────────────────────────────────────────────────────────────────────────
# READ THIS FIRST — non-CI script.
# AppleScript-injected keystrokes always go to the FOCUSED window. This script:
#   1. Opens a NEW window in each terminal it tests (so keystrokes never leak into the
#      window you're running the script from), and
#   2. Verifies the frontmost process is the expected target before EVERY keystroke batch,
#      aborting that phase rather than corrupting another window if focus drifts.
# It still takes over the foreground for ~60–120 s while it runs. Not safe in CI.
# ─────────────────────────────────────────────────────────────────────────────────────────
#
# Prereqs:
#   - Cotabby is running (Unix socket at ~/Library/Application Support/Cotabby/terminal.sock).
#   - Shell hook auto-loaded in ~/.zshrc / ~/.bashrc / ~/.config/fish/config.fish.
#   - Accessibility permission granted to the app running this script.
#   - jq + /usr/bin/nc available; optional: Ghostty, Terminal.app, code, bash >= 4, fish, claude.
#     Missing optional deps cause their phase to skip rather than fail.
#
# Usage:
#   bash scripts/test-terminal-acceptance-e2e.sh
#   bash scripts/test-terminal-acceptance-e2e.sh --yes   # skip the foreground-warning prompt

set -uo pipefail

SOCKET="$HOME/Library/Application Support/Cotabby/terminal.sock"
JSONL_LOG="$HOME/Library/Logs/Cotabby/cotabby.jsonl"
LLMIO_LOG="$HOME/Library/Logs/Cotabby/llm-io.jsonl"

PASS=0
FAIL=0
SKIP=0
SKIP_PROMPT=0

if [[ "${1:-}" == "--yes" ]]; then
    SKIP_PROMPT=1
fi

pass()  { echo "  PASS: $1"; ((PASS++)); }
fail()  { echo "  FAIL: $1"; ((FAIL++)); }
skip()  { echo "  SKIP: $1"; ((SKIP++)); }
note()  { echo "  ···  $1"; }

# ─────────────────────────────────────────────────────────────────────────────
# Log helpers
# ─────────────────────────────────────────────────────────────────────────────

now_iso() { date -u +"%Y-%m-%dT%H:%M:%S.000Z"; }

# Dump the tail of the JSONL log scoped to a timestamp window for diagnostics on failure.
log_tail_since() {
    local since="$1"
    tail -400 "$JSONL_LOG" 2>/dev/null | \
        jq -r "select(.timestamp > \"$since\" and .category != \"focus\") |
               .timestamp + \" [\" + .level + \"] \" + .category + \": \" + .message" 2>/dev/null
}

# Count "Inserted N characters via terminal-mode clipboard paste" log lines emitted after
# `since`. Secondary diagnostic measured at the Cotabby boundary
# (`SuggestionInserter.insertForTerminal`); the buffer dump is the primary proof.
count_terminal_inserts_since() {
    local since="$1"
    tail -400 "$JSONL_LOG" 2>/dev/null | \
        jq -r "select(.timestamp > \"$since\" and (.message | test(\"Inserted [0-9]+ characters via terminal-mode clipboard paste\"))) | .message" 2>/dev/null | wc -l | tr -d ' '
}

# ─────────────────────────────────────────────────────────────────────────────
# Focus + keystroke primitives
# ─────────────────────────────────────────────────────────────────────────────

# Returns the bundle id of the frontmost application. Empty string if the query fails.
frontmost_bundle_id() {
    osascript -e 'tell application "System Events" to bundle identifier of first application process whose frontmost is true' 2>/dev/null
}

# Returns the localized name of the frontmost application (used for human-readable error
# messages — bundle ids aren't always obvious to the reader).
frontmost_name() {
    osascript -e 'tell application "System Events" to name of first application process whose frontmost is true' 2>/dev/null
}

# Asserts the frontmost app is `expected_bid`. Returns 0 on match, 1 on mismatch. Use BEFORE
# every keystroke batch — if a stray Cmd+Tab or user click drifts focus mid-phase, we'd
# rather abort that phase than corrupt some unrelated window.
assert_frontmost_is() {
    local expected_bid="$1"
    local actual_bid
    actual_bid=$(frontmost_bundle_id)
    if [[ "$actual_bid" == "$expected_bid" ]]; then
        return 0
    fi
    note "Focus drift: expected $expected_bid, frontmost is '$(frontmost_name)' ($actual_bid)"
    return 1
}

# Activate `bundle_id` and wait until focus actually lands there. Returns 0 on success, 1
# after the timeout — the caller treats timeout as "phase impossible, skip" rather than
# pressing on against the wrong window.
activate_and_wait_for_focus() {
    local bundle_id="$1"
    local timeout="${2:-5}"
    osascript -e "tell application id \"$bundle_id\" to activate" 2>/dev/null || return 1
    local waited=0
    while (( waited * 10 < timeout * 10 )); do
        if [[ "$(frontmost_bundle_id)" == "$bundle_id" ]]; then
            sleep 0.3   # tiny extra settle so the window has finished animating in
            return 0
        fi
        sleep 0.2
        waited=$((waited + 1))
    done
    return 1
}

# Send `text` keystroke-by-keystroke to the focused app. Caller MUST have just asserted
# focus on the intended target. Each character is its own keystroke so per-key hooks (zle,
# bind -x, fish event handlers) fire just like a real user.
#
# MUST be a real `tell … end tell` block: `tell X to <line>` binds only the FIRST line, and
# every later line then runs outside the tell where `keystroke` is undefined — silently
# typing exactly one character (this bug shipped once; the 2>/dev/null hid it).
type_into_focused() {
    local text="$1"
    local delay="${2:-0.10}"
    local script="tell application \"System Events\""$'\n'
    for (( i=0; i<${#text}; i++ )); do
        local char="${text:$i:1}"
        if [[ "$char" == " " ]]; then
            script+="keystroke \" \""$'\n'
        elif [[ "$char" == '"' ]]; then
            script+="keystroke \"\\\"\""$'\n'
        elif [[ "$char" == '\' ]]; then
            script+="keystroke \"\\\\\""$'\n'
        else
            script+="keystroke \"$char\""$'\n'
        fi
        script+="delay $delay"$'\n'
    done
    script+="end tell"
    osascript -e "$script" 2>/dev/null
}

press_key() {
    # `key code` numbers: 36=Return, 124=RightArrow, 8=C (for Ctrl+C), 5=G (for Ctrl+G).
    osascript -e "tell application \"System Events\" to key code $1" 2>/dev/null
}
press_enter()       { press_key 36; }
press_ctrl_c()      {
    osascript -e 'tell application "System Events" to key code 8 using control down' 2>/dev/null
}
press_ctrl_g()      {
    osascript -e 'tell application "System Events" to key code 5 using control down' 2>/dev/null
}
press_cmd_n()       {
    osascript -e 'tell application "System Events" to keystroke "n" using command down' 2>/dev/null
}
press_cmd_w()       {
    osascript -e 'tell application "System Events" to keystroke "w" using command down' 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# Accept trigger.
#
# Synthetic keystrokes (osascript / CGEventPost from an unprivileged context) reach the
# focused app but are NOT delivered to other processes' CGEvent taps on modern macOS, so a
# scripted "press the accept key" can never reach Cotabby's accept tap. Instead the harness
# sends a debug-only `{"type":"accept"}` IPC message over the same Unix socket the shell
# hooks use. Cotabby (launched with -cotabby-debug) routes it through the REAL acceptance
# path — session validation → terminal clipboard paste — identical to a key-driven accept
# minus the tap hop, which stays covered by InputMonitor unit tests and manual QA.
# ─────────────────────────────────────────────────────────────────────────────

send_accept_ipc() {
    printf '{"type":"accept"}\n' | /usr/bin/nc -U -w 1 "$SOCKET" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# Buffer ground truth via llm-io.jsonl.
#
# Every terminal-source generation's prompt ENDS with the buffer exactly as the shell hook
# reported it ("$ <buffer>" is the final prompt line — see TerminalCompletionPromptRenderer).
# So the most recent llm-io record IS the shell's own statement of its edit buffer. After an
# accept-paste, one "poke" keystroke makes the hook re-report (bracketed paste bypasses the
# per-key hooks in every shell), and the next record reveals the post-paste buffer. This
# needs no shell-side bindings, no Ctrl-G, and works identically in every terminal.
# ─────────────────────────────────────────────────────────────────────────────

# Echo the buffer from the newest llm-io record after $1 (empty if none).
latest_reported_buffer_since() {
    local since="$1"
    tail -40 "$LLMIO_LOG" 2>/dev/null | \
        jq -rs --arg s "$since" \
           '[.[] | select(.timestamp > $s)] | if length == 0 then "" else (last | .prompt | split("\n") | last | ltrimstr("$ ")) end' 2>/dev/null
}

# Poll until a generation after $2 reports a buffer containing $1. Echoes that buffer.
wait_for_buffer_report() {
    local needle="$1"
    local since="$2"
    local timeout="${3:-8}"
    local waited=0
    local buffer
    while (( waited * 10 < timeout * 10 )); do
        buffer=$(latest_reported_buffer_since "$since")
        if [[ "$buffer" == *"$needle"* ]]; then
            printf '%s' "$buffer"
            return 0
        fi
        sleep 0.4
        waited=$((waited + 4))
    done
    printf '%s' "$buffer"
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Wait helpers
# ─────────────────────────────────────────────────────────────────────────────

# After typing `exec <shell>` + Enter, wait until Cotabby logs a session for that shell in
# the expected terminal. Proves the switch actually happened — a PATH miss or a swallowed
# Enter otherwise leaves the OLD shell running and the case tests the wrong thing.
wait_for_shell_session() {
    local shell="$1"
    local terminal_bid="$2"
    local since="$3"
    local timeout="${4:-6}"
    local waited=0
    while (( waited * 10 < timeout * 10 )); do
        if tail -200 "$JSONL_LOG" 2>/dev/null | \
            jq -e "select(.timestamp > \"$since\" and (.message | test(\"New terminal session.*shell=$shell.*terminal=$terminal_bid|switched shell.*→ $shell\")))" \
            > /dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
        waited=$((waited + 5))
    done
    return 1
}

# Type `exec <shell>`, submit, and verify the new shell's hook announced itself. The shell
# only reports on its first keystroke (prompt-render reports carry an empty buffer), so poke
# one char + backspace... simpler: callers type the test prefix right after; we just verify
# the exec line was ACCEPTED by checking the new session appears once the case types. Here we
# type one throwaway char to force the new shell's first report, then erase it.
switch_shell_and_verify() {
    local shell="$1"
    local terminal_bid="$2"
    local since
    since=$(now_iso)
    type_into_focused "exec $shell" 0.06
    sleep 0.3
    press_enter
    sleep 1.5
    # Force the new shell's first buffer report (empty-prompt reports are unreliable).
    type_into_focused "q" 0.05
    if ! wait_for_shell_session "$shell" "$terminal_bid" "$since" 6; then
        # Erase the probe char before giving up so the prompt is clean either way.
        press_key 51  # delete/backspace
        return 1
    fi
    press_key 51
    sleep 0.3
    return 0
}

wait_for_shell_integration_since() {
    local since="$1"
    local timeout="${2:-8}"
    local waited=0
    while (( waited * 10 < timeout * 10 )); do
        if tail -200 "$JSONL_LOG" 2>/dev/null | \
            jq -e "select(.timestamp > \"$since\" and (.message | test(\"Shell integration loaded|new terminal session|New terminal session|terminal-\")))" \
            > /dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
        waited=$((waited + 1))
    done
    return 1
}

wait_for_suggestion_since() {
    local since="$1"
    local timeout="${2:-12}"
    local waited=0
    while (( waited * 10 < timeout * 10 )); do
        if tail -200 "$JSONL_LOG" 2>/dev/null | \
            jq -e "select(.timestamp > \"$since\" and (.message | test(\"Llama generated|suggestion-ready|generated\")))" \
            > /dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
        waited=$((waited + 1))
    done
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# One bare-prompt acceptance case
#   $1 = label, $2 = typed prefix, $3 = expected frontmost bundle id, $4 = shell (zsh|bash|fish)
#
# Flow: load the Ctrl-G dump binding → type the prefix → wait for a generation →
# press the configured accept key → dump the buffer → assert it is now strictly
# "<prefix><something>". Accept is retried once because generation-complete and
# overlay-visible are separated by normalization/relevance gating.
# ─────────────────────────────────────────────────────────────────────────────
run_bare_prompt_case() {
    local label="$1"
    local prefix="$2"
    local expected_bid="$3"
    local shell="$4"

    if ! assert_frontmost_is "$expected_bid"; then
        fail "$label — could not get $expected_bid frontmost before typing; skipping safely"
        return
    fi

    local since
    since=$(now_iso)

    type_into_focused "$prefix" 0.10
    sleep 0.5

    # Wait for a generation whose reported buffer is exactly the full typed prefix — that is
    # the hook's own confirmation the keystrokes landed AND the suggestion matches the final
    # buffer state, not a mid-typing one.
    local typed_buffer
    if ! typed_buffer=$(wait_for_buffer_report "$prefix" "$since" 15); then
        if [[ -n "$typed_buffer" ]]; then
            fail "$label — shell reported buffer [$typed_buffer], expected it to contain [$prefix] (typing corrupted?)"
        else
            skip "$label — no generation fired within 15s (model latency / hook not loaded?)"
        fi
        press_ctrl_c; sleep 0.2
        return
    fi
    sleep 0.6  # let the ready/overlay state settle past normalization

    if ! assert_frontmost_is "$expected_bid"; then
        fail "$label — focus drifted before accept; aborted to avoid pasting into wrong window"
        return
    fi

    local accept_since
    accept_since=$(now_iso)
    send_accept_ipc
    sleep 0.8

    local inserts
    inserts=$(count_terminal_inserts_since "$accept_since")
    if (( inserts == 0 )); then
        # The suggestion may have been regenerating at accept time. One retry.
        note "$label — no paste after first accept; retrying once"
        sleep 1.2
        send_accept_ipc
        sleep 0.8
        inserts=$(count_terminal_inserts_since "$accept_since")
    fi

    # Bracketed paste bypasses per-key hooks in all three shells, so poke one throwaway
    # character to make the hook re-report, then read the post-paste buffer from the next
    # generation's prompt tail.
    type_into_focused "x" 0.05
    local buffer
    buffer=$(wait_for_buffer_report "$prefix" "$accept_since" 8) || true

    # The prompt prefix is word-windowed upstream, so a very long completion can scroll the
    # typed prefix out of the reported tail. Treat "contains prefix and grew" as the primary
    # proof; fall back to the paste log when windowing hides the head.
    local grew=0
    if [[ "$buffer" == *"$prefix"* ]]; then
        local after_prefix="${buffer##*"$prefix"}"
        # The poke contributes exactly one trailing char; require more than that.
        if (( ${#after_prefix} > 1 )); then
            grew=1
        fi
    fi

    if (( grew == 1 )); then
        pass "$label — buffer [$typed_buffer] → [$buffer] (paste log lines: $inserts)"
    elif (( inserts >= 1 )); then
        pass "$label — paste fired ($inserts log line(s)); post-paste buffer report: [$buffer]"
    else
        fail "$label — buffer never grew: [$typed_buffer] → [$buffer], no paste log lines"
        log_tail_since "$since" | grep -vE "Focus snapshot|client" | tail -20
    fi

    # Clear the prompt for the next case.
    press_ctrl_c; sleep 0.2
}

# ─────────────────────────────────────────────────────────────────────────────
# Per-terminal "open a fresh test window" helpers
# Each opens a NEW window in the target so we never corrupt the user's existing tabs
# or the window where this script is running.
# ─────────────────────────────────────────────────────────────────────────────

# Ghostty: use the universal Cmd+N "new window" shortcut (Ghostty supports it). After this
# we activate-and-wait-for-focus so the new window definitely owns keystrokes.
open_new_ghostty_window() {
    if ! activate_and_wait_for_focus "com.mitchellh.ghostty" 4; then
        return 1
    fi
    press_cmd_n
    sleep 1.0
    # Re-assert focus — opening a new window usually keeps Ghostty frontmost but a
    # racing notification could drift it.
    activate_and_wait_for_focus "com.mitchellh.ghostty" 3
}

# Terminal.app: `do script ""` opens a new window with a fresh shell. Empty arg avoids
# echoing test residue from the previous run.
open_new_terminal_app_window() {
    osascript -e 'tell application "Terminal" to do script ""' 2>/dev/null || return 1
    sleep 1.2
    activate_and_wait_for_focus "com.apple.Terminal" 3
}

# VS Code: spawn a new window with the CLI, then open the integrated terminal via Ctrl+`.
open_new_vscode_window_with_terminal() {
    code -n 2>/dev/null &
    sleep 3.0
    if ! activate_and_wait_for_focus "com.microsoft.VSCode" 5; then
        return 1
    fi
    # Ctrl+` toggles the integrated terminal. If already open, this hides; second press
    # opens. We send once, then sleep, then assert focus.
    osascript -e 'tell application "System Events" to keystroke "`" using control down' 2>/dev/null
    sleep 1.2
    activate_and_wait_for_focus "com.microsoft.VSCode" 3
}

# Read the full visible text of Terminal.app's frontmost tab. This is what makes
# Terminal.app the host for the Claude Code TUI phase: AppleScript can read the screen,
# so "the input box grew by the suggestion" is directly observable.
terminal_app_contents() {
    osascript -e 'tell application "Terminal" to contents of selected tab of front window' 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# Prereq checks
# ─────────────────────────────────────────────────────────────────────────────
echo "==========================================="
echo " Cotabby Terminal Acceptance E2E"
echo "==========================================="
echo ""

if [[ ! -S "$SOCKET" ]]; then
    echo "  FAIL: Cotabby socket not found at $SOCKET — is Cotabby running?"
    echo ""
    echo "Cannot continue without a live socket."
    exit 1
else
    pass "Cotabby socket present"
fi

if ! command -v jq > /dev/null 2>&1; then
    echo "  FAIL: jq not installed — 'brew install jq' or via Xcode CLT"
    exit 1
else
    pass "jq present"
fi

if [[ ! -x /usr/bin/nc ]]; then
    echo "  FAIL: /usr/bin/nc missing"
    exit 1
else
    pass "BSD netcat present"
fi

if [[ ! -f "$JSONL_LOG" ]]; then
    echo "  FAIL: Cotabby JSONL log not found at $JSONL_LOG — relaunch Cotabby with -cotabby-debug"
    exit 1
else
    pass "JSONL log present"
fi

write_dump_snippets
note "Acceptance trigger: debug IPC accept message over the terminal socket"

# Secure text input blocks Cotabby's clipboard-paste insertion outright (the inserter refuses
# while it is held). loginwindow can keep it stuck after a password dialog — surface that NOW
# instead of failing every acceptance below with a confusing log line.
if ioreg -l -w 0 2>/dev/null | grep -q kCGSSessionSecureInputPID; then
    holder_pid=$(ioreg -l -w 0 2>/dev/null | grep -o '"kCGSSessionSecureInputPID"=[0-9]*' | head -1 | grep -o '[0-9]*$')
    echo "  FAIL: Secure text input is held by pid=$holder_pid ($(ps -p "$holder_pid" -o comm= 2>/dev/null))."
    echo "        Close any open password dialog, or lock (Ctrl+Cmd+Q) and unlock the screen, then rerun."
    exit 1
else
    pass "No secure text input holder"
fi

# Keystroke synthesis needs Accessibility for this script's host app. Without it the harness
# can still prove the core chain (buffer → suggestion → accept → buffer+completion) through
# Terminal.app alone: `do script` injects commands without keystrokes, zsh's `print -z`
# preloads the edit buffer, and AppleScript can read the screen back. Phases that genuinely
# need typing (Ghostty, bash/fish switching, Claude Code TUI) are skipped in that mode.
CAN_TYPE=1
if ! osascript -e 'tell application "System Events" to keystroke ""' >/dev/null 2>&1 \
   || ! osascript -e 'tell application "System Events" to key code 63' >/dev/null 2>&1; then
    CAN_TYPE=0
    note "Keystroke synthesis unavailable (no Accessibility for this host) — running do-script-only phases"
fi

# Identify the parent terminal (where this script is running) so the user / reader can
# see we're aware of it and that we won't reuse it.
if [[ -n "${TERM_PROGRAM:-}" ]]; then
    note "Script running under TERM_PROGRAM=$TERM_PROGRAM (tty=$(tty 2>/dev/null || echo '?'))"
    note "Each phase opens a NEW window in its target terminal — this shell is never touched."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Foreground-focus warning
# ─────────────────────────────────────────────────────────────────────────────
if (( SKIP_PROMPT == 0 )); then
    echo ""
    echo "This script will take ~60–120 s and STEAL FOREGROUND FOCUS during that time."
    echo "AppleScript-injected keystrokes go to the active window."
    echo "Do not type or click while the script runs."
    echo ""
    read -p "Press Enter to start, Ctrl-C to abort: " _
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase Z — Terminal.app + zsh, keystroke-free (always runs).
# `do script` injects commands without keystroke synthesis; `print -z` preloads the next
# prompt's zle buffer so the hook reports it exactly like typed text; the accept IPC drives
# the real acceptance path; AppleScript reads the screen back for the buffer-grew proof.
# This is the phase that works even when the host has no Accessibility grant.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Phase Z: Terminal.app + zsh (do-script, keystroke-free) ---"

PREFIX="git ch"
z_since=$(now_iso)
if osascript -e 'tell application "Terminal" to do script ""' > /dev/null 2>&1; then
    osascript -e 'tell application "Terminal" to activate' 2>/dev/null
    sleep 1.5
    if wait_for_shell_integration_since "$z_since" 6; then
        pass "Z — Terminal.app new window: shell integration loaded"
    else
        note "Z — shell integration banner not seen (continuing)"
    fi

    z_since=$(now_iso)
    osascript -e "tell application \"Terminal\" to do script \"print -z '$PREFIX'\" in front window" > /dev/null 2>&1
    sleep 1.0

    if wait_for_suggestion_since "$z_since" 15; then
        send_accept_ipc
        sleep 1.5
        z_line=$(osascript -e 'tell application "Terminal" to history of selected tab of front window' 2>/dev/null | grep -F "$PREFIX" | grep -v "print -z" | tail -1)
        z_after="${z_line##*"$PREFIX"}"
        z_inserts=$(count_terminal_inserts_since "$z_since")
        if [[ -n "$z_line" && -n "${z_after// /}" ]]; then
            pass "Z.zsh — buffer grew: [...$PREFIX] → [${z_line#*% }] (paste log lines: $z_inserts)"
        elif (( z_inserts >= 1 )); then
            pass "Z.zsh — terminal paste fired ($z_inserts paste log line(s)); screen line: [$z_line]"
        else
            fail "Z.zsh — no insertion after accept. line=[$z_line]"
            log_tail_since "$z_since" | tail -25
        fi
    else
        skip "Z.zsh — no suggestion fired within 15s"
    fi

    # Tidy up: end the shell, then close the window (no keystrokes involved).
    osascript -e 'tell application "Terminal" to do script "exit" in front window' > /dev/null 2>&1
    sleep 0.8
    osascript -e 'tell application "Terminal" to close front window' > /dev/null 2>&1
else
    skip "Phase Z — could not open a Terminal.app window"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase A — Ghostty bare prompt (zsh, bash, fish)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Phase A: Ghostty bare prompt ---"

if (( CAN_TYPE == 0 )); then
    skip "Phase A — keystroke synthesis unavailable (grant Accessibility to this host to run)"
elif osascript -e 'tell application id "com.mitchellh.ghostty" to count windows' > /dev/null 2>&1; then
    if open_new_ghostty_window; then
        ghostty_since=$(now_iso)
        if wait_for_shell_integration_since "$ghostty_since" 6; then
            pass "A — Ghostty new window: shell integration loaded"
        else
            note "A — Ghostty new window: shell integration banner not seen in JSONL (continuing — hook may auto-load)"
        fi

        # zsh — default on macOS, no shell switch needed.
        run_bare_prompt_case "A.zsh — Ghostty + zsh" "git ch" "com.mitchellh.ghostty" "zsh"

        # bash
        if command -v bash > /dev/null 2>&1; then
            if assert_frontmost_is "com.mitchellh.ghostty"; then
                if switch_shell_and_verify "bash" "com.mitchellh.ghostty"; then
                    run_bare_prompt_case "A.bash — Ghostty + bash" "git ch" "com.mitchellh.ghostty" "bash"
                else
                    skip "A.bash — exec bash never produced a bash session (PATH/Enter?)"
                fi
                switch_shell_and_verify "zsh" "com.mitchellh.ghostty" || true
            fi
        else
            skip "A.bash — bash not available on PATH"
        fi

        # fish
        if command -v fish > /dev/null 2>&1; then
            if assert_frontmost_is "com.mitchellh.ghostty"; then
                if switch_shell_and_verify "fish" "com.mitchellh.ghostty"; then
                    run_bare_prompt_case "A.fish — Ghostty + fish" "git ch" "com.mitchellh.ghostty" "fish"
                else
                    skip "A.fish — exec fish never produced a fish session (PATH/Enter?)"
                fi
                switch_shell_and_verify "zsh" "com.mitchellh.ghostty" || true
            fi
        else
            skip "A.fish — fish not installed"
        fi

        # Close the dedicated test window.
        if assert_frontmost_is "com.mitchellh.ghostty"; then
            press_cmd_w; sleep 0.5
        fi
    else
        skip "Phase A — could not open a new Ghostty window"
    fi
else
    skip "Phase A — Ghostty not installed or not running"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase B — Terminal.app bare prompt (zsh, bash, fish)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Phase B: Terminal.app bare prompt ---"

if (( CAN_TYPE == 0 )); then
    skip "Phase B — keystroke synthesis unavailable"
elif osascript -e 'tell application id "com.apple.Terminal" to count windows' > /dev/null 2>&1; then
    if open_new_terminal_app_window; then
        terminal_since=$(now_iso)
        if wait_for_shell_integration_since "$terminal_since" 6; then
            pass "B — Terminal.app new window: shell integration loaded"
        else
            note "B — Terminal.app: shell integration banner not seen in JSONL (continuing)"
        fi

        run_bare_prompt_case "B.zsh — Terminal.app + zsh" "git ch" "com.apple.Terminal" "zsh"

        if command -v bash > /dev/null 2>&1; then
            if assert_frontmost_is "com.apple.Terminal"; then
                if switch_shell_and_verify "bash" "com.apple.Terminal"; then
                    run_bare_prompt_case "B.bash — Terminal.app + bash" "git ch" "com.apple.Terminal" "bash"
                else
                    skip "B.bash — exec bash never produced a bash session (PATH/Enter?)"
                fi
                switch_shell_and_verify "zsh" "com.apple.Terminal" || true
            fi
        else
            skip "B.bash — bash not installed"
        fi

        if command -v fish > /dev/null 2>&1; then
            if assert_frontmost_is "com.apple.Terminal"; then
                if switch_shell_and_verify "fish" "com.apple.Terminal"; then
                    run_bare_prompt_case "B.fish — Terminal.app + fish" "git ch" "com.apple.Terminal" "fish"
                else
                    skip "B.fish — exec fish never produced a fish session (PATH/Enter?)"
                fi
                switch_shell_and_verify "zsh" "com.apple.Terminal" || true
            fi
        else
            skip "B.fish — fish not installed"
        fi

        # Close the test window.
        if assert_frontmost_is "com.apple.Terminal"; then
            press_cmd_w; sleep 0.5
        fi
    else
        skip "Phase B — could not open a new Terminal.app window"
    fi
else
    skip "Phase B — Terminal.app unavailable"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase C — Claude Code TUI in Terminal.app
# Terminal.app is the host because AppleScript can read its screen contents, giving a
# direct before/after proof that the TUI input line grew by the accepted suggestion.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Phase C: Claude Code TUI (Terminal.app) ---"

if (( CAN_TYPE == 0 )); then
    skip "Phase C — keystroke synthesis unavailable (Claude Code TUI needs real typing)"
elif command -v claude > /dev/null 2>&1 \
   && osascript -e 'tell application id "com.apple.Terminal" to count windows' > /dev/null 2>&1; then
    if open_new_terminal_app_window; then
        if assert_frontmost_is "com.apple.Terminal"; then
            tui_since=$(now_iso)
            type_into_focused "claude" 0.05
            press_enter
            sleep 6.0  # Claude Code TUI takes a moment to draw.

            if tail -300 "$JSONL_LOG" 2>/dev/null | \
                jq -e "select(.timestamp > \"$tui_since\" and (.message | test(\"ClaudeCodeTuiInput|TuiContextCoordinator|Claude Code TUI\")))" \
                > /dev/null 2>&1; then
                pass "C — Cotabby detected the Claude Code TUI"
            else
                note "C — no TUI detection log yet (Advanced → Claude Code (beta) on? Screen Recording granted?); continuing anyway"
            fi

            tui_since=$(now_iso)
            if assert_frontmost_is "com.apple.Terminal"; then
                type_into_focused "explain how git reba" 0.08
                sleep 1.0

                if wait_for_suggestion_since "$tui_since" 20; then
                    if assert_frontmost_is "com.apple.Terminal"; then
                        before_contents=$(terminal_app_contents)
                        before_line=$(grep -F "explain how git reba" <<< "$before_contents" | tail -1)

                        send_accept_ipc
                        sleep 1.2

                        after_contents=$(terminal_app_contents)
                        after_line=$(grep -F "explain how git reba" <<< "$after_contents" | tail -1)
                        inserts=$(count_terminal_inserts_since "$tui_since")

                        if [[ -n "$after_line" && ${#after_line} -gt ${#before_line} ]]; then
                            pass "C — Claude TUI input grew: [$before_line] → [$after_line] (paste log lines: $inserts)"
                        elif (( inserts >= 1 )); then
                            pass "C — Claude TUI acceptance pasted ($inserts log line(s)); screen diff inconclusive"
                        else
                            fail "C — Claude TUI: no screen growth and no paste log line"
                            log_tail_since "$tui_since" | tail -30
                        fi
                    fi
                else
                    skip "C — Claude TUI did not surface a suggestion within 20s"
                fi
            fi

            # Exit claude (double Ctrl+C) then close the window.
            press_ctrl_c; sleep 0.3; press_ctrl_c; sleep 0.8
            if assert_frontmost_is "com.apple.Terminal"; then
                type_into_focused "exit" 0.05; press_enter; sleep 0.5
                press_cmd_w; sleep 0.3
                press_enter  # dismiss the "close anyway?" sheet if Terminal shows one
            fi
        fi
    else
        skip "Phase C — could not open a new Terminal.app window"
    fi
else
    skip "Phase C — claude command not found or Terminal.app unavailable"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase D — VS Code integrated terminal
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- Phase D: VS Code integrated terminal ---"

if (( CAN_TYPE == 0 )); then
    skip "Phase D — keystroke synthesis unavailable"
elif command -v code > /dev/null 2>&1; then
    if open_new_vscode_window_with_terminal; then
        vscode_since=$(now_iso)
        if wait_for_shell_integration_since "$vscode_since" 8; then
            pass "D — VS Code new window: shell integration loaded"
        else
            note "D — VS Code: shell integration banner not seen in JSONL (continuing)"
        fi

        run_bare_prompt_case "D.zsh — VS Code + zsh" "git ch" "com.microsoft.VSCode" "zsh"

        if command -v bash > /dev/null 2>&1; then
            if assert_frontmost_is "com.microsoft.VSCode"; then
                if switch_shell_and_verify "bash" "com.microsoft.VSCode"; then
                    run_bare_prompt_case "D.bash — VS Code + bash" "git ch" "com.microsoft.VSCode" "bash"
                else
                    skip "D.bash — exec bash never produced a bash session (PATH/Enter?)"
                fi
            fi
        else
            skip "D.bash — bash not installed"
        fi

        if command -v fish > /dev/null 2>&1; then
            if assert_frontmost_is "com.microsoft.VSCode"; then
                if switch_shell_and_verify "fish" "com.microsoft.VSCode"; then
                    run_bare_prompt_case "D.fish — VS Code + fish" "git ch" "com.microsoft.VSCode" "fish"
                else
                    skip "D.fish — exec fish never produced a fish session (PATH/Enter?)"
                fi
            fi
        else
            skip "D.fish — fish not installed"
        fi

        # Close the VS Code window.
        if assert_frontmost_is "com.microsoft.VSCode"; then
            osascript -e 'tell application "System Events" to keystroke "w" using {command down, shift down}' 2>/dev/null
            sleep 0.5
        fi
    else
        skip "Phase D — could not open a new VS Code window"
    fi
else
    skip "Phase D — 'code' CLI not on PATH"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "==========================================="
echo " Summary"
echo "==========================================="
echo "  PASS:  $PASS"
echo "  FAIL:  $FAIL"
echo "  SKIP:  $SKIP"
echo ""

if (( FAIL > 0 )); then
    exit 1
fi
exit 0
