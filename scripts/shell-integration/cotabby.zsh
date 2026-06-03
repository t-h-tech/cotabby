#!/usr/bin/env zsh
# Cotabby shell integration for zsh.
#
# Source this file in your .zshrc:
#   source /path/to/cotabby.zsh
#
# Requires: socat (brew install socat)

# Guard: do not load twice.
[[ -n "$COTABBY_SHELL_INTEGRATION_LOADED" ]] && return
export COTABBY_SHELL_INTEGRATION_LOADED=1

# Socket path must match TerminalIntegrationService.swift.
_cotabby_socket="${HOME}/Library/Application Support/Cotabby/terminal.sock"

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

# Verify socat is available.
if ! (( $+commands[socat] )); then
    echo "[cotabby] socat not found. Install with: brew install socat" >&2
    return 1
fi

_cotabby_send() {
    [[ -S "$_cotabby_socket" ]] || return 1
    printf '%s\n' "$1" | socat - "UNIX-CONNECT:${_cotabby_socket}" 2>/dev/null
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
_cotabby_line_init() { _cotabby_report_buffer; }
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

echo "[cotabby] Shell integration loaded for ${_cotabby_terminal_bundle_id} (pid $$)"
