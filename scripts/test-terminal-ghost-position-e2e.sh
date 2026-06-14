#!/usr/bin/env bash
# Ghost-position E2E: asserts the inline gray suggestion renders ON the prompt line,
# right after the typed text — not at the window-bottom fallback that shipped before the
# OCR prompt-anchor work (plan doc: "Ghost text at the real caret on terminal surfaces").
#
# Ground truth comes from two independent sources that must agree:
#   1. The overlay's actual AppKit placement, from the debug log line
#      "Inline ghost shown: caret=(x,y) panel=(...)" (only with -cotabby-debug).
#   2. Vision OCR of a full-screen screenshot locating the typed prefix's line.
# Vision boxes are normalized with a BOTTOM-LEFT origin — the same orientation as AppKit
# screen points — so vision_y * screen_height compares directly against the logged caret y.
#
# Phases: Ghostty (dedicated terminal) and VS Code integrated terminal. The wrap-below case
# is covered by GhostSuggestionLayoutTests (deterministic) rather than scripted here.
# Steals the foreground ~2 min. Requires: -cotabby-debug app, Screen Recording for your
# automation host (screencapture), Accessibility (System Events typing), jq, swiftc.
set -u
JSONL_LOG="$HOME/Library/Logs/Cotabby/cotabby.jsonl"
OCR_BIN="/tmp/cotabby-ocr-lines"
SHOT="/tmp/cotabby-ghost-position-shot.png"
PASS=0; FAIL=0; SKIP=0
pass() { echo "  PASS: $1"; ((PASS++)); }
fail() { echo "  FAIL: $1"; ((FAIL++)); }
skip() { echo "  SKIP: $1"; ((SKIP++)); }

[[ -f "$JSONL_LOG" ]] || { echo "FAIL: no debug JSONL — launch Cotabby with -cotabby-debug"; exit 1; }

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
        else script+="keystroke \"$char\""$'\n'; fi
        script+="delay $delay"$'\n'
    done
    script+="end tell"
    osascript -e "$script" 2>/dev/null
}
press_ctrl_c() { osascript -e 'tell application "System Events" to keystroke "c" using control down' 2>/dev/null; }

# Screen height in POINTS (AppKit), main display.
screen_height() {
    osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null \
        | awk -F", " '{print $4}'
}
screen_width() {
    osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null \
        | awk -F", " '{print $3}'
}

latest_ghost_caret_since() {
    # Prints "x y" of the last "Inline ghost shown" caret after $1, if any.
    jq -r "select(.timestamp >= \"$1\") | select((.message // \"\") | test(\"Inline ghost shown\")) | .message" "$JSONL_LOG" \
        | tail -1 | sed -E 's/.*caret=\(([-0-9]+),([-0-9]+)\).*/\1 \2/'
}

# Poll the JSONL for a message matching $1 since timestamp $2, up to $3 seconds.
wait_for_log() {
    local pattern="$1"; local since="$2"; local timeout="${3:-10}"
    local deadline=$((SECONDS + timeout))
    while (( SECONDS < deadline )); do
        if jq -r "select(.timestamp >= \"$since\") | select((.message // \"\") | test(\"$pattern\")) | .timestamp" "$JSONL_LOG" 2>/dev/null | head -1 | grep -q .; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

# Locate the bottom-most OCR line containing the needle. Prints "minX maxX midY" in
# normalized Vision coords (bottom-left origin).
ocr_find_line() {
    local needle="$1"
    "$OCR_BIN" "$SHOT" 2>/dev/null | jq -rs --arg needle "$needle" '
        map(select(.text | contains($needle))) | sort_by(.y) | first // empty
        | "\(.x) \(.x + .w) \(.y + .h / 2)"'
}

run_position_phase() {
    local label="$1"; local bundle="$2"; local prefix="git ch"
    local since; since=$(now_iso)

    type_into_focused "$prefix" 0.10
    # Generation (~200-400ms) + anchor OCR (250ms debounce + ~200ms OCR) + re-presentation.
    if ! wait_for_log "Inline ghost shown" "$since" 12; then
        fail "$label — no inline ghost placement logged within 12s (suggestion missing or suppressed)"
        press_ctrl_c; return
    fi
    sleep 1.0   # let anchor-driven repositioning settle before sampling

    local caret; caret=$(latest_ghost_caret_since "$since")
    if [[ -z "$caret" || "$caret" == *"Inline ghost shown"* ]]; then
        fail "$label — could not parse ghost placement"
        press_ctrl_c; return
    fi
    local caret_x caret_y; read -r caret_x caret_y <<< "$caret"

    screencapture -x "$SHOT" 2>/dev/null
    local line; line=$(ocr_find_line "$prefix")
    press_ctrl_c
    if [[ -z "$line" ]]; then
        skip "$label — OCR could not find the typed prefix on screen (font/theme?)"
        return
    fi
    local line_min_x line_max_x line_mid_y; read -r line_min_x line_max_x line_mid_y <<< "$line"
    local sw sh; sw=$(screen_width); sh=$(screen_height)
    local prompt_y prompt_end_x prompt_start_x
    prompt_y=$(echo "$line_mid_y * $sh" | bc -l | cut -d. -f1)
    prompt_end_x=$(echo "$line_max_x * $sw" | bc -l | cut -d. -f1)
    prompt_start_x=$(echo "$line_min_x * $sw" | bc -l | cut -d. -f1)

    local dy=$(( caret_y > prompt_y ? caret_y - prompt_y : prompt_y - caret_y ))
    if (( dy <= 24 )); then
        pass "$label — ghost on the prompt line (caretY=$caret_y promptY=$prompt_y dy=$dy)"
    else
        fail "$label — ghost OFF the prompt line (caretY=$caret_y promptY=$prompt_y dy=$dy)"
    fi
    if (( caret_x >= prompt_start_x && caret_x <= prompt_end_x + 80 )); then
        pass "$label — ghost x sits at the end of the typed text (caretX=$caret_x promptEnd=$prompt_end_x)"
    else
        fail "$label — ghost x far from typed text (caretX=$caret_x promptEnd=$prompt_end_x)"
    fi
}

echo "--- Preflight"
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }
if [[ ! -x "$OCR_BIN" ]]; then
    echo "building OCR helper..."
    swiftc -O "$(dirname "$0")/ocr-lines.swift" -o "$OCR_BIN" || { echo "FAIL: OCR helper build"; exit 1; }
fi

echo "--- Phase 1: Ghostty"
if activate_and_wait_for_focus "com.mitchellh.ghostty" 5; then
    phase_start=$(now_iso)
    # Fresh window = fresh hooked shell; typing into a stale/absent window is the main flake.
    osascript -e 'tell application "System Events" to keystroke "n" using command down' 2>/dev/null
    if wait_for_log "New terminal session.*ghostty" "$phase_start" 10; then
        sleep 0.5
        run_position_phase "Ghostty" "com.mitchellh.ghostty"
    else
        skip "Ghostty — no hooked shell session registered (hooks not installed?)"
    fi
else
    skip "Ghostty not available/focusable"
fi

echo "--- Phase 2: VS Code integrated terminal"
if command -v code >/dev/null 2>&1; then
    code -n 2>/dev/null &
    sleep 3.0
    if activate_and_wait_for_focus "com.microsoft.VSCode" 5; then
        phase_start=$(now_iso)
        osascript -e 'tell application "System Events" to keystroke "`" using control down' 2>/dev/null
        if ! wait_for_log "New terminal session.*VSCode" "$phase_start" 12; then
            skip "VS Code — no hooked shell session registered"
            osascript -e 'tell application "System Events" to keystroke "w" using {command down, shift down}' 2>/dev/null
        else
            sleep 0.5
            run_position_phase "VS Code" "com.microsoft.VSCode"
        fi
        if [[ "$(frontmost_bundle_id)" == "com.microsoft.VSCode" ]]; then
            osascript -e 'tell application "System Events" to keystroke "w" using {command down, shift down}' 2>/dev/null
        fi
    else
        skip "VS Code not focusable"
    fi
else
    skip "'code' CLI not on PATH"
fi

echo
echo "RESULTS: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
(( FAIL == 0 )) || exit 1
