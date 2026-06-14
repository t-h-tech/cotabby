# Cotabby shell integration for fish.
#
# Source this file from your fish config (e.g. ~/.config/fish/conf.d/cotabby.fish):
#   source /path/to/cotabby.fish
#
# Reports the current command buffer and cursor position to Cotabby's Unix domain socket using
# /usr/bin/nc -U (BSD netcat — ships with macOS, no extra install).
#
# Mirroring decision (compared with the zsh/bash hooks):
#   * fish exposes no generic "after self-insert" hook the way zsh's `zle -N` widgets do.
#     We bind the common editing keys (backspace, kill-word, etc.) and report on every
#     prompt redraw via `fish_prompt`. This matches the existing bash hook's shape —
#     incremental ghost text updates land on the next prompt or hooked keystroke rather than
#     on every printable character. Good enough for shell-prompt autocomplete; we keep the
#     OCR-based TUI path for full-screen apps like Claude Code.
#   * We do NOT touch fish's built-in autosuggest. The two systems coexist: fish's history
#     suggestion lives in the editor; Cotabby's ghost text floats above the caret.

# Guard: do not load twice in the same shell process. `set -g` (global, NOT exported -gx) —
# an exported guard is inherited by child/exec'd shells (`zsh` → `exec fish`), which silently
# disabled integration in every nested shell.
set -q _cotabby_integration_loaded; and exit 0
set -g _cotabby_integration_loaded 1

# Socket path must match TerminalIntegrationService.swift.
set -g _cotabby_socket "$HOME/Library/Application Support/Cotabby/terminal.sock"
# Pinned absolute path so a third-party `nc` replacement (e.g. nmap's ncat) can't break us.
set -g _cotabby_nc /usr/bin/nc

# Detect the hosting terminal so the Swift side can attribute the session.
if set -q __CFBundleIdentifier
    set -g _cotabby_terminal_bundle_id "$__CFBundleIdentifier"
else if test "$TERM_PROGRAM" = "ghostty"
    set -g _cotabby_terminal_bundle_id "com.mitchellh.ghostty"
else if test "$TERM_PROGRAM" = "iTerm.app"
    set -g _cotabby_terminal_bundle_id "com.googlecode.iterm2"
else if test "$TERM_PROGRAM" = "Apple_Terminal"
    set -g _cotabby_terminal_bundle_id "com.apple.Terminal"
else if test "$TERM_PROGRAM" = "WezTerm"
    set -g _cotabby_terminal_bundle_id "com.github.wez.wezterm"
else if test "$TERM_PROGRAM" = "vscode"
    set -g _cotabby_terminal_bundle_id "com.microsoft.VSCode"
else
    set -g _cotabby_terminal_bundle_id unknown
end

# Sanity-check /usr/bin/nc up front. macOS always ships it, so failure here implies a heavily
# customized filesystem — louder than a per-keystroke silent no-op.
if not test -x "$_cotabby_nc"
    echo "[cotabby] /usr/bin/nc not found — terminal integration disabled." >&2
    exit 1
end

# Minimal JSON string escaping for the command buffer.
# Every expansion is quoted: an empty value run through unquoted command substitution
# collapses to an empty LIST in fish, after which the next `string replace -- $s` has no
# input operand and the whole pipeline degrades — the first (empty-buffer) report of every
# session was lost to exactly this.
function _cotabby_json_escape
    set -l s "$argv[1]"
    set s (string replace -a '\\' '\\\\' -- "$s")
    set s (string replace -a '"' '\\"' -- "$s")
    set s (string replace -a \t '\\t' -- "$s")
    set s (string replace -a \n '\\n' -- "$s")
    set s (string replace -a \r '\\r' -- "$s")
    printf '%s' "$s"
end

function _cotabby_send
    # Cheap pre-check: skip the subprocess entirely when the daemon isn't running. -w 1 caps
    # the connection so a wedged server cannot block fish; nc exits on stdin EOF so the
    # typical send returns sub-millisecond.
    test -S $_cotabby_socket; or return 1
    printf '%s\n' $argv[1] | $_cotabby_nc -U -w 1 $_cotabby_socket 2>/dev/null
end

function _cotabby_report_buffer
    # `commandline` returns the entire edit buffer; `commandline -C` is the cursor's char
    # offset into that buffer. `TerminalFocusAdapter` treats fish's cursor offset as a
    # character (not byte) offset, so we hand it through verbatim.
    set -l text (commandline)
    set -l cursor (commandline -C)
    set -l escaped (_cotabby_json_escape "$text")
    _cotabby_send "{\"type\":\"buffer\",\"text\":\"$escaped\",\"cursor\":$cursor,\"shell\":\"fish\",\"terminal\":\"$_cotabby_terminal_bundle_id\",\"pid\":$fish_pid}"
end

function _cotabby_report_disconnect --on-event fish_exit
    _cotabby_send "{\"type\":\"disconnect\",\"shell\":\"fish\",\"terminal\":\"$_cotabby_terminal_bundle_id\",\"pid\":$fish_pid}"
end

# Prompt-redraw reporter. fish calls fish_prompt before drawing each prompt, so wrapping it
# gives us prompt-level reporting (matches the bash hook's PROMPT_COMMAND approach). We chain
# the user's existing fish_prompt rather than replacing it.
if functions -q fish_prompt
    functions -c fish_prompt _cotabby_original_fish_prompt
    function fish_prompt
        _cotabby_original_fish_prompt
        _cotabby_report_buffer
    end
else
    function fish_prompt
        _cotabby_report_buffer
    end
end

# Per-keystroke reporting: fish has no generic "after self-insert" hook, so every printable
# ASCII character is bound to insert-then-report, mirroring the bash hook's per-key bindings.
# `bind` accepts multiple commands and runs them in order. Known trade-off: overriding the
# space key bypasses abbreviation expansion (abbr) — autocomplete reporting wins here.
for _cotabby_i in (seq 32 126)
    set -l _cotabby_c (printf '%b' (printf '\\%03o' $_cotabby_i))
    set -l _cotabby_esc (string escape -- $_cotabby_c)
    bind --silent -- $_cotabby_c "commandline -i -- $_cotabby_esc" _cotabby_report_buffer 2>/dev/null
end
set -e _cotabby_i
set -e _cotabby_c

# Bind common editing keys to wrappers that report after the default action.
function _cotabby_wrap_after --argument-names default
    eval "$default"
    _cotabby_report_buffer
end

# Editing keys (backspace, ctrl-w, ctrl-u, ctrl-k, ctrl-y, ctrl-h, return). Each binding
# invokes the underlying fish function first, then reports the new buffer state.
bind --silent \cm '_cotabby_wrap_after "commandline -f execute"' 2>/dev/null
bind --silent \cu '_cotabby_wrap_after "commandline -f backward-kill-line"' 2>/dev/null
bind --silent \ck '_cotabby_wrap_after "commandline -f kill-line"' 2>/dev/null
bind --silent \cw '_cotabby_wrap_after "commandline -f backward-kill-word"' 2>/dev/null
bind --silent \ch '_cotabby_wrap_after "commandline -f backward-delete-char"' 2>/dev/null
bind --silent \cy '_cotabby_wrap_after "commandline -f yank"' 2>/dev/null
bind --silent \b '_cotabby_wrap_after "commandline -f backward-delete-char"' 2>/dev/null

# Right-arrow acceptance. Matches the zsh hook's semantics: at end-of-buffer with a pending
# Cotabby suggestion, insert it into the command line; otherwise pass through to fish's
# normal forward-char. The suggestion file is shared with the zsh/bash hooks.
set -g _cotabby_suggestion_file "$HOME/Library/Application Support/Cotabby/terminal-suggestion.txt"

function _cotabby_forward_char
    set -l buf (commandline)
    set -l cursor (commandline -C)
    set -l buf_len (string length -- $buf)
    if test $cursor -eq $buf_len; and test -f $_cotabby_suggestion_file
        set -l suggestion (cat $_cotabby_suggestion_file)
        if test -n "$suggestion"
            commandline --insert -- $suggestion
            rm -f $_cotabby_suggestion_file 2>/dev/null
            _cotabby_report_buffer
            return
        end
    end
    commandline -f forward-char
end

bind --silent \e\[C _cotabby_forward_char 2>/dev/null
bind --silent \eOC _cotabby_forward_char 2>/dev/null

# stderr so scripts capturing a hooked shell's stdout never see the banner.
echo "[cotabby] Shell integration loaded for $_cotabby_terminal_bundle_id (pid $fish_pid)" >&2
