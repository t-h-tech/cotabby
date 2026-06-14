#!/usr/bin/env bash
# Regression test for the VS Code TuiOCR stickiness bug (plan doc, "VS Code round"):
# after exiting `claude` in VS Code's integrated terminal, the injected
# ClaudeCodeTuiInput snapshot must CLEAR (heartbeat-driven, no keystroke needed)
# instead of leaving the HUD stuck on "TuiOCR | ClaudeCodeTuiInput".
#
# Asserts, via the debug JSONL (app must be running with -cotabby-debug):
#   1. ClaudeCodeTuiInput snapshots inject while claude runs in VS Code (TUI alive);
#   2. after /exit, injections STOP (quiesce within a bounded window — claude's own
#      shutdown takes a few seconds, during which injections are still legitimate);
#   3. the focus model republishes VS Code's real AX state
#      ("Focus snapshot changed: app=Code capability=Unsupported") — the direct
#      signature of clearTerminalInjection's republish; before the fix this line
#      could never appear because the injected snapshot was immortal.
#
# Prereqs: same as test-terminal-acceptance-e2e.sh (Accessibility for the automation
# host, no secure-input holder, `code` CLI on PATH, shell hooks installed). Steals
# the foreground for ~1 minute.
set -u
JSONL_LOG="$HOME/Library/Logs/Cotabby/cotabby.jsonl"
[[ -f "$JSONL_LOG" ]] || { echo "FAIL: no debug JSONL — launch Cotabby with -cotabby-debug"; exit 1; }
command -v code >/dev/null 2>&1 || { echo "SKIP: 'code' CLI not on PATH"; exit 0; }

now_iso() { date -u +"%Y-%m-%dT%H:%M:%S.000Z"; }
frontmost_bundle_id() {
    osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true' 2>/dev/null
}
activate_and_wait_for_focus() {
    local bundle_id="$1"; local timeout="${2:-5}"
    osascript -e "tell application id \"$bundle_id\" to activate" 2>/dev/null || return 1
    local waited=0
    while (( waited * 10 < timeout * 10 )); do
        if [[ "$(frontmost_bundle_id)" == "$bundle_id" ]]; then sleep 0.3; return 0; fi
        sleep 0.2; waited=$((waited + 1))
    done
    return 1
}
type_into_focused() {
    local text="$1"; local delay="${2:-0.10}"
    local script="tell application \"System Events\""$'\n'
    for (( i=0; i<${#text}; i++ )); do
        local char="${text:$i:1}"
        if [[ "$char" == " " ]]; then script+="keystroke \" \""$'\n'
        elif [[ "$char" == '"' ]]; then script+="keystroke \"\\\"\""$'\n'
        elif [[ "$char" == '\' ]]; then script+="keystroke \"\\\\\""$'\n'
        else script+="keystroke \"$char\""$'\n'; fi
        script+="delay $delay"$'\n'
    done
    script+="end tell"
    osascript -e "$script" 2>/dev/null
}
press_enter() { osascript -e 'tell application "System Events" to key code 36' 2>/dev/null; }
press_ctrl_c() { osascript -e 'tell application "System Events" to keystroke "c" using control down' 2>/dev/null; }
# True while a `claude` whose PARENT is a shell is alive — i.e. the one launched from the
# integrated terminal. Distinguishes it from the Claude desktop app's own claude-code
# process (parent: claude.app) and from extension-host processes.
vscode_claude_alive() {
    local p pp pc
    for p in $(pgrep -x claude 2>/dev/null); do
        pp=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
        [[ -n "$pp" ]] || continue
        pc=$(ps -o comm= -p "$pp" 2>/dev/null)
        case "$pc" in
            *zsh|*bash|*fish) return 0 ;;
        esac
    done
    return 1
}
count_tui_injections_since() {
    jq -r "select(.timestamp >= \"$1\") | select((.message // \"\") | test(\"ClaudeCodeTuiInput snapshot injected\")) | .timestamp" "$JSONL_LOG" 2>/dev/null | wc -l | tr -d ' '
}
last_tui_injection() {
    jq -r 'select((.message // "") | test("ClaudeCodeTuiInput snapshot injected")) | .timestamp' "$JSONL_LOG" 2>/dev/null | tail -1
}

echo "[1/5] Opening new VS Code window with integrated terminal..."
code -n 2>/dev/null &
sleep 3.0
activate_and_wait_for_focus "com.microsoft.VSCode" 5 || { echo "FAIL: VS Code not frontmost"; exit 1; }
osascript -e 'tell application "System Events" to keystroke "`" using control down' 2>/dev/null
sleep 1.5
activate_and_wait_for_focus "com.microsoft.VSCode" 3 || { echo "FAIL: VS Code lost focus"; exit 1; }

START=$(now_iso)
echo "[2/5] Launching claude in the integrated terminal..."
type_into_focused "claude" 0.08
press_enter

echo "[3/5] Waiting for ClaudeCodeTuiInput injection (<=30s)..."
deadline=$((SECONDS + 30)); injected=0
while (( SECONDS < deadline )); do
    if [[ "$(count_tui_injections_since "$START")" -ge 1 ]]; then injected=1; break; fi
    sleep 1
done
if (( injected == 0 )); then
    echo "FAIL: no TUI injection while claude runs in VS Code (TUI path dead?)"
    type_into_focused "/exit" 0.08; press_enter; sleep 1
    exit 1
fi
echo "  PASS: TUI injection observed while claude runs in VS Code"
sleep 3   # let a few heartbeat cycles run while claude is alive

echo "[4/5] Exiting claude (/exit, with Ctrl+C fallback)..."
[[ "$(frontmost_bundle_id)" == "com.microsoft.VSCode" ]] || { echo "FAIL: focus drifted"; exit 1; }
type_into_focused "/exit" 0.12
sleep 0.8
press_enter
# /exit can be swallowed by claude's trust/onboarding screens (one Enter advances them
# instead). Key the wait on the PROCESS, not the UI: poll for the shell-parented claude
# to die, falling back to the canonical double Ctrl+C.
death_deadline=$((SECONDS + 12)); dead=0
while (( SECONDS < death_deadline )); do
    if ! vscode_claude_alive; then dead=1; break; fi
    sleep 1
done
if (( dead == 0 )); then
    echo "  NOTE: /exit did not land; sending Ctrl+C twice"
    press_ctrl_c; sleep 0.4; press_ctrl_c
    death_deadline=$((SECONDS + 12))
    while (( SECONDS < death_deadline )); do
        if ! vscode_claude_alive; then dead=1; break; fi
        sleep 1
    done
fi
status=0
if (( dead == 1 )); then
    DEATH_TS=$(now_iso)
    echo "  PASS: claude process exited"
else
    echo "  FAIL: could not drive claude to exit (environment) — closing the window instead;"
    echo "        the session-death path below still exercises the same clear mechanism"
    DEATH_TS=$(now_iso)
    osascript -e 'tell application "System Events" to keystroke "w" using {command down, shift down}' 2>/dev/null
    status=1
fi

# The heartbeat is 1 Hz and the clear lands within a tick or two of the process dying;
# injections during claude's own multi-second shutdown are legitimate, so the assertion
# window starts at process death, not at the /exit keystroke.
echo "[5/5] Asserting the injection cleared within 8s of claude dying..."
sleep 8
LAST_INJ=$(last_tui_injection)
if [[ "$LAST_INJ" > "$DEATH_TS" ]]; then
    # Allow one in-flight capture to land right at death; anything beyond ~2s is sticky.
    LATE_CUTOFF=$(date -u -v-6S +"%Y-%m-%dT%H:%M:%S.000Z")
    if [[ "$LAST_INJ" > "$LATE_CUTOFF" ]]; then
        echo "  FAIL: TUI injections still firing well after claude died (stickiness regression)"
        status=1
    fi
fi
# Two valid end states after the TUI dies:
#   (a) heartbeat clear → focus model republishes VS Code's real AX state, or
#   (b) the shell prompt redraw fires precmd, the hook reports, and a SHELL snapshot
#       takes over (role TerminalShellInput) — the TUI then stands down via the
#       fingerprint gate / heartbeat. (b) is the common path and is exactly the
#       "back to shell completions after exiting claude" behavior under test.
RESTORE=$(jq -r "select(.timestamp > \"$LAST_INJ\") | select((.message // \"\") | test(\"Focus snapshot changed: app=Code capability=Unsupported\")) | .timestamp" "$JSONL_LOG" | head -1)
STOOD_DOWN=$(jq -r "select(.timestamp > \"$LAST_INJ\") | select((.message // \"\") | test(\"TUI capture lacks Claude Code fingerprint|TUI heartbeat: classification=(notClaudeCode|unknown)\")) | .timestamp" "$JSONL_LOG" | head -1)
SHELL_TAKEOVER=$(jq -r "select(.timestamp > \"$LAST_INJ\") | select((.message // \"\") | test(\"visual context session for element terminal-\")) | .timestamp" "$JSONL_LOG" | head -1)
if [[ -n "$RESTORE" ]]; then
    echo "  PASS: focus model republished real AX state at $RESTORE (heartbeat clear fired)"
elif [[ -n "$SHELL_TAKEOVER" && -n "$STOOD_DOWN" ]]; then
    echo "  PASS: shell snapshot took over at $SHELL_TAKEOVER and TUI stood down at $STOOD_DOWN"
else
    echo "  FAIL: neither AX republish nor shell takeover after the last injection — TuiOCR sticky"
    status=1
fi

# Cleanup: close the VS Code window we opened.
if [[ "$(frontmost_bundle_id)" == "com.microsoft.VSCode" ]]; then
    osascript -e 'tell application "System Events" to keystroke "w" using {command down, shift down}' 2>/dev/null
fi
exit $status
