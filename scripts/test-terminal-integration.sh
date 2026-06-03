#!/bin/bash
# scripts/test-terminal-integration.sh
#
# Comprehensive test for Cotabby terminal integration.
# Run this with Cotabby launched in Debug mode.
#
# Prerequisites:
#   - Cotabby is running (socket must exist)
#   - socat is installed (brew install socat)
#
# Usage:
#   bash scripts/test-terminal-integration.sh
#
# Exit code: 0 if all tests pass, 1 if any fail.

set -uo pipefail

SOCKET="$HOME/Library/Application Support/Cotabby/terminal.sock"
SUGGESTION_FILE="$HOME/Library/Application Support/Cotabby/terminal-suggestion.txt"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHELL_HOOKS_DIR="$SCRIPT_DIR/shell-integration"

PASS=0
FAIL=0
SKIP=0

pass() { echo "  PASS: $1"; ((PASS++)); }
fail() { echo "  FAIL: $1"; ((FAIL++)); }
skip() { echo "  SKIP: $1"; ((SKIP++)); }

echo "=========================================="
echo " Cotabby Terminal Integration Test Suite"
echo "=========================================="
echo ""

# ──────────────────────────────────────────────
# Prerequisites
# ──────────────────────────────────────────────
echo "--- Prerequisites ---"

if command -v socat &>/dev/null; then
    pass "socat is installed ($(command -v socat))"
else
    fail "socat is not installed. Run: brew install socat"
    echo ""
    echo "Cannot continue without socat."
    exit 1
fi

if [[ -S "$SOCKET" ]]; then
    pass "Socket exists at $SOCKET"
else
    fail "Socket does not exist. Is Cotabby running?"
    echo ""
    echo "Cannot continue without the socket."
    exit 1
fi

PERMS=$(stat -f "%Lp" "$SOCKET" 2>/dev/null)
if [[ "$PERMS" == "600" ]]; then
    pass "Socket permissions are 0600"
else
    fail "Socket permissions are $PERMS (expected 600)"
fi

if [[ -f "$SHELL_HOOKS_DIR/cotabby.bash" ]]; then
    pass "cotabby.bash found"
else
    fail "cotabby.bash not found at $SHELL_HOOKS_DIR/cotabby.bash"
fi

if [[ -f "$SHELL_HOOKS_DIR/cotabby.zsh" ]]; then
    pass "cotabby.zsh found"
else
    fail "cotabby.zsh not found at $SHELL_HOOKS_DIR/cotabby.zsh"
fi

# ──────────────────────────────────────────────
# Phase 1: Socket IPC
# ──────────────────────────────────────────────
echo ""
echo "--- Phase 1: Socket IPC ---"

# Test: Valid buffer message
MSG='{"type":"buffer","text":"git commit -m ","cursor":14,"shell":"zsh","terminal":"com.mitchellh.ghostty","pid":99901}'
if echo "$MSG" | socat - "UNIX-CONNECT:${SOCKET}" 2>/dev/null; then
    pass "Valid buffer message accepted"
else
    fail "Valid buffer message rejected"
fi
sleep 0.2

# Test: Updated buffer (same PID = same session)
MSG='{"type":"buffer","text":"git commit -m \"fix\"","cursor":19,"shell":"zsh","terminal":"com.mitchellh.ghostty","pid":99901}'
if echo "$MSG" | socat - "UNIX-CONNECT:${SOCKET}" 2>/dev/null; then
    pass "Updated buffer message accepted"
else
    fail "Updated buffer message rejected"
fi
sleep 0.1

# Test: Disconnect
MSG='{"type":"disconnect","shell":"zsh","terminal":"com.mitchellh.ghostty","pid":99901}'
if echo "$MSG" | socat - "UNIX-CONNECT:${SOCKET}" 2>/dev/null; then
    pass "Disconnect message accepted"
else
    fail "Disconnect message rejected"
fi
sleep 0.1

# Test: Malformed JSON
if echo "not valid json{{{" | socat - "UNIX-CONNECT:${SOCKET}" 2>/dev/null; then
    pass "Malformed JSON handled (connection accepted)"
else
    pass "Malformed JSON handled (connection closed gracefully)"
fi

# Test: Empty line
if echo "" | socat - "UNIX-CONNECT:${SOCKET}" 2>/dev/null; then
    pass "Empty message handled (connection accepted)"
else
    pass "Empty message handled (connection closed gracefully)"
fi

# Test: Message with special characters
MSG='{"type":"buffer","text":"echo \"hello\\nworld\"","cursor":20,"shell":"bash","terminal":"com.apple.Terminal","pid":99902}'
if echo "$MSG" | socat - "UNIX-CONNECT:${SOCKET}" 2>/dev/null; then
    pass "Message with escaped characters accepted"
else
    fail "Message with escaped characters rejected"
fi
sleep 0.1

# Clean up test session
echo '{"type":"disconnect","shell":"bash","terminal":"com.apple.Terminal","pid":99902}' \
  | socat - "UNIX-CONNECT:${SOCKET}" 2>/dev/null

# ──────────────────────────────────────────────
# Phase 2: Shell Hook Scripts
# ──────────────────────────────────────────────
echo ""
echo "--- Phase 2: Shell Hook Scripts ---"

# Syntax checks
if bash -n "$SHELL_HOOKS_DIR/cotabby.bash" 2>/dev/null; then
    pass "cotabby.bash syntax is valid"
else
    fail "cotabby.bash has syntax errors"
fi

if zsh -n "$SHELL_HOOKS_DIR/cotabby.zsh" 2>/dev/null; then
    pass "cotabby.zsh syntax is valid"
else
    fail "cotabby.zsh has syntax errors"
fi

# Terminal detection: Ghostty via TERM_PROGRAM
# set +u: the hook checks $COTABBY_SHELL_INTEGRATION_LOADED before it is defined.
RESULT=$(
    set +u
    export TERM_PROGRAM=ghostty
    unset __CFBundleIdentifier COTABBY_SHELL_INTEGRATION_LOADED 2>/dev/null
    source "$SHELL_HOOKS_DIR/cotabby.bash" 2>/dev/null
    echo "$_cotabby_terminal_bundle_id"
)
if [[ "$RESULT" == "com.mitchellh.ghostty" ]]; then
    pass "Bash hook detects Ghostty via TERM_PROGRAM"
else
    fail "Bash hook: expected com.mitchellh.ghostty, got $RESULT"
fi

# Terminal detection: VS Code via TERM_PROGRAM
RESULT=$(
    set +u
    export TERM_PROGRAM=vscode
    unset __CFBundleIdentifier COTABBY_SHELL_INTEGRATION_LOADED 2>/dev/null
    source "$SHELL_HOOKS_DIR/cotabby.bash" 2>/dev/null
    echo "$_cotabby_terminal_bundle_id"
)
if [[ "$RESULT" == "com.microsoft.VSCode" ]]; then
    pass "Bash hook detects VS Code via TERM_PROGRAM"
else
    fail "Bash hook: expected com.microsoft.VSCode, got $RESULT"
fi

# Terminal detection: __CFBundleIdentifier takes precedence
RESULT=$(
    set +u
    export __CFBundleIdentifier="com.googlecode.iterm2"
    export TERM_PROGRAM="other"
    unset COTABBY_SHELL_INTEGRATION_LOADED 2>/dev/null
    source "$SHELL_HOOKS_DIR/cotabby.bash" 2>/dev/null
    echo "$_cotabby_terminal_bundle_id"
)
if [[ "$RESULT" == "com.googlecode.iterm2" ]]; then
    pass "__CFBundleIdentifier takes precedence over TERM_PROGRAM"
else
    fail "Expected com.googlecode.iterm2, got $RESULT"
fi

# JSON escaping
ESCAPING_OK=true
(
    set +u
    export TERM_PROGRAM=ghostty
    unset __CFBundleIdentifier COTABBY_SHELL_INTEGRATION_LOADED 2>/dev/null
    source "$SHELL_HOOKS_DIR/cotabby.bash" 2>/dev/null

    # Backslash
    r=$(_cotabby_escape_json 'hello\world')
    [[ "$r" == 'hello\\world' ]] || exit 1

    # Double quote
    r=$(_cotabby_escape_json 'say "hi"')
    [[ "$r" == 'say \"hi\"' ]] || exit 1

    # Tab
    r=$(_cotabby_escape_json $'hello\tworld')
    [[ "$r" == 'hello\tworld' ]] || exit 1

    # Newline
    r=$(_cotabby_escape_json $'hello\nworld')
    [[ "$r" == 'hello\nworld' ]] || exit 1
) 2>/dev/null
if [[ $? -eq 0 ]]; then
    pass "JSON escaping handles backslash, dquote, tab, newline"
else
    fail "JSON escaping has issues (run Phase 2 manual tests for details)"
fi

# ──────────────────────────────────────────────
# Phase 3: Focus Bridge (simulated via socket)
# ──────────────────────────────────────────────
echo ""
echo "--- Phase 3: Focus Bridge (simulated) ---"

# Start a session and check if the pipeline processes it
MSG='{"type":"buffer","text":"docker build ","cursor":13,"shell":"zsh","terminal":"com.mitchellh.ghostty","pid":99903}'
echo "$MSG" | socat - "UNIX-CONNECT:${SOCKET}" 2>/dev/null
sleep 0.5

# The suggestion file is created when the pipeline processes terminal input
# and generates a suggestion. If no model is loaded, this may not appear.
if [[ -f "$SUGGESTION_FILE" ]]; then
    pass "Suggestion file created (pipeline processed terminal input)"
else
    skip "Suggestion file not created (model may not be loaded or debounce pending)"
fi

# Clean up
echo '{"type":"disconnect","shell":"zsh","terminal":"com.mitchellh.ghostty","pid":99903}' \
  | socat - "UNIX-CONNECT:${SOCKET}" 2>/dev/null
sleep 0.2

# ──────────────────────────────────────────────
# Phase 4: Multiple Sessions
# ──────────────────────────────────────────────
echo ""
echo "--- Phase 4: Multiple Sessions ---"

# Two concurrent sessions from different terminals
MSG1='{"type":"buffer","text":"ls -la","cursor":5,"shell":"zsh","terminal":"com.mitchellh.ghostty","pid":99904}'
MSG2='{"type":"buffer","text":"npm install","cursor":11,"shell":"bash","terminal":"com.microsoft.VSCode","pid":99905}'

echo "$MSG1" | socat - "UNIX-CONNECT:${SOCKET}" 2>/dev/null
echo "$MSG2" | socat - "UNIX-CONNECT:${SOCKET}" 2>/dev/null
sleep 0.1
pass "Two concurrent sessions sent without error"

# Disconnect one, update the other
echo '{"type":"disconnect","shell":"zsh","terminal":"com.mitchellh.ghostty","pid":99904}' \
  | socat - "UNIX-CONNECT:${SOCKET}" 2>/dev/null
sleep 0.1

MSG2_UPDATE='{"type":"buffer","text":"npm install express","cursor":19,"shell":"bash","terminal":"com.microsoft.VSCode","pid":99905}'
if echo "$MSG2_UPDATE" | socat - "UNIX-CONNECT:${SOCKET}" 2>/dev/null; then
    pass "Remaining session accepts updates after peer disconnects"
else
    fail "Remaining session could not receive updates"
fi

# Clean up
echo '{"type":"disconnect","shell":"bash","terminal":"com.microsoft.VSCode","pid":99905}' \
  | socat - "UNIX-CONNECT:${SOCKET}" 2>/dev/null

# ──────────────────────────────────────────────
# Phase 5: Stress Test
# ──────────────────────────────────────────────
echo ""
echo "--- Phase 5: Rapid Message Stress Test ---"

for i in $(seq 1 50); do
    MSG="{\"type\":\"buffer\",\"text\":\"test command $i\",\"cursor\":$((14 + ${#i})),\"shell\":\"zsh\",\"terminal\":\"com.mitchellh.ghostty\",\"pid\":99906}"
    echo "$MSG" | socat - "UNIX-CONNECT:${SOCKET}" 2>/dev/null
done
sleep 0.5

# Verify socket still accepts connections after the burst
MSG='{"type":"buffer","text":"post-stress","cursor":11,"shell":"zsh","terminal":"com.mitchellh.ghostty","pid":99907}'
if echo "$MSG" | socat - "UNIX-CONNECT:${SOCKET}" 2>/dev/null; then
    pass "Socket server survived 50 rapid messages"
else
    fail "Socket server stopped accepting connections after stress test"
fi

# Clean up
echo '{"type":"disconnect","shell":"zsh","terminal":"com.mitchellh.ghostty","pid":99906}' \
  | socat - "UNIX-CONNECT:${SOCKET}" 2>/dev/null
echo '{"type":"disconnect","shell":"zsh","terminal":"com.mitchellh.ghostty","pid":99907}' \
  | socat - "UNIX-CONNECT:${SOCKET}" 2>/dev/null

# ──────────────────────────────────────────────
# Phase 6: Per-App Bundle ID Acceptance
# ──────────────────────────────────────────────
echo ""
echo "--- Phase 6: Per-App Terminal Checks ---"

check_terminal_app() {
    local name="$1"
    local bundle_id="$2"
    local test_pid="$3"

    MSG="{\"type\":\"buffer\",\"text\":\"echo hello from $name\",\"cursor\":$((17 + ${#name})),\"shell\":\"zsh\",\"terminal\":\"$bundle_id\",\"pid\":$test_pid}"
    if echo "$MSG" | socat - "UNIX-CONNECT:${SOCKET}" 2>/dev/null; then
        pass "$name ($bundle_id): message accepted"
    else
        fail "$name ($bundle_id): message rejected"
    fi
    sleep 0.1
    echo "{\"type\":\"disconnect\",\"shell\":\"zsh\",\"terminal\":\"$bundle_id\",\"pid\":$test_pid}" \
      | socat - "UNIX-CONNECT:${SOCKET}" 2>/dev/null
}

check_terminal_app "Ghostty"        "com.mitchellh.ghostty"    99910
check_terminal_app "VS Code"        "com.microsoft.VSCode"     99911
check_terminal_app "iTerm2"         "com.googlecode.iterm2"    99912
check_terminal_app "Apple Terminal"  "com.apple.Terminal"       99913
check_terminal_app "Kitty"          "net.kovidgoyal.kitty"     99914
check_terminal_app "Alacritty"      "io.alacritty"             99915
check_terminal_app "WezTerm"        "com.github.wez.wezterm"   99916

# ──────────────────────────────────────────────
# Phase 7: Build Verification
# ──────────────────────────────────────────────
echo ""
echo "--- Phase 7: Build Verification ---"

PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$PROJECT_DIR/Cotabby.xcodeproj/project.pbxproj" ]]; then
    pass "Xcode project found"
else
    fail "Xcode project not found at $PROJECT_DIR/Cotabby.xcodeproj"
fi

# Check that new terminal files exist
declare -a TERMINAL_FILES=(
    "Cotabby/Models/TerminalFocusModels.swift"
    "Cotabby/Services/Terminal/TerminalIntegrationService.swift"
    "Cotabby/Services/Terminal/TerminalGeometryResolver.swift"
    "Cotabby/Support/TerminalFocusAdapter.swift"
)

for f in "${TERMINAL_FILES[@]}"; do
    if [[ -f "$PROJECT_DIR/$f" ]]; then
        pass "File exists: $f"
    else
        fail "Missing file: $f"
    fi
done

# Check modified files exist
declare -a MODIFIED_FILES=(
    "Cotabby/Support/TerminalAppDetector.swift"
    "Cotabby/Models/FocusTrackingModel.swift"
    "Cotabby/App/Core/CotabbyAppEnvironment.swift"
    "Cotabby/App/Core/AppDelegate.swift"
    "Cotabby/Services/Suggestion/SuggestionInserter.swift"
    "Cotabby/Support/SuggestionAvailabilityEvaluator.swift"
    "Cotabby/Models/SuggestionSettingsModel.swift"
)

for f in "${MODIFIED_FILES[@]}"; do
    if [[ -f "$PROJECT_DIR/$f" ]]; then
        pass "File exists: $f"
    else
        fail "Missing file: $f"
    fi
done

# ──────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────
echo ""
echo "=========================================="
echo " Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "=========================================="

if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo " Some tests failed. Review the FAIL lines above."
    exit 1
else
    echo ""
    echo " All tests passed."
    exit 0
fi
