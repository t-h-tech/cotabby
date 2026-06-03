# Terminal Integration Plan

Cotabby provides inline autocomplete via macOS Accessibility APIs. Terminals
expose minimal AX attributes for their text content, so Cotabby blocks them.
This plan adds **shell integration**: bash/zsh hooks report command buffer state
over a Unix domain socket, and Cotabby bridges that into the existing suggestion
pipeline.

**Target terminals:** Ghostty, VS Code integrated terminal, iTerm2, Apple
Terminal, Kitty, Alacritty, WezTerm, Rio. Claude Code runs inside these
terminals and benefits automatically.

**Architecture:**

```
Shell hook (zsh/bash)
  ──JSON over Unix socket──▶  TerminalIntegrationService
                                     │
                              TerminalGeometryResolver (enrich with AX window frame)
                                     │
                              TerminalFocusAdapter (convert to FocusedInputSnapshot)
                                     │
                              FocusTrackingModel.injectTerminalSnapshot()
                                     │
                              ┌──────▼──────────────────────┐
                              │ Existing suggestion pipeline │
                              │ (debounce → generate → overlay → insert) │
                              └─────────────────────────────┘
```

**Acceptance key:** Right arrow (like fish shell) instead of Tab.

**Text insertion:** Clipboard paste (`Cmd+V`) instead of synthetic keyboard
events (which break in terminals with kitty keyboard protocol).

---

## How to use this plan

Work through the phases in order. Each phase has a **gate** — a set of success
criteria that must all pass before moving to the next phase. Do not skip ahead.

After completing all phases, run the comprehensive test script:

```bash
bash scripts/test-terminal-integration.sh
```

---

## Phase 1: Socket IPC Foundation

**Goal:** The app compiles with all terminal files, creates the socket on launch,
accepts connections, and parses JSON messages without crashing.

### Files involved

| File | Status |
|------|--------|
| `Cotabby/Models/TerminalFocusModels.swift` | New |
| `Cotabby/Services/Terminal/TerminalIntegrationService.swift` | New |
| `Cotabby/Services/Terminal/TerminalGeometryResolver.swift` | New |
| `Cotabby/Support/TerminalFocusAdapter.swift` | New |
| `Cotabby/Support/TerminalAppDetector.swift` | Modified |
| `Cotabby/App/Core/CotabbyAppEnvironment.swift` | Modified |
| `Cotabby/App/Core/AppDelegate.swift` | Modified |

### Step 1.1 — Build compiles

Verify all new and modified Swift files compile without errors.

```bash
cd /Users/tamima/Desktop/project/cotabby
xcodebuild -project Cotabby.xcodeproj -scheme Cotabby \
  -destination 'platform=macOS' build \
  -derivedDataPath build/DerivedData 2>&1 | tail -30
```

**Potential issue:** `TerminalGeometryResolver.swift` uses `proc_bsdinfo` /
`proc_pidinfo` from `<libproc.h>`. If these symbols are not found, change
`import Darwin.POSIX` to `import Darwin`.

**Gate:**
- [ ] `xcodebuild build` exits 0 with zero errors
- [ ] All four new files appear in the Cotabby target (not just the project)

### Step 1.2 — Socket creation and lifecycle

Build and run Cotabby (Debug), then verify the socket:

```bash
# While Cotabby is running:
ls -la "$HOME/Library/Application Support/Cotabby/terminal.sock"
# Expected: srw------- ... terminal.sock

# Quit Cotabby, then:
ls -la "$HOME/Library/Application Support/Cotabby/terminal.sock" 2>&1
# Expected: No such file or directory
```

**Gate:**
- [ ] Socket file exists while Cotabby is running
- [ ] Socket permissions are `0600` (owner read/write only)
- [ ] Socket file is deleted when Cotabby quits

### Step 1.3 — Socket accepts connections and parses JSON

Prerequisite: `brew install socat`

```bash
SOCKET="$HOME/Library/Application Support/Cotabby/terminal.sock"

# Valid buffer message
echo '{"type":"buffer","text":"git commit -m ","cursor":14,"shell":"zsh","terminal":"com.mitchellh.ghostty","pid":12345}' \
  | socat - "UNIX-CONNECT:${SOCKET}"

# Disconnect message
echo '{"type":"disconnect","shell":"zsh","terminal":"com.mitchellh.ghostty","pid":12345}' \
  | socat - "UNIX-CONNECT:${SOCKET}"

# Malformed JSON (must not crash Cotabby)
echo "this is not json" | socat - "UNIX-CONNECT:${SOCKET}"

# Empty line (must not crash)
echo "" | socat - "UNIX-CONNECT:${SOCKET}"
```

**Verify via Cotabby logs** (Xcode console or Console.app, subsystem
`com.cotabby.app`):
- Buffer message: session created log with pid/shell/terminal
- Disconnect: session removed log
- Malformed JSON: decode error log, no crash

**Gate:**
- [ ] All `socat` sends exit 0 (or close gracefully)
- [ ] Cotabby does not crash on any input
- [ ] Logs confirm correct parsing of valid messages
- [ ] Session appears after buffer message, removed after disconnect

---

## Phase 2: Shell Hooks

**Goal:** Both shell hooks load without errors, detect the hosting terminal, and
send IPC messages to the socket.

### Files involved

| File | Status |
|------|--------|
| `scripts/shell-integration/cotabby.zsh` | New |
| `scripts/shell-integration/cotabby.bash` | New |

### Step 2.1 — Syntax validation

```bash
bash -n scripts/shell-integration/cotabby.bash && echo "bash: OK"
zsh  -n scripts/shell-integration/cotabby.zsh  && echo "zsh: OK"
```

**Gate:**
- [ ] Both exit 0 with no output

### Step 2.2 — Terminal bundle ID detection

```bash
# Ghostty via TERM_PROGRAM
(
  export TERM_PROGRAM=ghostty; unset __CFBundleIdentifier COTABBY_SHELL_INTEGRATION_LOADED
  source scripts/shell-integration/cotabby.bash 2>/dev/null
  [[ "$_cotabby_terminal_bundle_id" == "com.mitchellh.ghostty" ]] && echo "PASS" || echo "FAIL: $_cotabby_terminal_bundle_id"
)

# VS Code via TERM_PROGRAM
(
  export TERM_PROGRAM=vscode; unset __CFBundleIdentifier COTABBY_SHELL_INTEGRATION_LOADED
  source scripts/shell-integration/cotabby.bash 2>/dev/null
  [[ "$_cotabby_terminal_bundle_id" == "com.microsoft.VSCode" ]] && echo "PASS" || echo "FAIL: $_cotabby_terminal_bundle_id"
)

# __CFBundleIdentifier takes precedence
(
  export __CFBundleIdentifier="com.googlecode.iterm2" TERM_PROGRAM="other"
  unset COTABBY_SHELL_INTEGRATION_LOADED
  source scripts/shell-integration/cotabby.bash 2>/dev/null
  [[ "$_cotabby_terminal_bundle_id" == "com.googlecode.iterm2" ]] && echo "PASS" || echo "FAIL: $_cotabby_terminal_bundle_id"
)
```

**Note on Claude Code:** Claude Code runs as a Node.js process inside a
terminal. It inherits the parent terminal's `TERM_PROGRAM` /
`__CFBundleIdentifier`. The hook correctly reports the hosting terminal (e.g.,
Ghostty), not "Claude Code". This is correct — Cotabby positions the overlay on
the terminal window.

**Gate:**
- [ ] Ghostty detected via `TERM_PROGRAM`
- [ ] VS Code detected via `TERM_PROGRAM`
- [ ] `__CFBundleIdentifier` takes precedence when both are set

### Step 2.3 — JSON escaping edge cases

```bash
(
  export TERM_PROGRAM=ghostty; unset __CFBundleIdentifier COTABBY_SHELL_INTEGRATION_LOADED
  source scripts/shell-integration/cotabby.bash 2>/dev/null

  # Backslash
  r=$(_cotabby_escape_json 'hello\world')
  [[ "$r" == 'hello\\world' ]] && echo "PASS: backslash" || echo "FAIL: backslash"

  # Double quote
  r=$(_cotabby_escape_json 'say "hi"')
  [[ "$r" == 'say \"hi\"' ]] && echo "PASS: dquote" || echo "FAIL: dquote"

  # Tab
  r=$(_cotabby_escape_json $'hello\tworld')
  [[ "$r" == 'hello\tworld' ]] && echo "PASS: tab" || echo "FAIL: tab"

  # Newline
  r=$(_cotabby_escape_json $'hello\nworld')
  [[ "$r" == 'hello\nworld' ]] && echo "PASS: newline" || echo "FAIL: newline"
)
```

**Gate:**
- [ ] All four escaping cases pass

### Step 2.4 — Hooks send messages to the socket (manual)

Requires Cotabby running + a supported terminal.

**Zsh (primary — macOS default shell):**

1. Open Ghostty (or any supported terminal).
2. `source /path/to/scripts/shell-integration/cotabby.zsh`
3. Expected output: `[cotabby] Shell integration loaded for com.mitchellh.ghostty (pid XXXXX)`
4. Type `git sta` — check Xcode console for session creation and buffer updates.

**Bash:**

1. In the same terminal: `bash`
2. `source /path/to/scripts/shell-integration/cotabby.bash`
3. Type `ls -la` — check logs for `shell=bash` session.

**VS Code:**

1. Open VS Code → integrated terminal.
2. Source the hook (zsh or bash).
3. Type commands — logs should show `terminal=com.microsoft.VSCode`.

**Double-load guard:**

```bash
source scripts/shell-integration/cotabby.zsh
source scripts/shell-integration/cotabby.zsh
# Only ONE "[cotabby] Shell integration loaded" message should appear
```

**Gate:**
- [ ] Hook loads without errors in each shell
- [ ] Double-source is a no-op
- [ ] IPC messages reach the socket (confirmed via Cotabby logs)
- [ ] Correct terminal bundle ID appears in logs for each terminal tested

---

## Phase 3: Focus Bridge

**Goal:** Terminal snapshots flow through the full chain into the suggestion
pipeline, AX polling is suppressed during terminal focus, and the adapter
produces valid `FocusedInputSnapshot` values.

### Files involved

| File | Role |
|------|------|
| `Cotabby/Models/FocusTrackingModel.swift` | Snapshot injection + AX suppression |
| `Cotabby/Support/TerminalFocusAdapter.swift` | Snapshot conversion |
| `Cotabby/Support/SuggestionAvailabilityEvaluator.swift` | Terminal gating |
| `Cotabby/App/Core/CotabbyAppEnvironment.swift` | Wiring callbacks |

### Step 3.1 — Unit tests for TerminalFocusAdapter

Create `CotabbyTests/TerminalFocusAdapterTests.swift` with these test cases:

```swift
// 1. Zsh snapshot: cursor offset is character-based, passed through
//    - commandBuffer="git ", cursorOffset=4, shellType=.zsh
//    - Assert adapted.precedingText == "git "
//    - Assert adapted.trailingText == ""

// 2. Bash snapshot: byte offset → character offset conversion
//    - commandBuffer="echo 日本語", cursorOffset=5, shellType=.bash
//    - Assert adapted.precedingText == "echo "

// 3. Application name mapping
//    - terminalBundleIdentifier="com.mitchellh.ghostty"
//    - Assert adapted.applicationName == "Ghostty"

// 4. Caret rect uses estimated cursor position when available
//    - estimatedCursorPosition = CGPoint(x: 100, y: 200)
//    - Assert caret rect origin is near (100, 200)

// 5. Caret rect fallback to window frame bottom when no cursor position
//    - estimatedCursorPosition = nil, terminalWindowFrame = some rect
//    - Assert caret rect is near bottom of window frame
```

Run:

```bash
xcodebuild -project Cotabby.xcodeproj -scheme Cotabby \
  -destination 'platform=macOS' test \
  -only-testing:CotabbyTests/TerminalFocusAdapterTests \
  -derivedDataPath build/DerivedData 2>&1 | tail -20
```

### Step 3.2 — Unit tests for SuggestionAvailabilityEvaluator (terminal gating)

**Update existing test:** `CotabbyTests/TerminalAppDetectorTests.swift` — the
test `test_evaluator_blocksTerminalApp` expects the old string `"Cotabby is not
available in terminal apps."` but the new code returns a longer string mentioning
shell integration. Update the assertion.

**Add new tests:**

```swift
// test_evaluator_allowsTerminalWithShellIntegration
//   - FocusSnapshot for a terminal bundle ID
//   - terminalIntegrationActive: true
//   - Assert disabledReason == nil

// test_evaluator_blocksTerminalWithoutShellIntegration
//   - FocusSnapshot for a terminal bundle ID
//   - terminalIntegrationActive: false
//   - Assert disabledReason contains "shell integration"
```

Run:

```bash
xcodebuild -project Cotabby.xcodeproj -scheme Cotabby \
  -destination 'platform=macOS' test \
  -only-testing:CotabbyTests/TerminalAppDetectorTests \
  -derivedDataPath build/DerivedData 2>&1 | tail -20
```

### Step 3.3 — Manual verification: snapshot injection

1. Run Cotabby (Debug), set breakpoint at `FocusTrackingModel.injectTerminalSnapshot`.
2. Send a buffer message via socat.
3. Breakpoint hit → snapshot injected.
4. Observe Cotabby's menu bar shows the terminal app name and "Supported".

### Step 3.4 — Manual verification: AX suppression

1. Open Ghostty, source the hook, type a few chars (terminal mode active).
2. Switch to TextEdit — type text.
3. Verify: normal AX suggestions appear in TextEdit (AX suppression cleared).
4. Switch back to Ghostty — verify terminal mode re-activates.

**Gate:**
- [ ] All adapter unit tests pass
- [ ] Updated evaluator tests pass
- [ ] Terminal snapshots flow through the full chain (breakpoint confirms)
- [ ] AX polling resumes when switching away from the terminal
- [ ] Menu bar reflects terminal app name during terminal focus

---

## Phase 4: Ghost Text Overlay

**Goal:** Ghost text appears in the terminal window at a reasonable position.

### Files involved

| File | Role |
|------|------|
| `Cotabby/Services/Terminal/TerminalGeometryResolver.swift` | Cursor estimation |

### Step 4.1 — Unit tests for TerminalGeometryResolver

Create `CotabbyTests/TerminalGeometryResolverTests.swift`:

```swift
// 1. estimatedCursorRect with typical values
//    - windowFrame = (100, 100, 800, 600), row=5, col=10
//    - Assert result is inside the window bounds

// 2. row=1, col=1 should be near top-left of content area
//    - Assert result.origin.x ≈ windowFrame.minX + 4 (left inset)
//    - Assert result.origin.y ≈ windowFrame.minY + 28 (title bar)

// 3. fallbackCursorRect is near bottom of window
//    - Assert result.origin.y > windowFrame.midY

// 4. enrichWithGeometry with non-existent PID: no crash, snapshot unchanged
```

### Step 4.2 — Manual overlay test in Ghostty

1. Build and run Cotabby (Debug).
2. Open Ghostty, source the hook.
3. Type `git com` — wait for suggestion generation.
4. Observe:
   - Does ghost text appear?
   - Is it near the cursor (approximately right of typed text)?
   - Does it follow typing?
   - Does it dismiss on Escape / cursor move?

**Known limitation:** The shell hooks do not currently send `row`/`col` fields.
The overlay will use fallback positioning (bottom of window). This is functional
since the prompt is typically near the bottom. Pixel-perfect positioning is a
Phase 7 enhancement.

### Step 4.3 — Manual overlay test in VS Code terminal

1. Open VS Code → integrated terminal (bottom pane, default layout).
2. Source the hook, type a partial command.
3. Overlay should appear within the VS Code window.

**Known limitation:** The AX window frame is the entire VS Code window, not just
the terminal pane. The fallback cursor rect targets the bottom of the window,
which coincidentally is where the terminal pane usually is.

**Gate:**
- [ ] Geometry unit tests pass
- [ ] Ghost text appears in Ghostty (even if not pixel-perfect)
- [ ] Ghost text appears in VS Code terminal
- [ ] Overlay does not appear in the wrong window
- [ ] Overlay dismisses when suggestion is cancelled
- [ ] Overlay does not persist after switching away from the terminal

---

## Phase 5: Text Insertion

**Goal:** Accepting a suggestion inserts the text into the terminal command
buffer correctly.

### Files involved

| File | Role |
|------|------|
| `Cotabby/Services/Suggestion/SuggestionInserter.swift` | Clipboard paste mode |
| `Cotabby/Models/SuggestionSettingsModel.swift` | Acceptance key settings |
| `scripts/shell-integration/cotabby.zsh` | Right-arrow acceptance widget |

### Step 5.1 — Clipboard paste insertion (manual)

1. Run Cotabby, open Ghostty, source the hook.
2. Copy known text to clipboard: `echo "canary" | pbcopy`
3. Type `git com` — wait for suggestion.
4. Press the acceptance key (right arrow).
5. Verify:
   - Suggestion text inserted into terminal buffer.
   - After ~200ms, check clipboard: `pbpaste` should return "canary" (restored).

### Step 5.2 — Zsh right-arrow direct acceptance (manual)

The zsh hook has a `_cotabby_forward_char` widget that reads the suggestion
directly from `~/Library/Application Support/Cotabby/terminal-suggestion.txt`
and appends it to `$BUFFER` — bypassing CGEvent entirely.

1. Run Cotabby, open Ghostty with zsh, source the hook.
2. Type a partial command, wait for ghost text.
3. Press right arrow.
4. Verify: suggestion text appears in the zsh buffer (not via paste).
5. Verify: suggestion file is deleted after acceptance.

**Test right-arrow works normally without a suggestion:**

1. Type `echo hello`, press left arrow 5 times (cursor before "hello").
2. Press right arrow.
3. Verify: cursor moves right one character (normal behavior).

### Step 5.3 — Bash acceptance (manual)

Bash does not have zsh's `zle` widget mechanism. Acceptance relies on the
clipboard paste from `SuggestionInserter.insertForTerminal`.

1. In Ghostty: `bash`
2. Source the bash hook.
3. Type partial command, wait for suggestion.
4. Press acceptance key.
5. Verify: text inserted via clipboard paste.

### Step 5.4 — Edge cases

- **Empty suggestion:** should not crash or paste anything.
- **Multi-line suggestion:** `\r` characters should be stripped for shell
  compatibility (the inserter normalizes CRLF → LF).
- **Rapid acceptance:** accept 3+ suggestions in quick succession. The 150ms
  clipboard restore delay should not cause race conditions.

**Gate:**
- [ ] Suggestion text appears in terminal after acceptance
- [ ] Original clipboard is restored
- [ ] Zsh right-arrow direct acceptance works
- [ ] Right-arrow at non-EOL position moves cursor normally
- [ ] No crash or hang during insertion
- [ ] Edge cases (empty, multi-line, rapid) do not break

---

## Phase 6: End-to-End Per-App Testing

**Goal:** Full flow works in each target terminal. No regressions in
non-terminal apps.

### 6.1 — Ghostty full flow

| Step | Action | Expected |
|------|--------|----------|
| 1 | Launch Cotabby, open Ghostty | Socket exists |
| 2 | Source zsh hook | `[cotabby] Shell integration loaded` |
| 3 | Type `git com` | Ghost text appears |
| 4 | Type more characters | Ghost text updates |
| 5 | Press right arrow | Suggestion inserted |
| 6 | Press Enter | Command executes normally |
| 7 | Open new Ghostty tab | New session (new PID) in logs |
| 8 | Close that tab | Session disconnected in logs |
| 9 | Switch to TextEdit, type | Normal AX suggestions work |
| 10 | Switch back to Ghostty | Terminal mode re-activates |

### 6.2 — VS Code integrated terminal

| Step | Action | Expected |
|------|--------|----------|
| 1 | Open VS Code, open integrated terminal | |
| 2 | Source shell hook | `[cotabby] ... com.microsoft.VSCode` |
| 3 | Type partial command | Ghost text appears |
| 4 | Accept suggestion | Text inserted |
| 5 | Click into a `.swift` file in editor | Normal AX suggestions resume* |
| 6 | Click back to terminal, type | Terminal mode re-activates |

**\*Known limitation:** There is a delay (up to ~30s) when switching from VS
Code's terminal pane to its editor pane before AX suggestions resume. This is
because `terminalInjectedBundleIdentifier` suppresses AX for
`com.microsoft.VSCode` until the session timeout fires. See "Known Issues"
section for fix options.

### 6.3 — Claude Code

Claude Code is a CLI tool that runs inside a terminal. It has its own input
handling (line editor).

| Step | Action | Expected |
|------|--------|----------|
| 1 | Open Ghostty, source the hook | Hook active |
| 2 | Type `claude` to start Claude Code | |
| 3 | Type inside Claude Code | Cotabby does NOT show suggestions* |
| 4 | Exit Claude Code | |
| 5 | Type at shell prompt | Suggestions resume |

**\*Why:** While Claude Code is running, the user types into Claude Code's
interface, not into the shell. The shell hook does not fire (no `$BUFFER`
changes). This is correct behavior — Cotabby should not interfere with Claude
Code's own input handling.

### 6.4 — Non-terminal app regression test

Run each with terminal integration enabled and a shell hook session active in a
background Ghostty window:

| App | Action | Expected |
|-----|--------|----------|
| TextEdit | Type text | Ghost text suggestions appear normally |
| Safari | Type in search / Google Docs | Suggestions work |
| Notes | Type text | Suggestions work |
| Slack | Type message | Suggestions work |

Switching between Ghostty and these apps should cleanly transition between
terminal and AX modes.

**Gate:**
- [ ] Ghostty full flow: all 10 steps pass
- [ ] VS Code terminal: all 6 steps pass (with documented delay caveat)
- [ ] Claude Code: does not interfere, suggestions resume after exit
- [ ] Non-terminal apps: no regressions in at least 2 apps

---

## Phase 7: Settings UI and Polish

**Goal:** User-facing settings, installation instructions, and production
readiness.

### 7.1 — Terminal integration toggle

Add a "Terminal Integration" section to the Settings UI:
- Toggle for `isTerminalIntegrationEnabled` (persisted in
  `SuggestionSettingsModel`)
- When off: socket server still runs but snapshots are ignored

Verify:
- [ ] Toggle off → terminal suggestions stop immediately
- [ ] Toggle on → terminal suggestions resume
- [ ] Setting persists across app restarts

### 7.2 — Acceptance key customization

- Key recorder for the terminal acceptance key (default: right arrow, code 124)
- Display current key label
- Reset to default button

Verify:
- [ ] Changing key takes effect immediately
- [ ] Key label updates in UI
- [ ] Custom keys (e.g., Option+Tab) work

### 7.3 — Bundle shell scripts into app

The scripts are currently at `scripts/shell-integration/`. For distribution,
they must ship inside the `.app` bundle.

1. Edit `project.yml` to add a Copy Files build phase:
   - Source: `scripts/shell-integration/cotabby.bash`,
     `scripts/shell-integration/cotabby.zsh`
   - Destination: `Resources/shell-integration/`
2. Run `xcodegen generate` and rebuild.
3. Verify scripts appear in the built app:

```bash
ls build/DerivedData/Build/Products/Debug/Cotabby.app/Contents/Resources/shell-integration/
# Expected: cotabby.bash  cotabby.zsh
```

### 7.4 — Installation instructions

Add an in-app panel or Settings section with copy-paste commands:

```
# For zsh (add to ~/.zshrc):
[[ -f "/Applications/Cotabby.app/Contents/Resources/shell-integration/cotabby.zsh" ]] && \
  source "/Applications/Cotabby.app/Contents/Resources/shell-integration/cotabby.zsh"

# For bash (add to ~/.bashrc or ~/.bash_profile):
[[ -f "/Applications/Cotabby.app/Contents/Resources/shell-integration/cotabby.bash" ]] && \
  source "/Applications/Cotabby.app/Contents/Resources/shell-integration/cotabby.bash"

# Prerequisite:
brew install socat
```

### 7.5 — Cursor positioning enhancement (optional)

The shell hooks do not currently send `row`/`col`. Add cursor position
estimation to the hooks:

**Zsh:**
```zsh
local _row _col
# Use ANSI DSR (Device Status Report) — fragile but possible
# Simpler: estimate from $CURSOR and $COLUMNS
_row=$(( (CURSOR / COLUMNS) + 1 ))
_col=$(( (CURSOR % COLUMNS) + 1 ))
```

**Limitation:** This gives the line within the command buffer, not the absolute
terminal row. The absolute row depends on where the prompt was printed, which is
not easily available. This remains approximate.

**Gate:**
- [ ] Settings UI toggle works
- [ ] Acceptance key customization works
- [ ] Shell scripts bundled in `.app`
- [ ] Installation instructions are clear and copy-pasteable

---

## Known Issues

### 1. Row/column not sent by shell hooks

The `TerminalIpcMessage` struct supports `row` and `col` fields but the hooks
don't send them. Ghost text uses fallback positioning (bottom of window). This
is functional since the prompt is typically at the bottom, but not pixel-perfect.

### 2. VS Code AX suppression gap

When switching from VS Code's terminal pane to its editor pane,
`terminalInjectedBundleIdentifier` suppresses AX polling for `com.microsoft.VSCode`
for up to 30 seconds (the session timeout). During this time, the user gets no
suggestions in VS Code's editor.

**Fix options (pick one):**
- Reduce `sessionTimeoutSeconds` to 3-5 seconds
- Add a recency check: only suppress AX if last IPC message was within 2 seconds
- Detect AX element role changes: if AX reports a `.supported` text field
  (editor), clear suppression immediately

### 3. Bash keystroke coverage

The bash hook uses `bind -x` for specific keys plus `PROMPT_COMMAND`. Regular
character typing (`self-insert`) does not immediately trigger a buffer report —
state lags until the next bound key or prompt redraw. Enhancement: explore
binding to more keys or using a timer.

### 4. socat dependency

Both hooks require `socat` for socket communication. This is a runtime
dependency (`brew install socat`). Alternatives: Python socket script, or
`/dev/tcp` in bash 4+ (not available in macOS default bash 3.2).

### 5. Existing test string update

`CotabbyTests/TerminalAppDetectorTests.swift` —
`test_evaluator_blocksTerminalApp` expects the old disabled reason string. Must
update to match the new message mentioning shell integration.

---

## Test Script

A comprehensive automated test script lives at:

```
scripts/test-terminal-integration.sh
```

Run it with Cotabby launched:

```bash
bash scripts/test-terminal-integration.sh
```

It validates: prerequisites, socket IPC, shell hook syntax/detection/escaping,
multi-session handling, stress test (50 rapid messages), and per-app bundle ID
acceptance. See the script for details.
