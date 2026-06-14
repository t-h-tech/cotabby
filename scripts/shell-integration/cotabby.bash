#!/usr/bin/env bash
# Cotabby shell integration for bash.
#
# Source this file in your .bashrc (and have .bash_profile source .bashrc):
#   source /path/to/cotabby.bash
#
# Reports the current command buffer and cursor position to Cotabby over a Unix domain socket
# after every keystroke. Transport is /usr/bin/nc -U (BSD netcat, shipped on every macOS
# install) — no `brew install socat` required.
#
# How per-keystroke reporting works (and why it needs bash >= 4):
# readline has no "after self-insert" hook, so every printable ASCII key is individually
# rebound with `bind -x` to a function that re-implements self-insert (insert at
# READLINE_POINT, advance point) and then reports the buffer. The editing keys we rebind
# (backspace, Ctrl-A/E/K/U/W/Y/D) likewise re-implement their default readline action before
# reporting — a `bind -x` binding REPLACES the default action, it does not wrap it, so a
# report-only binding would silently break the key. READLINE_LINE/READLINE_POINT only exist
# on bash >= 4.0; macOS ships 3.2, so on stock bash we disable cleanly instead of breaking
# keys (`brew install bash` to enable).
#
# Deliberately NOT rebound: Enter (command submission stays native), Tab (completion),
# Ctrl-R (history search), Ctrl-C, arrows/history navigation. Buffer changes those produce
# are picked up by the next reported keystroke or the PROMPT_COMMAND heartbeat. Bracketed
# paste also bypasses the per-key bindings; the post-accept paste is reflected on the next
# keystroke, which is fine because the overlay clears on acceptance anyway.

# Guard: do not load twice in the same shell process. Deliberately NOT exported — an exported
# guard is inherited by child/exec'd shells (`zsh` → `exec bash`), which silently disabled
# integration in every nested shell. A plain variable dies with the process image, so each new
# shell loads its own hook while a double `source` in the same shell is still a no-op.
[[ -n "$_cotabby_integration_loaded" ]] && return
_cotabby_integration_loaded=1

# Socket path must match TerminalIntegrationService.swift.
_cotabby_socket="${HOME}/Library/Application Support/Cotabby/terminal.sock"
# Pinned absolute path — third-party `nc` replacements (Nmap's ncat in particular) have
# incompatible UDS flags, so we always use the system BSD netcat.
_cotabby_nc=/usr/bin/nc

# Detect the hosting terminal's bundle identifier.
_cotabby_terminal_bundle_id=""
if [[ -n "$__CFBundleIdentifier" ]]; then
    _cotabby_terminal_bundle_id="$__CFBundleIdentifier"
elif [[ "$TERM_PROGRAM" == "ghostty" ]]; then
    _cotabby_terminal_bundle_id="com.mitchellh.ghostty"
elif [[ "$TERM_PROGRAM" == "iTerm.app" ]]; then
    _cotabby_terminal_bundle_id="com.googlecode.iterm2"
elif [[ "$TERM_PROGRAM" == "Apple_Terminal" ]]; then
    _cotabby_terminal_bundle_id="com.apple.Terminal"
elif [[ "$TERM_PROGRAM" == "WezTerm" ]]; then
    _cotabby_terminal_bundle_id="com.github.wez.wezterm"
elif [[ "$TERM_PROGRAM" == "vscode" ]]; then
    _cotabby_terminal_bundle_id="com.microsoft.VSCode"
fi

_cotabby_send() {
    local msg="$1"
    # Cheap pre-checks first: no point spawning nc when the daemon isn't running. `-w 1` caps
    # the connection so a stalled server cannot wedge bash; nc closes on stdin EOF, so the
    # typical send returns in well under a millisecond.
    if [[ -S "$_cotabby_socket" && -x "$_cotabby_nc" ]]; then
        printf '%s\n' "$msg" | "$_cotabby_nc" -U -w 1 "$_cotabby_socket" 2>/dev/null
    fi
}

_cotabby_escape_json() {
    # Minimal JSON string escaping for the command buffer.
    local str="$1"
    str="${str//\\/\\\\}"   # backslash
    str="${str//\"/\\\"}"   # double quote
    str="${str//$'\t'/\\t}" # tab
    str="${str//$'\n'/\\n}" # newline
    printf '%s' "$str"
}

_cotabby_report_buffer() {
    # $READLINE_LINE — the current contents of the readline buffer
    # $READLINE_POINT — byte offset of the cursor within $READLINE_LINE
    # Both are UNSET outside `bind -x` handlers (notably in PROMPT_COMMAND), so default them —
    # `printf %d ""` spams "invalid number" on every prompt otherwise.
    local escaped_text
    escaped_text=$(_cotabby_escape_json "${READLINE_LINE-}")
    local json
    json=$(printf '{"type":"buffer","text":"%s","cursor":%d,"shell":"bash","terminal":"%s","pid":%d}' \
        "$escaped_text" \
        "${READLINE_POINT:-0}" \
        "$_cotabby_terminal_bundle_id" \
        "$$")
    _cotabby_send "$json"
}

_cotabby_report_disconnect() {
    local json
    json=$(printf '{"type":"disconnect","shell":"bash","terminal":"%s","pid":%d}' \
        "$_cotabby_terminal_bundle_id" "$$")
    _cotabby_send "$json"
}

# Report disconnect on shell exit. Installed before the version gate so even unsupported
# sessions clean up the heartbeat below.
trap '_cotabby_report_disconnect' EXIT

# PROMPT_COMMAND heartbeat: announces the session to Cotabby on the first prompt and reports
# the (empty) buffer after every command, covering edits the key bindings can't see.
if [[ -n "$PROMPT_COMMAND" ]]; then
    PROMPT_COMMAND="_cotabby_report_buffer; ${PROMPT_COMMAND}"
else
    PROMPT_COMMAND="_cotabby_report_buffer"
fi

# READLINE_LINE/READLINE_POINT were introduced in bash 4.0. Without them no binding can read
# or edit the buffer, so on macOS's stock 3.2 we stop here rather than install bindings that
# would break editing keys. PROMPT_COMMAND/disconnect above still let Cotabby see the session.
if (( BASH_VERSINFO[0] < 4 )); then
    echo "[cotabby] bash ${BASH_VERSION%%(*} lacks READLINE_LINE (need >= 4.0); per-keystroke integration disabled. brew install bash" >&2
    return 0
fi

# --- per-keystroke readline hooks (bash >= 4) ---

# Re-implementation of readline's self-insert, then report. `bind -x` replaces the default
# action, so the insert must be done by hand: splice the char at READLINE_POINT and advance.
_cotabby_self_insert() {
    local c="$1"
    READLINE_LINE="${READLINE_LINE:0:READLINE_POINT}${c}${READLINE_LINE:READLINE_POINT}"
    (( READLINE_POINT += ${#c} ))
    _cotabby_report_buffer
}

# Bind every printable ASCII character (32..126) to the self-insert wrapper. The character
# is parked in a per-key variable (_cotabby_char_NN) so the bind command string never needs
# to quote the character itself — only `"` and `\` need escaping in the key sequence.
_cotabby_bind_printables() {
    local i char keyseq
    for (( i = 32; i <= 126; i++ )); do
        printf -v char "\\$(printf '%03o' "$i")"
        printf -v "_cotabby_char_$i" '%s' "$char"
        keyseq="$char"
        case "$char" in
            '"') keyseq='\"' ;;
            '\') keyseq='\\' ;;
        esac
        bind -x "\"${keyseq}\": _cotabby_self_insert \"\$_cotabby_char_$i\"" 2>/dev/null
    done
}
_cotabby_bind_printables
unset -f _cotabby_bind_printables

# Editing keys: each re-implements its readline default, then reports. A shared single-slot
# kill buffer approximates the readline kill ring for Ctrl-K/U/W/Y.
_cotabby_kill_buffer=""

_cotabby_backward_delete_char() {
    if (( READLINE_POINT > 0 )); then
        READLINE_LINE="${READLINE_LINE:0:READLINE_POINT-1}${READLINE_LINE:READLINE_POINT}"
        (( READLINE_POINT-- ))
    fi
    _cotabby_report_buffer
}

_cotabby_delete_char_or_eof() {
    # Default Ctrl-D: EOF on an empty line, delete-char otherwise.
    if [[ -z "$READLINE_LINE" ]]; then
        builtin exit
    fi
    if (( READLINE_POINT < ${#READLINE_LINE} )); then
        READLINE_LINE="${READLINE_LINE:0:READLINE_POINT}${READLINE_LINE:READLINE_POINT+1}"
    fi
    _cotabby_report_buffer
}

_cotabby_beginning_of_line() { READLINE_POINT=0; _cotabby_report_buffer; }
_cotabby_end_of_line()       { READLINE_POINT=${#READLINE_LINE}; _cotabby_report_buffer; }

_cotabby_kill_line() {
    _cotabby_kill_buffer="${READLINE_LINE:READLINE_POINT}"
    READLINE_LINE="${READLINE_LINE:0:READLINE_POINT}"
    _cotabby_report_buffer
}

_cotabby_unix_line_discard() {
    _cotabby_kill_buffer="${READLINE_LINE:0:READLINE_POINT}"
    READLINE_LINE="${READLINE_LINE:READLINE_POINT}"
    READLINE_POINT=0
    _cotabby_report_buffer
}

_cotabby_unix_word_rubout() {
    local head="${READLINE_LINE:0:READLINE_POINT}"
    local tail="${READLINE_LINE:READLINE_POINT}"
    # Default unix-word-rubout: strip trailing whitespace, then the word before the cursor.
    local trimmed="${head%"${head##*[![:space:]]}"}"
    local kept="${trimmed% *}"
    if [[ "$kept" == "$trimmed" ]]; then kept=""; fi
    if [[ -n "$kept" ]]; then kept="$kept "; fi
    _cotabby_kill_buffer="${head:${#kept}}"
    READLINE_LINE="${kept}${tail}"
    READLINE_POINT=${#kept}
    _cotabby_report_buffer
}

_cotabby_yank() {
    if [[ -n "$_cotabby_kill_buffer" ]]; then
        READLINE_LINE="${READLINE_LINE:0:READLINE_POINT}${_cotabby_kill_buffer}${READLINE_LINE:READLINE_POINT}"
        (( READLINE_POINT += ${#_cotabby_kill_buffer} ))
    fi
    _cotabby_report_buffer
}

bind -x '"\C-h": _cotabby_backward_delete_char' 2>/dev/null
bind -x '"\C-?": _cotabby_backward_delete_char' 2>/dev/null
bind -x '"\C-d": _cotabby_delete_char_or_eof'   2>/dev/null
bind -x '"\C-a": _cotabby_beginning_of_line'    2>/dev/null
bind -x '"\C-e": _cotabby_end_of_line'          2>/dev/null
bind -x '"\C-k": _cotabby_kill_line'            2>/dev/null
bind -x '"\C-u": _cotabby_unix_line_discard'    2>/dev/null
bind -x '"\C-w": _cotabby_unix_word_rubout'     2>/dev/null
bind -x '"\C-y": _cotabby_yank'                 2>/dev/null

# stderr so scripts capturing a hooked shell's stdout never see the banner.
echo "[cotabby] Shell integration loaded for ${_cotabby_terminal_bundle_id} (pid $$)" >&2
