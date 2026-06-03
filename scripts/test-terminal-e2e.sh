#!/bin/bash
# scripts/test-terminal-e2e.sh
#
# End-to-end test for terminal right-arrow acceptance.
# Uses AppleScript to control Ghostty — opens a tab, sources the zsh hook,
# types a partial command, waits for a suggestion, presses right-arrow,
# and verifies the suggestion was accepted.
#
# Prerequisites:
#   - Cotabby running (from Xcode or standalone)
#   - Ghostty installed
#   - Accessibility permission granted to Terminal.app or wherever you run this
#
# Usage:
#   bash scripts/test-terminal-e2e.sh

set -uo pipefail

SOCKET="$HOME/Library/Application Support/Cotabby/terminal.sock"
SUGGESTION_FILE="$HOME/Library/Application Support/Cotabby/terminal-suggestion.txt"
HOOK_PATH="$(cd "$(dirname "$0")" && pwd)/shell-integration/cotabby.zsh"

echo "==========================================="
echo " Cotabby Terminal E2E Test (AppleScript)"
echo "==========================================="
echo ""

# --- Step 1: Prerequisites ---
echo "Step 1: Checking prerequisites..."

if ! pgrep -x Cotabby >/dev/null 2>&1; then
    echo "  FAIL: Cotabby is not running. Launch it from Xcode first."
    exit 1
fi
echo "  OK: Cotabby is running"

if [[ ! -S "$SOCKET" ]]; then
    echo "  FAIL: Socket not found at $SOCKET"
    exit 1
fi
echo "  OK: Socket exists"

if [[ ! -f "$HOOK_PATH" ]]; then
    echo "  FAIL: Shell hook not found at $HOOK_PATH"
    exit 1
fi
echo "  OK: Shell hook found"

if ! command -v osascript &>/dev/null; then
    echo "  FAIL: osascript not available"
    exit 1
fi
echo "  OK: osascript available"

# Clean up any leftover files
rm -f "$SUGGESTION_FILE"
ACCEPT_DEBUG="$HOME/Library/Application Support/Cotabby/terminal-accept-debug.log"
rm -f "$ACCEPT_DEBUG"

# --- Step 2: Open Ghostty and new tab ---
echo ""
echo "Step 2: Opening Ghostty with new tab..."

osascript <<'APPLESCRIPT'
tell application "Ghostty"
    activate
end tell
delay 1
tell application "System Events"
    tell process "Ghostty"
        -- Open a new tab
        keystroke "t" using command down
    end tell
end tell
delay 1.5
APPLESCRIPT

echo "  OK: Ghostty activated, new tab opened"

# --- Step 3: Switch to zsh ---
echo ""
echo "Step 3: Switching to zsh..."

osascript <<'APPLESCRIPT'
tell application "System Events"
    tell process "Ghostty"
        keystroke "zsh"
        key code 36 -- Enter
    end tell
end tell
delay 1.5
APPLESCRIPT

echo "  OK: zsh started"

# --- Step 4: Source the shell hook ---
echo ""
echo "Step 4: Sourcing the shell hook..."

osascript -e "
tell application \"System Events\"
    tell process \"Ghostty\"
        keystroke \"source $HOOK_PATH\"
        key code 36 -- Enter
    end tell
end tell
"
sleep 2

echo "  OK: Hook sourced"

# --- Step 5: Type partial command ---
echo ""
echo "Step 5: Typing 'git com' (with pauses for zle widgets)..."

# Type each character with a small delay so zle self-insert fires for each one
osascript <<'APPLESCRIPT'
tell application "System Events"
    tell process "Ghostty"
        keystroke "g"
        delay 0.15
        keystroke "i"
        delay 0.15
        keystroke "t"
        delay 0.15
        keystroke " "
        delay 0.15
        keystroke "c"
        delay 0.15
        keystroke "o"
        delay 0.15
        keystroke "m"
    end tell
end tell
APPLESCRIPT

echo "  OK: Typed 'git com'"

# Delete any stale suggestion file BEFORE waiting for a fresh one.
rm -f "$SUGGESTION_FILE"

# Give the hook time to send the buffer message and Cotabby time to generate
sleep 2

# --- Step 6: Wait for suggestion file ---
echo ""
echo "Step 6: Waiting for suggestion to appear (up to 15s)..."

WAITED=0
while [[ ! -f "$SUGGESTION_FILE" ]] && (( WAITED < 15 )); do
    sleep 1
    ((WAITED++))
    echo "  Waiting... (${WAITED}s)"
done

if [[ -f "$SUGGESTION_FILE" ]]; then
    SUGGESTION=$(cat "$SUGGESTION_FILE")
    echo "  OK: Suggestion file written after ${WAITED}s"
    echo "  Content: '${SUGGESTION:0:60}'"
else
    echo "  FAIL: Suggestion file never appeared after 15s"
    echo ""
    echo "  Debug: Check if Cotabby generated a suggestion:"
    echo "    tail -10 ~/Library/Logs/Cotabby/cotabby.jsonl | jq '.message'"
    echo ""
    echo "  Cleaning up test tab..."
    osascript <<'CLEANUP'
tell application "System Events"
    tell process "Ghostty"
        -- Ctrl+C to cancel, then close tab
        key code 8 using control down
        delay 0.3
        keystroke "exit"
        key code 36
        delay 0.3
        keystroke "exit"
        key code 36
    end tell
end tell
CLEANUP
    exit 1
fi

# --- Step 7: Press right-arrow ---
echo ""
echo "Step 7: Pressing right-arrow to accept..."

osascript <<'APPLESCRIPT'
tell application "System Events"
    tell process "Ghostty"
        key code 124 -- Right arrow
    end tell
end tell
APPLESCRIPT

sleep 1

# --- Step 8: Check if suggestion file was consumed ---
echo ""
echo "Step 8: Checking acceptance..."

ACCEPT_DEBUG="$HOME/Library/Application Support/Cotabby/terminal-accept-debug.log"

if [[ ! -f "$SUGGESTION_FILE" ]]; then
    echo "  OK: Suggestion file was consumed"
    if [[ -f "$ACCEPT_DEBUG" ]]; then
        echo "  Widget debug log:"
        sed 's/^/    /' "$ACCEPT_DEBUG"
        # Check if AFTER buffer contains more than BEFORE
        AFTER_BUFFER=$(grep "^AFTER:" "$ACCEPT_DEBUG" | head -1 | sed 's/.*BUFFER=\[\(.*\)\] CURSOR.*/\1/')
        if [[ ${#AFTER_BUFFER} -gt 7 ]]; then
            echo "  PASS: Buffer was extended to '${AFTER_BUFFER:0:60}'"
            RESULT="PASS"
        else
            echo "  FAIL: Buffer was NOT extended (still '${AFTER_BUFFER}')"
            RESULT="FAIL"
        fi
    else
        echo "  WARN: No widget debug log — widget may not have run"
        RESULT="FAIL"
    fi
else
    echo "  FAIL: Suggestion file still exists (right-arrow did not consume it)"
    echo "  File content: '$(cat "$SUGGESTION_FILE" | head -c 60)'"
    RESULT="FAIL"
fi

# --- Step 9: Pause to observe ---
echo ""
echo "Step 9: Pausing 3s so you can see the terminal..."
sleep 3

# --- Step 10: Clean up ---
echo ""
echo "Step 10: Cleaning up test tab..."

osascript <<'APPLESCRIPT'
tell application "System Events"
    tell process "Ghostty"
        -- Ctrl+C to cancel any command
        key code 8 using control down
        delay 0.3
        -- Type exit twice (once for zsh, once for the original shell)
        keystroke "exit"
        key code 36
        delay 0.5
        keystroke "exit"
        key code 36
    end tell
end tell
APPLESCRIPT

rm -f "$SUGGESTION_FILE"

echo "  OK: Cleaned up"

# --- Result ---
echo ""
echo "==========================================="
if [[ "$RESULT" == "PASS" ]]; then
    echo " RESULT: PASS — Right-arrow acceptance works!"
else
    echo " RESULT: FAIL — Right-arrow acceptance did not work"
fi
echo "==========================================="

[[ "$RESULT" == "PASS" ]] && exit 0 || exit 1
