#!/usr/bin/env bash
# Cotabby shell integration for bash.
#
# Source this file in your .bashrc or .bash_profile:
#   source /path/to/cotabby.bash
#
# The hook reports the current command buffer and cursor position to Cotabby over a Unix domain
# socket after every keystroke. Cotabby uses this to provide inline autocomplete in terminal apps
# where macOS Accessibility attributes are not available.

# Guard: do not load twice in the same session.
[[ -n "$COTABBY_SHELL_INTEGRATION_LOADED" ]] && return
export COTABBY_SHELL_INTEGRATION_LOADED=1

# Socket path must match TerminalIntegrationService.swift.
_cotabby_socket="${HOME}/Library/Application Support/Cotabby/terminal.sock"

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
    # Write to the Unix domain socket via socat. socat is the most portable way to talk to
    # a Unix socket from a shell script on macOS.
    if [[ -S "$_cotabby_socket" ]] && command -v socat &>/dev/null; then
        printf '%s\n' "$msg" | socat - "UNIX-CONNECT:${_cotabby_socket}" 2>/dev/null
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
    local escaped_text
    escaped_text=$(_cotabby_escape_json "$READLINE_LINE")
    local json
    json=$(printf '{"type":"buffer","text":"%s","cursor":%d,"shell":"bash","terminal":"%s","pid":%d}' \
        "$escaped_text" \
        "$READLINE_POINT" \
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

# --- readline hooks ---

# bind -x binds a shell function to a key sequence. When the key is pressed, bash calls the
# function with $READLINE_LINE and $READLINE_POINT set to the current buffer state.
# We bind to common editing keys and a catch-all approach using PROMPT_COMMAND.

# Report buffer after every command prompt is displayed. This catches cases where the buffer
# was modified by operations we didn't explicitly bind (paste, undo, etc.).
_cotabby_prompt_hook() {
    # READLINE_LINE is only available inside bind -x functions, not in PROMPT_COMMAND.
    # We use this as a session heartbeat and rely on bind -x for actual buffer reporting.
    :
}

# Wrap common keystrokes via bind -x. The function is called AFTER readline processes the key,
# so $READLINE_LINE reflects the updated buffer.
_cotabby_after_keystroke() {
    _cotabby_report_buffer
}

# Bind to self-insert-like events. In bash, bind -x for every printable character is impractical,
# so we use a periodic approach: report the buffer after each command via PROMPT_COMMAND, and
# also bind to Enter and common editing keys.

# The cleanest approach for bash is to use a READLINE macro that calls our function after each
# keypress. However, bash 4.x+ supports bind -x with a function that runs after each key.
# We use the "\C-x\C-r" internal binding trick: bind a rarely-used sequence to our reporter,
# then insert it into the default keymap via KEYSEQ_TIMEOUT.

# Primary approach: bind -x to a terminal-bell key that we remap.
bind -x '"\e[COTABBY_REPORT": _cotabby_after_keystroke' 2>/dev/null

# Fallback: bind common editing keys individually.
# These fire our reporter after the default action has already updated READLINE_LINE.
for _key in '\C-a' '\C-e' '\C-k' '\C-u' '\C-w' '\C-y' '\C-d' '\C-h' '\C-?' '\C-m'; do
    bind -x "\"${_key}\": _cotabby_after_keystroke" 2>/dev/null
done

# For regular character input, bash doesn't support a generic "after self-insert" hook.
# We use PROMPT_COMMAND to report the buffer when the prompt is redrawn (i.e. after each
# command completes). For mid-command reporting, the bind -x keys above cover the most
# common editing operations.
if [[ -n "$PROMPT_COMMAND" ]]; then
    PROMPT_COMMAND="_cotabby_report_buffer; ${PROMPT_COMMAND}"
else
    PROMPT_COMMAND="_cotabby_report_buffer"
fi

# Report disconnect on shell exit.
trap '_cotabby_report_disconnect' EXIT
