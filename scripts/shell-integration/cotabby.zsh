#!/usr/bin/env zsh
# Cotabby shell integration for zsh.
#
# Source this file in your .zshrc:
#   source /path/to/cotabby.zsh
#
# Transport: writes newline-delimited JSON to Cotabby's Unix-domain socket via /usr/bin/nc -U,
# which ships on every macOS install (BSD netcat). No `brew install socat` needed.

# Guard: do not load twice in the same shell process. Deliberately NOT exported — an exported
# guard is inherited by child/exec'd shells (`zsh` → `exec bash`), which silently disabled
# integration in every nested shell. A plain variable dies with the process image, so each new
# shell loads its own hook while a double `source` in the same shell is still a no-op.
[[ -n "$_cotabby_integration_loaded" ]] && return
_cotabby_integration_loaded=1

# Socket path must match TerminalIntegrationService.swift.
_cotabby_socket="${HOME}/Library/Application Support/Cotabby/terminal.sock"
# Absolute path is intentional: a wrapper or alias for `nc` from a third-party tool (e.g.
# nmap's `ncat`, which doesn't accept `-U` the same way) would silently break the hook. The
# pinned path also avoids a per-keystroke PATH lookup.
_cotabby_nc=/usr/bin/nc

# Detect terminal bundle identifier.
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
else
    _cotabby_terminal_bundle_id="unknown"
fi

# Verify /usr/bin/nc is present. This should never fail on macOS (it's part of the base
# system), but if a user's PATH or filesystem is mangled we'd rather error loudly here than
# silently no-op on every keystroke.
if [[ ! -x "$_cotabby_nc" ]]; then
    echo "[cotabby] /usr/bin/nc not found — terminal integration disabled." >&2
    return 1
fi

_cotabby_send() {
    # Cheap pre-check: skip the subprocess spawn entirely when the socket is gone, which is
    # the common "Cotabby isn't running" case. Without this every keystroke pays for nc to
    # fork, fail, and exit.
    [[ -S "$_cotabby_socket" ]] || return 1
    # `-w 1` caps the connection at one second so a stalled server can never wedge the shell;
    # nc closes immediately after stdin EOF, so the typical send is sub-millisecond.
    printf '%s\n' "$1" | "$_cotabby_nc" -U -w 1 "$_cotabby_socket" 2>/dev/null
}

# JSON-escape a string: handle backslash, double quote, newline, tab.
_cotabby_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

_cotabby_report_buffer() {
    local escaped_text
    escaped_text=$(_cotabby_json_escape "$BUFFER")
    _cotabby_send "{\"type\":\"buffer\",\"text\":\"${escaped_text}\",\"cursor\":${CURSOR:-0},\"shell\":\"zsh\",\"terminal\":\"${_cotabby_terminal_bundle_id}\",\"pid\":$$}"
}

_cotabby_report_disconnect() {
    _cotabby_send "{\"type\":\"disconnect\",\"shell\":\"zsh\",\"terminal\":\"${_cotabby_terminal_bundle_id}\",\"pid\":$$}"
}

# --- zle widget wrapper ---

_cotabby_widget_wrapper() {
    # Call the original built-in widget (dot prefix accesses the built-in directly).
    zle ".${WIDGET}" "$@"
    _cotabby_report_buffer
}

# Wrap common editing widgets so every keystroke reports buffer state.
for _w in self-insert backward-delete-char delete-char kill-line \
          kill-whole-line backward-kill-word kill-word yank yank-pop; do
    zle -N "$_w" _cotabby_widget_wrapper
done

# --- Right-arrow acceptance ---
# When a suggestion is available, right-arrow at end of line inserts it directly into
# the zsh buffer. This bypasses CGEvent tap issues and handles acceptance shell-side.
_cotabby_suggestion_file="${HOME}/Library/Application Support/Cotabby/terminal-suggestion.txt"

_cotabby_forward_char() {
    local _debug="${HOME}/Library/Application Support/Cotabby/terminal-accept-debug.log"
    # If cursor is at end of buffer and a suggestion file exists, accept the suggestion.
    if (( CURSOR == ${#BUFFER} )) && [[ -f "$_cotabby_suggestion_file" ]]; then
        local suggestion
        suggestion=$(<"$_cotabby_suggestion_file")
        if [[ -n "$suggestion" ]]; then
            printf "BEFORE: BUFFER=[%s] CURSOR=%d\n" "$BUFFER" "$CURSOR" >> "$_debug"
            LBUFFER="${LBUFFER}${suggestion}"
            rm -f "$_cotabby_suggestion_file" 2>/dev/null
            printf "AFTER: BUFFER=[%s] CURSOR=%d LEN=%d\n" "$BUFFER" "$CURSOR" "${#BUFFER}" >> "$_debug"
            _cotabby_report_buffer
            return
        fi
    fi
    printf "PASSTHROUGH: BUFFER=[%s] CURSOR=%d LEN=%d\n" "$BUFFER" "$CURSOR" "${#BUFFER}" >> "$_debug" 2>/dev/null
    # Normal right-arrow behavior.
    zle .forward-char "$@"
}
zle -N forward-char _cotabby_forward_char
# Also bind the raw escape sequences for right-arrow, since some terminals
# (Ghostty with kitty keyboard protocol, kitty, WezTerm) may not map them
# to the built-in forward-char widget.
bindkey '\e[C'  forward-char   # Standard right-arrow (CSI C)
bindkey '\eOC'  forward-char   # Application-mode right-arrow (SS3 C)

# Hook into new-prompt and command-submission.
_cotabby_line_init() {
    # Re-ensure our forward-char widget is bound. This is a safety net: after a
    # subprocess (e.g. Claude Code) takes over stdin and exits, zle resumes and
    # fires zle-line-init. Re-binding here ensures acceptance survives.
    zle -N forward-char _cotabby_forward_char
    _cotabby_report_buffer
}
_cotabby_line_finish() { _cotabby_report_buffer; }
zle -N zle-line-init _cotabby_line_init
zle -N zle-line-finish _cotabby_line_finish

# Also report via precmd as a safety net.
autoload -Uz add-zsh-hook 2>/dev/null
if (( $+functions[add-zsh-hook] )); then
    add-zsh-hook precmd _cotabby_report_buffer
    add-zsh-hook zshexit _cotabby_report_disconnect
else
    precmd_functions+=(_cotabby_report_buffer)
    trap '_cotabby_report_disconnect' EXIT
fi

# stderr so scripts capturing a hooked shell's stdout never see the banner.
echo "[cotabby] Shell integration loaded for ${_cotabby_terminal_bundle_id} (pid $$)" >&2
