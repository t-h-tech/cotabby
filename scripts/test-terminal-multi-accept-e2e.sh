#!/usr/bin/env bash
# Multi-accept regression test for the optimistic-echo fix (plan doc, ghost-position round
# follow-up): accepting several chunks in a row must preserve the suggestion's separator
# spaces. Before the fix, bracketed paste was invisible to the shell hooks, the live snapshot
# went stale, and the whitespace reconciler stripped legitimate leading spaces from later
# chunks ("git pull" + " origin" → "git pullorigin").
#
# Keystroke-free (Phase-Z machinery): Terminal.app `do script` + zsh `print -z` preloads the
# buffer, IPC `{"type":"accept"}` drives the real acceptance path, and the final buffer is
# read back from the terminal screen. Assertion: the final buffer must be a VERBATIM prefix
# of (typed prefix + raw model completion) — any dropped or doubled space breaks prefix-ness.
# Requires the app running with -cotabby-debug. Steals foreground ~30 s.
set -u
JSONL_LOG="$HOME/Library/Logs/Cotabby/cotabby.jsonl"
LLM_LOG="$HOME/Library/Logs/Cotabby/llm-io.jsonl"
SOCKET="$HOME/Library/Application Support/Cotabby/terminal.sock"
PREFIX="git"
ACCEPTS=3

[[ -S "$SOCKET" ]] || { echo "FAIL: Cotabby socket missing (-cotabby-debug app running?)"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }

now_iso() { date -u +"%Y-%m-%dT%H:%M:%S.000Z"; }
send_accept_ipc() { printf '{"type":"accept"}\n' | /usr/bin/nc -U "$SOCKET" -w 1 2>/dev/null; }

START=$(now_iso)
echo "[1/4] Opening Terminal.app window with preloaded buffer '$PREFIX'..."
osascript <<OSA
tell application "Terminal"
    activate
    do script "print -z '$PREFIX'"
end tell
OSA
sleep 1.0

echo "[2/4] Waiting for a ready suggestion for the preloaded buffer (<=20s)..."
deadline=$((SECONDS + 20)); RAW=""
while (( SECONDS < deadline )); do
    RAW=$(jq -r "select(.timestamp >= \"$START\") | select((.prompt // \"\") | endswith(\"\$ $PREFIX\")) | .completion_raw" "$LLM_LOG" 2>/dev/null | tail -1)
    [[ -n "$RAW" && "$RAW" != "null" ]] && break
    sleep 0.5
done
if [[ -z "$RAW" || "$RAW" == "null" ]]; then
    echo "FAIL: no generation for '$PREFIX' within 20s"
    exit 1
fi
echo "  suggestion RAW=[$RAW]"
sleep 1.0   # let ready state + overlay settle

echo "[3/4] Accepting $ACCEPTS chunks via IPC..."
for _ in $(seq "$ACCEPTS"); do
    send_accept_ipc
    sleep 1.2
done
sleep 0.5

echo "[4/4] Reading the buffer back from the terminal screen..."
SCREEN=$(osascript -e 'tell application "Terminal" to get history of selected tab of front window' 2>/dev/null)
BUFFER=$(printf '%s' "$SCREEN" | grep -E "% $PREFIX" | tail -1 | sed -E "s/.*% //" | sed -E 's/[[:space:]]+$//')
# Close the window we opened.
osascript -e 'tell application "Terminal" to close front window' -e 'tell application "System Events" to keystroke return' 2>/dev/null

echo "  final buffer=[$BUFFER]"
EXPECTED="$PREFIX$RAW"
status=0
if [[ -z "$BUFFER" || "$BUFFER" == "$PREFIX" ]]; then
    echo "FAIL: buffer did not grow (accepts did not land)"
    status=1
elif [[ "$EXPECTED" == "$BUFFER"* ]]; then
    echo "PASS: buffer is a verbatim prefix of prompt+completion — all separator spaces intact"
else
    echo "FAIL: buffer diverges from the suggestion text (dropped/added characters)"
    echo "      expected prefix of: [$EXPECTED]"
    status=1
fi
exit $status
