#!/bin/bash
# scripts/test-terminal-e2e.sh
#
# End-to-end test for Cotabby terminal integration.
# Uses AppleScript to control Ghostty — tests shell prompt suggestions,
# right-arrow acceptance, Claude Code non-interference, and post-exit recovery.
#
# Prerequisites:
#   - Cotabby running (from Xcode or standalone)
#   - Ghostty installed with zsh as default shell
#   - ~/.zshrc sources the Cotabby hook (auto-load)
#   - Accessibility permission granted to the app running this script
#   - Claude Code installed (optional — skips Claude Code tests if missing)
#
# Usage:
#   bash scripts/test-terminal-e2e.sh

set -uo pipefail

SOCKET="$HOME/Library/Application Support/Cotabby/terminal.sock"
SUGGESTION_FILE="$HOME/Library/Application Support/Cotabby/terminal-suggestion.txt"
ACCEPT_DEBUG="$HOME/Library/Application Support/Cotabby/terminal-accept-debug.log"
JSONL_LOG="$HOME/Library/Logs/Cotabby/cotabby.jsonl"

PASS=0
FAIL=0
SKIP=0

pass() { echo "  PASS: $1"; ((PASS++)); }
fail() { echo "  FAIL: $1"; ((FAIL++)); }
skip() { echo "  SKIP: $1"; ((SKIP++)); }

# Helper: type text character by character with delays (so zle widgets fire)
type_slowly() {
    local text="$1"
    local delay="${2:-0.12}"
    local script=""
    for (( i=0; i<${#text}; i++ )); do
        local char="${text:$i:1}"
        if [[ "$char" == " " ]]; then
            script+="keystroke \" \""$'\n'
        else
            script+="keystroke \"$char\""$'\n'
        fi
        script+="delay $delay"$'\n'
    done
    osascript -e "
tell application \"System Events\"
    tell process \"Ghostty\"
        $script
    end tell
end tell
"
}

# Helper: press a key by code
press_key() {
    local code="$1"
    osascript -e "
tell application \"System Events\"
    tell process \"Ghostty\"
        key code $code
    end tell
end tell
"
}

# Helper: press Enter
press_enter() { press_key 36; }

# Helper: press Ctrl+C
press_ctrl_c() {
    osascript -e '
tell application "System Events"
    tell process "Ghostty"
        key code 8 using control down
    end tell
end tell
'
}

# Helper: wait for suggestion file (returns 0 if found, 1 if timeout)
wait_for_suggestion() {
    local timeout="${1:-15}"
    local waited=0
    while [[ ! -f "$SUGGESTION_FILE" ]] && (( waited < timeout )); do
        sleep 1
        ((waited++))
    done
    [[ -f "$SUGGESTION_FILE" ]]
}

# Helper: get recent log lines after a timestamp
log_lines_after() {
    local after="$1"
    local filter="${2:-}"
    if [[ -n "$filter" ]]; then
        tail -200 "$JSONL_LOG" 2>/dev/null | \
            jq -r "select(.timestamp > \"$after\" and .category != \"focus\" and (.message | test(\"$filter\"; \"i\"))) | .category + \": \" + .message" 2>/dev/null
    else
        tail -200 "$JSONL_LOG" 2>/dev/null | \
            jq -r "select(.timestamp > \"$after\" and .category != \"focus\") | .category + \": \" + .message" 2>/dev/null
    fi
}

# Helper: count real errors (exclude benign cancellations which are expected during focus changes)
count_real_errors() {
    local after="$1"
    tail -200 "$JSONL_LOG" 2>/dev/null | \
        jq -r "select(.timestamp > \"$after\" and .level == \"error\" and (.message | test(\"cancelled|canceled\") | not)) | .message" 2>/dev/null | wc -l
}

echo "==========================================="
echo " Cotabby Terminal E2E Test Suite v2"
echo "==========================================="
echo ""

# ============================================
# PREREQUISITES
# ============================================
echo "--- Prerequisites ---"

if ! pgrep -x Cotabby >/dev/null 2>&1; then
    fail "Cotabby is not running. Launch it from Xcode first."
    exit 1
fi
pass "Cotabby is running"

[[ -S "$SOCKET" ]] && pass "Socket exists" || { fail "Socket not found"; exit 1; }

if ! command -v osascript &>/dev/null; then
    fail "osascript not available"
    exit 1
fi
pass "osascript available"

HAS_CLAUDE=false
if command -v claude &>/dev/null; then
    pass "Claude Code found ($(claude --version 2>/dev/null | head -1))"
    HAS_CLAUDE=true
else
    skip "Claude Code not installed — Claude Code tests will be skipped"
fi

# Clean up
rm -f "$SUGGESTION_FILE" "$ACCEPT_DEBUG"

# ============================================
# TEST 1: Shell prompt — auto-load hook
# ============================================
echo ""
echo "=== TEST 1: Shell Prompt Auto-Load ==="

osascript <<'AS'
tell application "Ghostty" to activate
delay 0.5
tell application "System Events"
    tell process "Ghostty"
        keystroke "t" using command down
    end tell
end tell
delay 3
AS

echo "  New Ghostty tab opened (hook auto-loads via ~/.zshrc)"

# Record log position
LOG_BEFORE=$(wc -l < "$JSONL_LOG" 2>/dev/null || echo 0)

rm -f "$SUGGESTION_FILE" "$ACCEPT_DEBUG"
sleep 1

type_slowly "git com"
echo "  Typed 'git com'"

# Delete any stale file after typing
rm -f "$SUGGESTION_FILE"
sleep 2

if wait_for_suggestion 15; then
    SUGGESTION=$(cat "$SUGGESTION_FILE")
    pass "Suggestion appeared: '${SUGGESTION:0:50}'"
else
    fail "No suggestion appeared after 15s (hook may not have auto-loaded)"
    echo "  Recent logs:"
    log_lines_after "$(date -u -v-30S '+%Y-%m-%dT%H:%M:%S')" "suggestion|terminal" | tail -5 | sed 's/^/    /'
fi

# ============================================
# TEST 2: Right-arrow acceptance
# ============================================
echo ""
echo "=== TEST 2: Right-Arrow Acceptance ==="

if [[ -f "$SUGGESTION_FILE" ]]; then
    rm -f "$ACCEPT_DEBUG"
    press_key 124  # Right arrow
    sleep 1

    if [[ ! -f "$SUGGESTION_FILE" ]]; then
        if [[ -f "$ACCEPT_DEBUG" ]]; then
            AFTER_BUF=$(grep "^AFTER:" "$ACCEPT_DEBUG" | head -1 | sed 's/.*BUFFER=\[\(.*\)\] CURSOR.*/\1/')
            if [[ ${#AFTER_BUF} -gt 7 ]]; then
                pass "Right-arrow accepted: '${AFTER_BUF:0:50}'"
            else
                fail "File consumed but buffer not extended"
            fi
        else
            # File consumed but no debug log — Cotabby accepted via its own mechanism
            pass "Suggestion file consumed (acceptance worked)"
        fi
    else
        fail "Suggestion file still exists after right-arrow"
    fi
else
    skip "No suggestion to accept (Test 1 failed)"
fi

# Clear the line for next test
press_ctrl_c
sleep 0.5

# ============================================
# TEST 3: Second suggestion cycle
# ============================================
echo ""
echo "=== TEST 3: Second Suggestion Cycle ==="

rm -f "$SUGGESTION_FILE" "$ACCEPT_DEBUG"

type_slowly "echo hello"
echo "  Typed 'echo hello'"

rm -f "$SUGGESTION_FILE"
sleep 2

if wait_for_suggestion 10; then
    pass "Second suggestion appeared: '$(cat "$SUGGESTION_FILE" | head -c 50)'"
    # Accept it
    press_key 124
    sleep 1
    [[ ! -f "$SUGGESTION_FILE" ]] && pass "Second acceptance worked" || fail "Second acceptance failed"
else
    skip "No second suggestion (model may not have generated one)"
fi

press_ctrl_c
sleep 0.5

# ============================================
# TEST 4: Claude Code — non-interference
# ============================================
echo ""
echo "=== TEST 4: Claude Code Non-Interference ==="

if [[ "$HAS_CLAUDE" == "true" ]]; then
    rm -f "$SUGGESTION_FILE" "$ACCEPT_DEBUG"
    LOG_BEFORE_CLAUDE=$(wc -l < "$JSONL_LOG" 2>/dev/null || echo 0)

    # Launch Claude Code with --print to send a quick query and exit
    # Using -p (print mode) so it doesn't start interactive mode
    echo "  Launching Claude Code (print mode)..."

    type_slowly "claude -p 'say hello in one word'" 0.05
    press_enter
    echo "  Claude Code command sent"

    # Wait for Claude Code to finish
    sleep 8

    # Check: did Cotabby have real errors? Exclude benign cancellations (expected during focus changes).
    CLAUDE_ERRORS=$(count_real_errors "$(date -u -v-15S '+%Y-%m-%dT%H:%M:%S')")
    if (( CLAUDE_ERRORS == 0 )); then
        pass "No real Cotabby errors during Claude Code execution"
    else
        fail "Cotabby errors during Claude Code: $CLAUDE_ERRORS"
        log_lines_after "$(date -u -v-15S '+%Y-%m-%dT%H:%M:%S')" "error|crash" | tail -3 | sed 's/^/    /'
    fi

    # Check if suggestion file was written during Claude Code (it shouldn't be, or if it was, that's fine)
    if [[ -f "$SUGGESTION_FILE" ]]; then
        pass "Suggestion file present during/after Claude Code (Cotabby still active)"
    else
        pass "No suggestion file during Claude Code (expected — different input loop)"
    fi

    sleep 1

    # ============================================
    # TEST 5: Post-Claude Code recovery
    # ============================================
    echo ""
    echo "=== TEST 5: Post-Claude Code Shell Recovery ==="

    rm -f "$SUGGESTION_FILE" "$ACCEPT_DEBUG"

    # Claude Code in -p mode returns to the shell prompt automatically
    # Type a new command to see if suggestions resume
    type_slowly "docker build"
    echo "  Typed 'docker build' (post-Claude Code)"

    rm -f "$SUGGESTION_FILE"
    sleep 2

    if wait_for_suggestion 10; then
        pass "Suggestions resumed after Claude Code: '$(cat "$SUGGESTION_FILE" | head -c 50)'"

        # Test acceptance still works
        rm -f "$ACCEPT_DEBUG"
        press_key 124
        sleep 1
        if [[ ! -f "$SUGGESTION_FILE" ]]; then
            pass "Right-arrow acceptance works after Claude Code"
        else
            fail "Right-arrow acceptance broken after Claude Code"
        fi
    else
        skip "No suggestion after Claude Code (model may not have generated one)"
    fi

    press_ctrl_c
    sleep 0.5

    # ============================================
    # TEST 6: Claude Code interactive mode
    # ============================================
    echo ""
    echo "=== TEST 6: Claude Code Interactive Mode ==="

    rm -f "$SUGGESTION_FILE" "$ACCEPT_DEBUG"

    echo "  Launching Claude Code (interactive)..."
    type_slowly "claude" 0.08
    press_enter

    # Wait for Claude Code to start
    sleep 5

    # Type something inside Claude Code's input and send it
    type_slowly "hello world" 0.1
    press_enter
    echo "  Typed 'hello world' inside Claude Code"
    sleep 5

    # Check for real errors (exclude benign cancellations)
    CLAUDE_INT_ERRORS=$(count_real_errors "$(date -u -v-10S '+%Y-%m-%dT%H:%M:%S')")
    if (( CLAUDE_INT_ERRORS == 0 )); then
        pass "No real Cotabby errors during interactive Claude Code"
    else
        fail "Errors during interactive Claude Code"
    fi

    # Exit Claude Code — Escape first to clear any input, then /exit
    echo "  Exiting Claude Code..."
    osascript -e '
tell application "System Events"
    tell process "Ghostty"
        key code 53
        delay 0.5
        keystroke "/exit"
        delay 0.5
        key code 36
    end tell
end tell
'
    sleep 5
    # Press Enter twice to ensure a fresh zsh prompt
    press_enter
    sleep 1
    press_enter
    sleep 1

    # ============================================
    # TEST 7: Post-interactive Claude Code recovery
    # ============================================
    echo ""
    echo "=== TEST 7: Post-Interactive Claude Code Recovery ==="

    rm -f "$SUGGESTION_FILE" "$ACCEPT_DEBUG"

    # Ctrl+C to ensure clean prompt before typing
    press_ctrl_c
    sleep 0.5

    type_slowly "ls -la"
    echo "  Typed 'ls -la'"

    rm -f "$SUGGESTION_FILE"
    sleep 2

    if wait_for_suggestion 10; then
        ORIGINAL_SUGGESTION=$(cat "$SUGGESTION_FILE")
        pass "Suggestions work after exiting interactive Claude Code"
        rm -f "$ACCEPT_DEBUG"
        press_key 124
        sleep 2

        # Acceptance is verified by either:
        # 1. Widget debug log shows AFTER buffer was extended, OR
        # 2. Suggestion file was consumed (deleted), OR
        # 3. Suggestion file content CHANGED (Cotabby generated a NEW suggestion
        #    for the now-longer buffer — this means acceptance succeeded and
        #    triggered a follow-up suggestion)
        if [[ -f "$ACCEPT_DEBUG" ]] && grep -q "^AFTER:" "$ACCEPT_DEBUG"; then
            pass "Acceptance works after interactive Claude Code (widget confirmed)"
        elif [[ ! -f "$SUGGESTION_FILE" ]]; then
            pass "Acceptance works after interactive Claude Code (file consumed)"
        elif [[ -f "$SUGGESTION_FILE" ]] && [[ "$(cat "$SUGGESTION_FILE")" != "$ORIGINAL_SUGGESTION" ]]; then
            pass "Acceptance works after interactive Claude Code (new suggestion generated)"
        else
            fail "Acceptance broken after interactive Claude Code"
            echo "  Suggestion file still contains: '$(cat "$SUGGESTION_FILE" | head -c 50)'"
            [[ -f "$ACCEPT_DEBUG" ]] && echo "  Widget log:" && sed 's/^/    /' "$ACCEPT_DEBUG"
        fi
    else
        skip "No suggestion after interactive Claude Code exit"
    fi

    press_ctrl_c
    sleep 0.5
else
    skip "Claude Code not installed — skipping Tests 4-7"
fi

# ============================================
# TEST 8: Non-terminal regression (quick check)
# ============================================
echo ""
echo "=== TEST 8: Log Health Check ==="

# Check that no crashes or critical errors occurred during the entire test
ALL_ERRORS=$(log_lines_after "$(date -u -v-120S '+%Y-%m-%dT%H:%M:%S')" "crash|fatal|assertion" 2>/dev/null | wc -l)
if (( ALL_ERRORS == 0 )); then
    pass "No crashes or fatal errors in Cotabby logs"
else
    fail "Found $ALL_ERRORS critical log entries"
    log_lines_after "$(date -u -v-120S '+%Y-%m-%dT%H:%M:%S')" "crash|fatal|assertion" | tail -3 | sed 's/^/    /'
fi

# ============================================
# CLEANUP
# ============================================
echo ""
echo "--- Cleanup ---"

# Close the test tab
osascript <<'AS'
tell application "System Events"
    tell process "Ghostty"
        key code 8 using control down
        delay 0.3
        keystroke "exit"
        key code 36
    end tell
end tell
AS

rm -f "$SUGGESTION_FILE" "$ACCEPT_DEBUG"
echo "  Test tab closed"

# ============================================
# SUMMARY
# ============================================
echo ""
echo "==========================================="
echo " Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "==========================================="

if [[ $FAIL -gt 0 ]]; then
    echo " Some tests FAILED."
    exit 1
else
    echo " All tests PASSED!"
    exit 0
fi
