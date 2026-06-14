# Implementation Plan — Terminal & Claude Code Autocomplete + Per‑App Shortcuts

**Status:** In progress — Sub‑plans A, B (B.1–B.3), C, and D landed in this branch and the
acceptance E2E is green for zsh + bash across Terminal.app / Ghostty / VS Code (buffer goes
`text` → `text + completion` through the full live pipeline). fish and the Claude Code TUI
detection are still under test — see **E2E acceptance status** at the bottom.
Outstanding work tracked at the bottom of this file under **Landed vs. outstanding**.
**Owner:** _unassigned_
**Scope:** Two related goals shipped together:

1. **Make Cotabby autocomplete work in terminals**, both at the **shell prompt** (zsh / bash / fish) and **inside the Claude Code TUI** running in a terminal.
2. **Add a settings UI for per‑app shortcuts**, where each app can have its own accept/trigger shortcut, and **falls back to the global shortcut when no per‑app override is set**.

This document is organized as a set of self‑contained **sub‑plans**. Each sub‑plan lists its objective, the frontend (SwiftUI/AppKit) and backend (services/models/support) work, the concrete files to touch, and its testing strategy. A consolidated testing sub‑plan (Sub‑plan E) and a sequencing/rollout sub‑plan (Sub‑plan F) tie everything together.

> Read this alongside `.claude/CLAUDE.md`. Cotabby is stateful, permission‑heavy, and tied to macOS Accessibility timing. Prefer pure helpers in `Cotabby/Support/` before touching services, coordinators, or SwiftUI views, and keep changes narrow.

---

## 1. Current State (what already exists)

Before adding anything, here is the ground truth in the repo today. **A large part of the shell‑prompt terminal path is already built** — the work is finishing and hardening it, not starting from scratch.

### Terminal shell‑integration (partially built)

| Piece | File | State |
|---|---|---|
| Unix‑socket server that shell hooks connect to | `Cotabby/Services/Terminal/TerminalIntegrationService.swift` | **Built**, started/stopped in `AppDelegate` (`terminalIntegrationService.start()` / `.stop()`) |
| Terminal classification (`blocked` / `shellIntegration` / `nonTerminal`) | `Cotabby/Support/TerminalAppDetector.swift` | **Built**, knows 9 terminal bundle IDs |
| IPC + snapshot value types | `Cotabby/Models/TerminalFocusModels.swift` | **Built** (`TerminalIpcMessage`, `TerminalFocusSnapshot`, `TerminalSession`, `ShellType`) |
| Terminal → `FocusedInputSnapshot` adapter | `Cotabby/Support/TerminalFocusAdapter.swift` | **Built** |
| Cursor geometry estimation | `Cotabby/Services/Terminal/TerminalGeometryResolver.swift` | **Built** |
| Wiring into the suggestion pipeline | `Cotabby/App/Core/CotabbyAppEnvironment.swift` (`onSnapshotUpdate`, `onSessionChange`, `terminalIntegrationActiveProvider`) | **Built** |
| Terminal‑specific accept key (`→` default) | `SuggestionSettingsModel.terminalAcceptanceKey*` | **Built** (model only; partial UI) |
| Terminal insertion via clipboard paste (Cmd+V, bracketed paste) | `Cotabby/Services/Suggestion/SuggestionInserter.swift` | **Built** |
| zsh hook | `scripts/shell-integration/cotabby.zsh` | **Built**, but depends on `socat`, uses a file‑based right‑arrow accept hack |
| bash hook | `scripts/shell-integration/cotabby.bash` | **Built**, same `socat` dependency |
| fish hook | — | **Missing** |
| E2E smoke scripts | `scripts/test-terminal-integration.sh`, `scripts/test-terminal-e2e.sh` | **Built** (incl. a "Claude Code non‑interference" check) |
| Unit tests | `CotabbyTests/TerminalAppDetectorTests.swift`, `TerminalFocusAdapterTests.swift`, `TerminalGeometryResolverTests.swift` | **Built** |

### Per‑app behavior (only enable/disable exists)

| Piece | File | State |
|---|---|---|
| Per‑app **disable** rules | `SuggestionSettingsModel.disabledAppRules` + `Cotabby/UI/Settings/Panes/AppsPaneView.swift` | **Built** |
| Global accept / full‑accept / toggle shortcuts | `SuggestionSettingsModel` (`acceptanceKey*`, `fullAcceptanceKey*`, `globalToggleKey*`) + `Cotabby/UI/Settings/Panes/ShortcutsPaneView.swift` | **Built** |
| Key recorder widget | `Cotabby/UI/KeyRecorderView.swift` | **Built** |
| Event‑time shortcut resolution (closures) | `Cotabby/Services/Input/InputMonitor.swift` (`acceptanceKeyCodeProvider`, etc.), assigned in `CotabbyAppEnvironment` | **Built** |
| **Per‑app shortcut overrides** | — | **Missing** — this is the new feature |

### The Claude Code problem (the genuinely new work)

The shell hooks report the shell's editable line buffer (`$BUFFER` / `READLINE_LINE`) via zsh `zle` widgets and bash `bind -x`. **Those hooks do not fire while a full‑screen TUI like Claude Code owns the terminal** — the `cotabby.zsh` hook even comments on this ("after a subprocess (e.g. Claude Code) takes over stdin and exits, zle resumes"). The existing E2E test only checks that Cotabby **does not interfere** with Claude Code, not that it autocompletes inside it.

So: **the shell‑prompt path cannot see inside the Claude Code input box.** Making autocomplete appear inside Claude Code requires a separate path that reads the on‑screen prompt text via **screen capture + OCR** (Cotabby already has `ScreenTextExtractor`, `WindowScreenshotService`, `ScreenshotContextGenerator`, `VisualContextCoordinator`) and inserts via the existing clipboard‑paste terminal path. That is Sub‑plan C, and it is the hardest part.

---

## 2. Architecture Overview

```
                         ┌──────────────────────────────────────────────┐
                         │            SuggestionCoordinator              │
                         │  (state machine: focus → predict → overlay →  │
                         │   accept)  — consumes FocusedInputSnapshot     │
                         └──────────────────────────────────────────────┘
                                      ▲                 ▲
              FocusedInputSnapshot    │                 │  FocusedInputSnapshot
                                      │                 │
        ┌─────────────────────────────┘                 └──────────────────────────────┐
        │                                                                               │
┌───────────────┐      ┌──────────────────────────┐                     ┌──────────────────────────┐
│  AX pipeline  │      │  Shell‑prompt pipeline    │                     │  Claude Code TUI pipeline │
│ FocusTracker  │      │  TerminalIntegration‑     │                     │  (NEW — Sub‑plan C)        │
│ + resolvers   │      │  Service ← shell hooks     │                     │  TuiContextReader:         │
│ (normal apps) │      │  → TerminalFocusAdapter    │                     │  screenshot + OCR of the   │
└───────────────┘      └──────────────────────────┘                     │  Claude Code input line    │
        │                          │                                      │  → TuiFocusAdapter          │
        └──────────────┬───────────┴──────────────────────────┬──────────┘
                       │                                       │
              ┌────────────────────┐               ┌────────────────────────────┐
              │  ShortcutResolver  │ ◄──────────── │  per‑app override → global  │
              │  (NEW — Sub‑plan A)│   resolves    │  fallback (Sub‑plan A)       │
              └────────────────────┘               └────────────────────────────┘
                       │
              ┌────────────────────┐
              │  SuggestionInserter│  (AX synthetic keys  |  terminal clipboard paste)
              └────────────────────┘
```

Three input sources all converge on the same `FocusedInputSnapshot` shape and the same coordinator. Per‑app shortcut resolution sits in front of the `InputMonitor` providers and is independent of which source produced the snapshot.

---

## Sub‑plan A — Per‑App Configurable Shortcuts (with global fallback)

**Objective.** Let the user assign an accept shortcut (and optionally full‑accept) per application. When the frontmost app has an override, the `InputMonitor` uses it; otherwise it falls back to the global shortcut already configured in the Shortcuts pane. Surfaced in a settings UI alongside the existing per‑app disable list.

This is the most self‑contained sub‑plan and a good first milestone because it does not depend on terminal work.

### A.1 Data model (backend)

Create a pure, codable value type for a per‑app override and store a keyed collection on the settings model.

- **New file:** `Cotabby/Models/PerAppShortcutOverride.swift`
  ```
  struct PerAppShortcutOverride: Codable, Equatable, Identifiable, Sendable {
      let bundleIdentifier: String
      let displayName: String
      // nil for any field means "inherit the global binding for that action"
      var acceptKeyCode: CGKeyCode?
      var acceptKeyModifiers: ShortcutModifierMask?
      var acceptKeyLabel: String?
      var fullAcceptKeyCode: CGKeyCode?
      var fullAcceptKeyModifiers: ShortcutModifierMask?
      var fullAcceptKeyLabel: String?
      var id: String { bundleIdentifier }
  }
  ```
  Using optionals (rather than always storing a value) is what makes "no custom shortcut → use the global shortcut" a first‑class state instead of a sentinel.

- **Edit:** `Cotabby/Models/SuggestionSettingsModel.swift`
  - Add `@Published private(set) var perAppShortcutOverrides: [PerAppShortcutOverride]`.
  - Add a UserDefaults key `cotabbyPerAppShortcutOverrides` and follow the exact load/sanitize/persist pattern already used by `disabledAppRules` (JSON‑encode, dedupe by bundle id, normalize names, drop empties).
  - Add mutators mirroring the existing shortcut setters: `setPerAppAcceptKey(bundleIdentifier:displayName:keyCode:modifiers:label:)`, `clearPerAppAcceptKey(bundleIdentifier:)`, `setPerAppFullAcceptKey(...)`, `removePerAppOverride(bundleIdentifier:)`.
  - Keep the "absent vs empty" UserDefaults discipline already documented in this file so migrations stay clean.

### A.2 Resolution logic (backend, pure + testable)

The resolution rule (frontmost override → else global) must be a **pure function** in `Support/` so it can be unit‑tested without the event tap.

- **New file:** `Cotabby/Support/ShortcutResolver.swift`
  ```
  enum ShortcutResolver {
      struct ResolvedBinding: Equatable { let keyCode: CGKeyCode; let modifiers: ShortcutModifierMask }

      static func acceptBinding(
          frontmostBundleIdentifier: String?,
          overrides: [PerAppShortcutOverride],
          globalKeyCode: CGKeyCode,
          globalModifiers: ShortcutModifierMask
      ) -> ResolvedBinding { /* override if present else global */ }

      // analogous fullAcceptBinding(...)
  }
  ```
  Precedence (highest first): **terminal‑specific binding** (existing, when a shell‑integration session is active) → **per‑app override** → **global**. Document this ordering in the file header; it is the single source of truth.

- **Edit:** `Cotabby/App/Core/CotabbyAppEnvironment.swift`
  - The `InputMonitor` providers (`acceptanceKeyCodeProvider`, `acceptanceKeyModifiersProvider`, `fullAcceptanceKeyCodeProvider`, `fullAcceptanceKeyModifiersProvider`) are already closures resolved at event time and already do terminal‑aware resolution here. Extend those same closures to call `ShortcutResolver`, passing the frontmost bundle id (from `focusModel`) and `suggestionSettings.perAppShortcutOverrides`.
  - Important: resolution must run **at event time** (inside the closure), not be cached, because the frontmost app changes constantly. This matches how terminal resolution already works.

- **Edit (hint label):** `SuggestionSettingsModel.acceptanceHintLabel` and the overlay keycap currently show the global label. Decide whether the ghost‑text hint should reflect the per‑app label for the frontmost app. Recommended: yes — compute the hint from the resolved binding so the pill teaches the key that will actually work. This needs the frontmost bundle id available where the hint is built; thread it through or expose a `resolvedAcceptanceHintLabel(forBundleIdentifier:)` helper.

### A.3 Settings UI (frontend)

Surface overrides in the existing **Apps** pane (preferred — keeps all per‑app config in one place) or a dedicated subsection. Reuse the existing `KeyRecorderView` and the `KeybindRow` chrome pattern from `ShortcutsPaneView`.

- **Edit:** `Cotabby/UI/Settings/Panes/AppsPaneView.swift`
  - Add a **"Per‑App Shortcuts"** section above or below "Disabled Apps".
  - Row per override: app icon + name, the resolved accept binding shown as a badge, a **Change** button (opens `KeyRecorderView`), and a **Reset to global** button that clears the override (sets the optional fields back to `nil`) — this is the explicit "fall back to the global shortcut" affordance.
  - An **"Add App…"** button reusing the existing `NSOpenPanel` + `ApplicationBundleMetadata` flow already in this file for the disabled list, plus the running‑app quick‑suggestion chips already implemented (`RunningAppSuggestion.collect()`).
  - Empty/inherit state copy: when no override exists, show "Uses global shortcut (`<label>`)" so the fallback is visible, not hidden.
- **Optional new component:** factor the `KeybindRow` private struct out of `ShortcutsPaneView.swift` into `Cotabby/UI/Settings/Components/KeybindRow.swift` so both panes share it (avoids divergence).
- **Conflict checking:** reuse `SuggestionSettingsModel.conflictingShortcutName(...)`. Extend the conflict model so a per‑app override is only checked against the **same app's** other binding and the global terminal/toggle keys, not against unrelated apps (two different apps may use the same key). Document this scoping decision in code.

### A.4 Tests (Sub‑plan A)

- **New:** `CotabbyTests/ShortcutResolverTests.swift` — table‑driven: override present vs absent; partial override (accept set, full‑accept inherited); terminal binding precedence over per‑app; per‑app precedence over global; unknown/nil bundle id → global.
- **New:** `CotabbyTests/PerAppShortcutOverrideStoreTests.swift` — load/sanitize/persist round‑trips on a fresh `UserDefaults(suiteName:)`; dedupe by bundle id; drop empty/whitespace; migration when key absent.
- **Extend:** `CotabbyTests/ShortcutConflictTests.swift` — per‑app conflict scoping (same app conflicts; different apps don't).
- **Acceptance criteria:** With an override set for App X and none for App Y, the resolved accept key differs by frontmost app; clearing X's override restores the global key for X.

---

## Sub‑plan B — Finish & Harden the Shell‑Prompt Terminal Path

**Objective.** Make autocomplete reliable when typing commands at the zsh/bash/fish prompt in real terminals, without fragile external dependencies. This is the foundation Claude Code support (Sub‑plan C) builds on.

### B.1 Remove the `socat` dependency (backend/scripts)

Today both hooks shell out to `socat` to write to the Unix socket. That is an extra `brew install` and a per‑keystroke subprocess spawn (latency + noise).

- **Preferred:** replace `socat` with a tiny bundled helper Cotabby ships, e.g. `cotabby-notify`, that opens the socket and writes one line. Options, in order of preference:
  1. Use the shell's own networking: zsh can open a socket via `zsh/net/socket` module (`zmodload zsh/net/socket`); bash can use `/dev/tcp`‑style redirection only for TCP, not Unix sockets, so bash still needs a helper.
  2. Ship a ~30‑line compiled helper binary (Swift or C) inside the app bundle and reference it by absolute path from the hook. This also removes the `socat` install step from onboarding.
- **Edit:** `scripts/shell-integration/cotabby.zsh`, `cotabby.bash`; **document** the chosen mechanism in `TerminalIntegrationService.swift`'s header so client and server stay in sync.
- **Decision needed:** helper binary vs shell‑native socket. Recommend the bundled helper for uniformity across shells.

### B.2 Add fish support (scripts/backend)

- **New file:** `scripts/shell-integration/cotabby.fish` — use fish's `commandline` builtin to read buffer + cursor, and an event handler (`function --on-event fish_prompt` and a key‑binding wrapper) to report on edits. `ShellType.fish` already exists in `TerminalFocusModels.swift` and `TerminalFocusAdapter` already treats fish cursor offset as a character offset, so no model change is needed.
- **Test:** extend `scripts/test-terminal-integration.sh` with a fish branch.

### B.3 Replace the file‑based right‑arrow accept hack (backend)

Today acceptance inside zsh is done by Cotabby writing `terminal-suggestion.txt` and the hook reading it on right‑arrow. This is racy (file polling) and shell‑specific.

- Move acceptance to the **per‑app/terminal resolved shortcut** + the existing clipboard‑paste insertion path (`SuggestionInserter` terminal mode) so all surfaces accept the same way. Keep the right‑arrow shell‑side accept only as a documented fallback for terminals where CGEvent insertion is unreliable (Ghostty/kitty keyboard protocol).
- Reconcile with the `terminalAcceptanceKey` setting (default `→`) so the configured key and the shell binding agree.

### B.4 Geometry & overlay verification (backend/frontend)

- `TerminalGeometryResolver` estimates the caret from reported row/column + default cell metrics; `caretQuality` is `.estimated`, which routes to the popup/mirror card rather than precise inline ghost text. Verify the overlay actually appears at the right place in each terminal and tune `defaultCellMetrics`, or read real cell metrics where the terminal exposes them.
- Confirm `MirrorPreference`/`CompletionRenderModePolicy` produces a sensible presentation for `.estimated` terminal carets.

### B.5 Onboarding / install UX (frontend)

- The shell hook must be sourced from the user's `.zshrc`/`.bashrc`/`config.fish`. Add a one‑click "Install shell integration" affordance (writes/【appends a guarded `source` line, copies the hook to a stable path) in the Engine/Advanced or a new Terminal settings subsection, plus a live "● shell session connected" indicator driven by `TerminalIntegrationService.sessions`.

### B.6 Tests (Sub‑plan B)

- Extend `scripts/test-terminal-integration.sh` / `test-terminal-e2e.sh` for: socat‑free transport, fish, and accept‑key parity.
- Unit: keep `TerminalFocusAdapterTests` / `TerminalGeometryResolverTests` green; add cases for fish cursor offsets and for the new transport's message framing if any parsing changes.
- **Acceptance criteria:** Typing `git ch` at a zsh, bash, and fish prompt shows a ghost suggestion positioned at the caret; the configured terminal accept key inserts it; no `socat` required.

---

## Sub‑plan C — Claude Code TUI Autocomplete (the new path)

**Objective.** Show inline (or popup) suggestions inside the Claude Code prompt box running in a terminal, and accept them with a shortcut. Because shell hooks cannot see inside a TUI, this path reads the prompt text from the screen.

> This is the highest‑risk sub‑plan. Treat it as a spike first (C.1) and gate the rest on whether OCR is fast and accurate enough.

### C.1 Detect "Claude Code is focused" (backend)

- **New file:** `Cotabby/Support/TuiSessionDetector.swift` — classify the focused context as "Claude Code TUI" when: the frontmost app is a known terminal (reuse `TerminalAppDetector`) **and** a heuristic indicates Claude Code is the foreground process. Heuristics, cheapest first:
  1. The terminal window/tab title contains a Claude Code marker (many terminals set the title from the running program; AX exposes `AXTitle` even for terminals).
  2. The foreground process of the terminal's TTY is `claude` (walk the process tree from the terminal PID; the shell hook already knows the shell PID).
  3. OCR fingerprint of the Claude Code UI chrome (border box / prompt glyph) as a last resort.
- Add a `SupportLevel.claudeCodeTui` (or a parallel enum) so routing is explicit.

### C.2 Read the prompt text via screenshot + OCR (backend — the spike)

- **New file:** `Cotabby/Services/Terminal/TuiContextReader.swift` — given the terminal window, capture the input region with `WindowScreenshotService`, OCR it with `ScreenTextExtractor` (Vision), and clean it with `OCRTextHygiene`. Produce the current input line text and an estimated caret position.
- Constrain the capture to the bottom input box (Claude Code's prompt is a bordered box near the bottom) to keep OCR fast and accurate. Reuse `VisualContextStartCoalescer` to avoid redundant captures.
- **Spike exit criteria (decide go/no‑go here):** end‑to‑end capture→OCR→text under a target latency budget (e.g. ≤120 ms on Apple Silicon) and accurate enough on monospaced terminal text that the suggestion prefix matches what the user typed. If OCR can't hit this, fall back to "C.6 Alternative" before investing further.

### C.3 Adapt into the pipeline (backend)

- **New file:** `Cotabby/Support/TuiFocusAdapter.swift` — mirror `TerminalFocusAdapter`: convert the OCR result into a `FocusedInputSnapshot` (`role: "ClaudeCodeTuiInput"`, `caretQuality: .estimated`, preceding/trailing text split at the estimated cursor). No coordinator fork — it consumes the same snapshot shape.
- **Edit:** `Cotabby/App/Core/CotabbyAppEnvironment.swift` — add a polling/trigger source for the TUI reader (on keystroke from the listen‑only `InputMonitor` tap, debounced) that emits adapted snapshots the same way `terminalIntegrationService.onSnapshotUpdate` does.

### C.4 Overlay positioning (frontend)

- Position ghost text / popup at the OCR‑estimated caret over the terminal window via `OverlayController`. Because caret quality is `.estimated`, the mirror/popup card path is the realistic target rather than pixel‑perfect inline ghost text.

### C.5 Insertion (backend)

- Use the existing **terminal clipboard‑paste** path in `SuggestionInserter` (Cmd+V / bracketed paste). Claude Code's input box accepts pasted text, so this works without synthetic per‑character keystrokes. Accept key resolves through `ShortcutResolver` (Sub‑plan A) with a Claude‑Code‑specific or terminal default.

### C.6 Alternative / complementary approach (document, decide)

If OCR proves too slow or inaccurate, document these fallbacks rather than silently shipping a flaky feature:
- **Claude Code native integration:** Claude Code supports configuration/hooks; investigate whether an official extension point can feed the buffer to Cotabby (cleanest, no OCR). Verify against current Claude Code docs before relying on it.
- **PTY/terminal scrollback parsing** where the terminal exposes it (e.g. iTerm2's scripting API).
- Ship Claude Code support behind a clearly‑labeled **experimental** toggle until the spike proves the latency/accuracy budget.

### C.7 Tests (Sub‑plan C)

- Unit (pure): `TuiFocusAdapterTests`, `TuiSessionDetectorTests` (title/process heuristics with fixture inputs), and OCR‑hygiene cases feeding `OCRTextHygiene`.
- Component: feed a captured fixture screenshot of a Claude Code prompt through `TuiContextReader` and assert extracted text (golden‑image test; store fixtures under `CotabbyTests/Fixtures/`).
- E2E (script): extend `scripts/test-terminal-e2e.sh` "Claude Code" section from *non‑interference* to *suggestion appears + accept inserts*, gated/skipped when `claude` is absent.
- **Acceptance criteria:** With Claude Code focused and the experimental toggle on, typing a partial command/sentence in its prompt shows a suggestion within the latency budget, and the accept key pastes it into the prompt.

---

## Sub‑plan D — Routing & Coordination Glue

**Objective.** Make the three input sources (AX, shell‑prompt, Claude Code TUI) coexist deterministically so only one drives a suggestion at a time and shortcut resolution stays consistent.

- **Edit:** `Cotabby/Support/SuggestionAvailabilityEvaluator.swift` and the `SuggestionCoordinator` extensions (`+Input`, `+Prediction`, `+Lifecycle`, `+Acceptance`) — extend the existing `terminalIntegrationActive` plumbing into a single source‑of‑truth "active input source" decision: AX vs shell‑integration vs TUI. Today the coordinator already threads `terminalIntegrationActive`; generalize it rather than adding parallel booleans.
- Define precedence when signals overlap (e.g. Claude Code focused inside a terminal that also has a shell session): **TUI source wins** while Claude Code is foreground, shell‑prompt source wins at the bare prompt.
- Ensure cancellation/staleness: switching apps or sources must invalidate in‑flight requests (the codebase already uses `focusChangeSequence` for this — every adapter must stamp the current sequence, which `TerminalFocusAdapter` already does).
- Keep `ShortcutResolver` precedence (terminal/TUI → per‑app → global) consistent with the active source.

### D Tests
- Unit: extend `SuggestionAvailabilityEvaluatorTests` for the new source‑selection matrix.
- Unit: `SuggestionSessionReconcilerTests` / coordinator acceptance tests for source switching without stale insertions.

---

## Sub‑plan E — Testing Strategy (consolidated)

Testing is a first‑class goal here, not an afterthought. The strategy has four layers, matching the existing repo conventions (XCTest, pure‑rule unit tests, no real CGEvents in app‑hosted tests).

### E.1 Unit tests (pure rules — the bulk)
Follow the existing pattern: pure helpers in `Support/` with table‑driven `XCTest` cases and no AppKit/CGEvent dependencies.
- `ShortcutResolverTests`, `PerAppShortcutOverrideStoreTests` (A)
- fish offset cases in `TerminalFocusAdapterTests` (B)
- `TuiSessionDetectorTests`, `TuiFocusAdapterTests` (C)
- extended `SuggestionAvailabilityEvaluatorTests`, `ShortcutConflictTests` (D)

### E.2 Component / golden tests
- OCR pipeline against fixture screenshots (`TuiContextReader`) with stored golden inputs/outputs.
- Settings round‑trip persistence on isolated `UserDefaults(suiteName:)`.

### E.3 Integration via scripts
- `scripts/test-terminal-integration.sh` and `scripts/test-terminal-e2e.sh` extended for: socat‑free transport, fish, accept‑key parity, and the upgraded Claude Code "suggestion appears + accept" check.

### E.4 Manual QA matrix (pre‑release)
Run before shipping. Each cell = "suggestion appears at caret" + "accept inserts" + "no interference when idle".

| Surface | Terminal.app | iTerm2 | Ghostty | kitty | WezTerm | Alacritty | VS Code term |
|---|---|---|---|---|---|---|---|
| zsh prompt | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| bash prompt | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| fish prompt | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| Claude Code TUI | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ | ☐ |
| Per‑app shortcut override | ☐ (set & verify differs from global) |
| Reset‑to‑global fallback | ☐ (clear override → global key works) |

### E.5 Build & lint gates (from `.claude/CLAUDE.md`)
```bash
swiftlint lint --quiet
xcodebuild -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' build \
  -derivedDataPath build/DerivedData
xcodebuild -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' build-for-testing \
  -derivedDataPath build/DerivedData
# clean up afterward:
rm -rf build/DerivedData
```
New source files under `Cotabby/` and `CotabbyTests/` are auto‑discovered by XcodeGen — no `project.yml` edit needed unless adding a target, dependency, or bundled helper binary (B.1) or fixture resources (then regenerate with `xcodegen generate`).

### E.6 Debugging during development
Use the structured logs described in `.claude/CLAUDE.md` (`~/Library/Logs/Cotabby/cotabby.jsonl`, `llm-io.jsonl`, correlation `request_id`). For terminal/TUI work, watch the `focus`, `suggestion`, and router‑selection categories; for OCR latency, add timing fields to the `visual`/`runtime` categories.

---

## Sub‑plan F — Sequencing, Risks, Rollout

### F.1 Recommended order
1. **Sub‑plan A (per‑app shortcuts)** — independent, low‑risk, ships value immediately and builds the `ShortcutResolver` other sub‑plans reuse.
2. **Sub‑plan B (harden shell prompt)** — finishes an existing half‑built feature; unblocks reliable terminal QA.
3. **Sub‑plan C.1–C.2 spike (Claude Code detection + OCR)** — go/no‑go gate before investing in C.3–C.5.
4. **Sub‑plan C.3–C.5 + D (full TUI path + routing)** — only if the spike passes its latency/accuracy budget.
5. **Sub‑plan E.4 manual matrix + F.3 rollout.**

### F.2 Risks & mitigations
- **OCR latency/accuracy (C):** mitigate with a region‑constrained capture, a hard latency budget, the go/no‑go spike, and an experimental flag.
- **Screen Recording permission:** the TUI path needs Screen Recording (Cotabby already uses screenshots for visual context — reuse `PermissionModels`/permission flow; surface a clear prompt).
- **Terminal keyboard‑protocol quirks (Ghostty/kitty):** clipboard‑paste insertion sidesteps synthetic‑keystroke issues; keep the shell‑side right‑arrow accept as a documented fallback.
- **Shortcut conflicts (A):** scoped conflict checking + reuse of `conflictingShortcutName`.
- **Source thrashing (D):** deterministic precedence + `focusChangeSequence` staleness guards.

### F.3 Rollout
- Land A and B as normal features. Ship C behind an **experimental "Claude Code (beta)"** toggle in settings until the QA matrix is green across at least Terminal.app, iTerm2, and Ghostty.
- Follow the repo's PR/issue template rules in `.claude/CLAUDE.md` (no `Co‑Authored‑By`, fill every template section, run SwiftLint, keep `Cotabby.xcodeproj` in sync with `project.yml`).

---

## Appendix — File Change Index

**New files**
- `Cotabby/Models/PerAppShortcutOverride.swift` (A)
- `Cotabby/Support/ShortcutResolver.swift` (A)
- `Cotabby/UI/Settings/Components/KeybindRow.swift` (A, refactor)
- `scripts/shell-integration/cotabby.fish` (B)
- bundled socket helper, e.g. `Cotabby/Services/Terminal/` + tool target (B, if chosen)
- `Cotabby/Support/TuiSessionDetector.swift` (C)
- `Cotabby/Services/Terminal/TuiContextReader.swift` (C)
- `Cotabby/Support/TuiFocusAdapter.swift` (C)
- Tests: `ShortcutResolverTests`, `PerAppShortcutOverrideStoreTests`, `TuiSessionDetectorTests`, `TuiFocusAdapterTests` (+ fixtures)

**Landed vs. outstanding** (delta against this branch)

| Sub‑plan | Status | Notes |
|---|---|---|
| A.1 model + store | ✅ landed | `PerAppShortcutOverride` + load/sanitize/persist mirroring `disabledAppRules`. |
| A.2 `ShortcutResolver` + InputMonitor wiring | ✅ landed | Pure resolver in `Support/`; full-accept providers also routed through it. |
| A.3 settings UI | ✅ landed | New "Per‑App Shortcuts" section in `AppsPaneView`; `KeybindRow` extracted to `Settings/Components/`. |
| A.4 tests | ✅ landed | `ShortcutResolverTests`, `PerAppShortcutOverrideStoreTests`, per‑app conflict cases in `ShortcutConflictTests`. |
| B.1 drop `socat` | ✅ landed | All hooks + test scripts now use `/usr/bin/nc -U` (BSD netcat ships with macOS). |
| B.2 fish hook | ✅ landed | New `scripts/shell-integration/cotabby.fish`; test script gates a syntax check on `fish` being installed. |
| B.3 file‑based accept removed | ✅ landed (+ regression fix) | `shouldPassThroughAcceptKeyProvider = { false }`; Cotabby owns terminal acceptance via clipboard paste. Initial rollout left a stale `!terminalPassThrough` skip in `SuggestionCoordinator+Acceptance.swift` that swallowed the right‑arrow without pasting — fixed in this round and pinned by new XCTest cases in `CotabbyTests/SuggestionCoordinatorAcceptanceTests.swift` (`test_acceptanceInGhosttyTerminal_routesToInserter`, `test_terminalAcceptanceWithFailedInsert_clearsOverlay`). |
| Accept-key E2E script | ✅ landed | `scripts/test-terminal-acceptance-e2e.sh` — opt-in osascript-driven sweep over Ghostty / Terminal.app / VS Code × zsh / bash / fish + a Claude Code TUI case in Ghostty. Run on demand (~60 s of foreground); the always-on regression coverage lives in the XCTest layer above. |
| B.4 geometry tuning | ⏸ deferred | Visual verification per terminal — best done with the QA matrix in E.4. |
| B.5 install UX | ⏸ deferred | One‑click install affordance + "shell session connected" indicator. |
| C.1 TUI detection | ✅ landed | `TuiSessionDetector` + tests; title / process-name heuristics, OCR as documented fallback. |
| C.2 OCR reader | ✅ landed | `TuiContextReader` over `ScreenTextExtractor`; latency reported via `PromptReading.latencyMilliseconds` so the QA gate can measure each capture. |
| C.3–C.5 adapter + coordinator + insertion | ✅ landed | `TuiFocusAdapter` (tested), `TuiContextCoordinator` with live `captureSession` backed by the new `TuiScreenshotService` (ScreenCaptureKit window + region capture), foreground‑process detection via `ProcessTreeInspector`, debounced refresh from `suggestionCoordinator.tuiInputObserver`. Insertion reuses the terminal clipboard‑paste path from B.3. `shouldProcessEventsProvider` and `terminalIntegrationActiveProvider` both honor the TUI source. |
| Experimental gate | ✅ landed | `SuggestionSettingsModel.isClaudeCodeTuiExperimentEnabled` defaults off; "Claude Code autocomplete (beta)" toggle now lives in the Advanced pane and gates the entire TUI path. |
| D routing & coordination | ✅ landed | `terminalIntegrationActive` provider now ORs shell + TUI sources; precedence documented in `SuggestionAvailabilityEvaluator`. |
| E manual QA matrix | ⏸ outstanding | Run before flipping the C experiment to default‑on. |
| F rollout | ⏸ outstanding | Settings UI toggle for the experiment + ramp plan. |

**Edited files**
- `Cotabby/Models/SuggestionSettingsModel.swift` (A)
- `Cotabby/UI/Settings/Panes/AppsPaneView.swift` (A)
- `Cotabby/UI/Settings/Panes/ShortcutsPaneView.swift` (A, extract `KeybindRow`)
- `Cotabby/App/Core/CotabbyAppEnvironment.swift` (A, C, D)
- `scripts/shell-integration/cotabby.zsh`, `cotabby.bash` (B)
- `Cotabby/Services/Terminal/TerminalGeometryResolver.swift` (B)
- `Cotabby/Services/Suggestion/SuggestionInserter.swift` (B, C — reuse)
- `Cotabby/Support/SuggestionAvailabilityEvaluator.swift` + `SuggestionCoordinator+*` (D)
- `scripts/test-terminal-integration.sh`, `scripts/test-terminal-e2e.sh` (B, C)
- `CotabbyTests/ShortcutConflictTests.swift`, `TerminalFocusAdapterTests.swift`, `SuggestionAvailabilityEvaluatorTests.swift` (A, B, D)

---

## VS Code round (2026-06-12) — embedded-host injection, TUI stickiness

Three VS Code-only failures were reported after the 2026-06-11 round and root-caused by a
16-agent QA workflow (3 investigators + adversarial verification; 13 findings confirmed,
0 refuted): (a) no completions at the VS Code integrated-terminal prompt, (b) the
`TerminalShellIntegration | TerminalShellInput` badge never appearing after `exec bash`,
(c) the HUD stuck on `TuiOCR | ClaudeCodeTuiInput` after exiting claude.

**Root causes (all log- and code-verified):**

1. **(a)+(b)** The embedded-host guard in `CotabbyAppEnvironment.onSnapshotUpdate`
   unconditionally dropped every shell-hook snapshot for VS Code on the assumption that
   "Electron exposes the terminal text to AX". The logs disproved it: VS Code's xterm.js
   terminal yields `capability=Unsupported — No focused Accessibility element` on every
   poll, so NO source served the prompt at all.
2. **(c)** Compounded: the heartbeat's non-Claude tick was a deliberate no-op (nothing
   cleared the injected TUI snapshot without a keystroke); the app-pid-wide process walk
   kept classifying `claudeCode` because the Claude Code VS Code EXTENSION holds `claude`
   processes under VS Code's pid; the OCR fingerprint matched "Claude Code" text the
   extension renders in VS Code's own UI (61 spurious injections against the Welcome tab);
   and `FocusTrackingModel` suppressed all same-bundle AX polls while injected, making the
   snapshot immortal (the tracker republishes only on CHANGE, and an AX-dead terminal never
   changes).

**Fixes (kept narrow; all shared-path changes role/flag-guarded):**

- `CotabbyAppEnvironment.onSnapshotUpdate`: embedded hosts now inject UNLESS a supported,
  non-terminal-role AX element owns focus (the editor keeps AX service; the AX-dead
  terminal pane gets shell service).
- `FocusTrackingModel`: a same-bundle `.supported` AX poll reclaims focus from a terminal
  injection in embedded hosts only (`onTerminalInjectionReclaimed` resets the inserter's
  terminal mode); `clearTerminalInjection` now republishes the tracker's real snapshot.
- `TuiContextCoordinator` heartbeat: a non-Claude tick calls `cancelPending()` when this
  coordinator holds the injection — keystroke-free recovery within ~1–2 s of the TUI dying.
- `CotabbyAppEnvironment` TUI wiring: the `clearInjection` closure verifies the live
  snapshot is TUI-owned before tearing down (protects shell sessions from stale-flag
  clears); the capture session refuses to OCR when a supported AX field owns focus.
- Process detection for embedded hosts is scoped to the registered shell sessions'
  subtrees (`ProcessTreeInspector.subtreeProcessNames(rootedAt:)`, roots included to
  survive `exec claude`) — extension-host claude processes can no longer classify.

**Validation (app from Xcode DerivedData, `-cotabby-debug`):**

- Full E2E: **15 PASS / 0 FAIL / 3 SKIP** — `D.zsh — VS Code + zsh` and
  `D.bash — VS Code + bash` (after `exec bash`) now PASS with real buffer growth
  (`git ch` → `git ch koutx`); Ghostty/Terminal.app/Claude-TUI phases unchanged. Skips:
  `A.fish` (pre-existing), `D.fish` (same), `Z.zsh` (environment flake — a macOS
  notification banner held AX focus for the whole keystroke-free window; the same path
  passes with keystrokes in `B.zsh`).
- New regression test `scripts/test-vscode-tui-exit-e2e.sh` (claude in VS Code → exit →
  assert recovery): TUI injects while claude runs; after exit the shell snapshot takes
  over in ~340 ms, the next TUI capture self-rejects ("lacks Claude Code fingerprint"),
  and the heartbeat flips — no sticky TuiOCR. When the shell does NOT re-report, the
  heartbeat clear restores the real AX snapshot (observed live: clear 582 ms after
  process exit). Note: claude's `/exit` is unreliable under synthetic typing (trust/
  onboarding screens swallow it); the script keys on process death with a Ctrl+C
  fallback.
- Spurious TUI injections in VS Code since the fix: **zero** (was 61/session against the
  Welcome tab). Only legitimate injections while claude actually runs.

Known limitation (accepted, documented in code): TUI detection in embedded hosts requires
a HOOKED shell session — claude launched from an unhooked integrated terminal will not
engage TuiOCR (deliberate: an app-pid fallback would resurrect the extension false
positive).

## Ghost-position round (2026-06-12) — OCR prompt anchor + arithmetic caret tracking

User report: on shell surfaces the inline gray suggestion rendered at the WINDOW BOTTOM-LEFT
(stacked on the debug badge) instead of after the typed text. Root cause: shell hooks never
populate the IPC `row`/`col` fields, so `TerminalGeometryResolver` always used the
`fallbackCursorRect` bottom-left guess. The renderer was NOT the problem —
`GhostSuggestionLayout` already wraps ghost text below the caret line at the pane's right
edge (verified + regression-locked in `GhostSuggestionLayoutTests`).

**Design (plan: `~/.claude/plans/quizzical-brewing-widget.md`):** one OCR pass per prompt
builds a `TerminalPromptAnchor` (Support/, pure: buffer-prefix → OCR-line matching with glyph
folding, bottom-most tie-break, calibrated cell width `lineBoxWidth/charCount`); every
keystroke then computes the caret ARITHMETICALLY from the shell-reported cursor offset with
row wrap at the pane's column count. `ShellPromptGeometryCoordinator` (Services/Terminal/)
owns the debounced capture (shares `TuiScreenshotService` + the embedded-host pane clamp),
anchor cache keyed by shell pid, miss backoff, and an `onAnchorResolved` re-injection that
snaps the ghost in ~0.5 s after the first keystroke at a fresh prompt. Anchors invalidate on
new prompt / window move / age (20 s) / caret-out-of-window; low-confidence (empty-prompt)
anchors keep serving until their upgrade OCR actually succeeds.

**Key behavior changes:**
- NO MORE bottom-left guessing: an un-anchored shell snapshot now carries a ZERO caret and
  the overlay is suppressed (`SuggestionOverlayPresenter` hides on zero caret; the
  acceptance path's `predictedCaretRect` can no longer smuggle a zero-based caret through).
- Anchor-resolved re-injection re-presents a ready suggestion at the new geometry
  (`repositionTerminalOverlayIfNeeded`), and `presentOverlay` upgrades zero-caret terminal
  contexts to the live anchored geometry — both generation/anchor orderings covered.
- Terminal-grid surfaces render MONOSPACED ghost text (`usesMonospacedFont` through
  `SuggestionOverlayGeometry`), so the painted glyphs match the cell-width line budgets.
- Debug caret badge anchors at the prompt line's LEFT edge for terminal roles — it can no
  longer collide with the ghost (which only renders right of the typed text).
- New placement log: `Inline ghost shown: caret=(x,y) panel=(...)` (debug builds).

**Validation:**
- `scripts/test-terminal-ghost-position-e2e.sh` (new): types a prefix, then checks the
  logged overlay caret against an independent full-screen Vision OCR of the prompt line
  (`scripts/ocr-lines.swift` helper). Result: **4 PASS / 0 FAIL / 0 SKIP** — Ghostty
  dy=8pt / x within 2pt of the typed text's end; VS Code dy=8pt / x within 10pt.
- Live tracking observed in logs: caret advances one cell per typed char and follows
  backspaces; anchors upgrade from low-confidence to calibrated (cell width 7.0–8.7pt
  matching the actual terminal fonts).
- New unit tests: `TerminalPromptAnchorResolverTests` (matching, normalization, arithmetic
  row wrap, validity), `GhostSuggestionLayoutTests` terminal-line cases,
  `TerminalFocusAdapterTests` zero-suppression contract.
- Acceptance suite re-run for regressions (see updated matrix below).

Known limitations (documented in code): CJK/emoji count as one column in the arithmetic
caret (v1); shells without hooks get no ghost (no anchor source); the first ghost at a
fresh prompt appears ~0.5 s after the first keystroke (OCR anchor latency) rather than
instantly.

### Follow-up: optimistic local echo for terminal accepts (same day)

User-reported after live testing: multi-chunk accepts dropped separator spaces
("git pull" + " origin" → "git pullorigin") and the remaining-tail ghost rendered over the
accepted text. Root cause (proven from paste-size logs + buffer ground truth): **bracketed
paste is invisible to the per-keystroke shell hooks**, so the live snapshot stays pre-paste
until the next real keystroke — `SuggestionSessionReconciler.insertionChunk` then reads a
STALE trailing space and strips legitimate leading spaces from later chunks, and the
post-accept ghost positions against the stale caret.

Fix: after every successful terminal-mode paste, Cotabby applies an **optimistic local
echo** — `TerminalFocusSnapshot.appendingInsertedText` (shell-aware offsets: bash bytes,
zsh/fish chars) updates the session snapshot natively via
`TerminalIntegrationService.applyOptimisticInsertion`, wired through
`SuggestionCoordinator.onTerminalInsertion` after `commitAcceptedChunk` (ordering matters:
echoing before commit would double-advance the session via reconciliation). The echo flows
through the normal report path, so it also re-anchors the ghost at the arithmetic caret
after the pasted text. The shell's next real report overwrites the echo with ground truth.

Validation: new `scripts/test-terminal-multi-accept-e2e.sh` (keystroke-free, Phase-Z
machinery): 3 IPC accepts on the same suggestion text as the user's repro now yield
`git pull origin master` — the buffer is asserted to be a VERBATIM prefix of
prompt+completion, so any dropped/doubled space fails. Ghost caret logged marching
771→806→857→907 across the accepts (reposition after each paste). Unit:
`TerminalOptimisticEchoTests`. Regressions: position E2E 4/4 PASS; acceptance suite
**17 PASS / 0 FAIL / 2 SKIP** (new best).

Out of scope (model quality, known 2B-base weakness): completions that start with a
spurious leading space mid-word ("gi" → " t add …" accepting to "gi t add"). The accept
inserts exactly what the ghost shows; the ghost's single leading space is just hard to see
on a terminal grid.

## E2E acceptance status (updated 2026-06-11)

The goal of this round was a live, automated proof that the shell buffer changes from
`<typed text>` to `<typed text + completion>` through the real pipeline (hook → socket →
prompt → llama → accept → clipboard paste). Run with the app launched `-cotabby-debug`:

```bash
bash scripts/test-terminal-acceptance-e2e.sh --yes
```

### Matrix (best full run 2026-06-12, post ghost-position round: 16 PASS / 0 FAIL / 2 SKIP — only the two fish hook skips remain; Claude Code verified separately on-screen)

| Surface | zsh | bash | fish | Claude Code TUI |
|---|---|---|---|---|
| Terminal.app | ✅ PASS (incl. keystroke‑free Phase Z with on‑screen buffer proof) | ✅ PASS | ⏳ testing | ✅ **PASS** — see below |
| Ghostty | ✅ PASS | ✅ PASS | ⏳ testing | — |
| VS Code | ✅ PASS | ✅ PASS | ⏳ testing | — |

**Claude Code TUI proof (2026‑06‑11).** Detection + OCR + generation + acceptance verified
end‑to‑end against the live `claude` CLI in Terminal.app; the input box visibly grew by the
accepted suggestion (screen read via AppleScript):

```
before accept: [❯ explain how git rebase wor]
after accept:  [❯ explain how git rebase wor ke and how to use it in a project.]
log:           Inserted 35 characters via terminal-mode clipboard paste
```

OCR latency 25–35 ms per capture (well inside the C.2 ≤120 ms gate). The E2E's Phase C now
passes both "Cotabby detected the Claude Code TUI" and the acceptance-paste check.

**Overlay positioning architecture (2026‑06‑11, second round).** A 4‑agent code sweep pinned
the coordinate contract: `FocusedInputSnapshot.caretRect`/`inputFrameRect` must be **AppKit
bottom‑left screen points** — the overlay layer (`OverlayController`, `MirrorOverlayLayout`,
`GhostSuggestionLayout`) does ZERO conversion and feeds them straight into `NSPanel.setFrame`.
The AX path converts at the source (`AXHelper.cocoaRect` → `DisplayCoordinateConverter`); both
terminal paths emitted raw CG top‑left rects (`TerminalGeometryResolver.estimatedCursorRect`
even had a comment promising a conversion that never happened) — which is why suggestion cards
floated far from the input line. Fixes applied at the source boundaries, keeping the pure
helpers (and their tests) in CG space:
- `TerminalGeometryResolver.enrichWithGeometry` converts cursor rect + window frame to AppKit
  once, at the service boundary (shell path).
- `TuiContextCoordinator.performCapture` builds line/caret rects from OCR geometry and
  converts via `AXHelper.cocoaRect` (TUI path).
- `ScreenTextExtractor` now preserves Vision's per‑line normalized bounding boxes
  (`RecognizedTextLine`; it always sorted by them, then discarded them) and `TuiContextReader`
  anchors to the **bottom‑most prompt‑glyph line's box** — exact position, and immune to
  Claude Code's menus that reuse the `❯` glyph (e.g. the trust screen's "❯ 2. No, exit",
  which had hijacked prompt extraction). Glyph variants now include the `)` OCR misread.
- `TerminalFocusAdapter` fallback caret updated to the AppKit convention (+ test updated to
  assert bottom = small y).

Verified live in a windowed Terminal: `❯ write a function that par` → accepted →
`❯ write a function that par ses a string of numbers and returns the sum of all the numbers in`.

**Per-window TUI arbitration + customizable shell shortcut (2026‑06‑11, fifth round).**
Process-tree detection is app-wide, so `claude` alive in one tab classified a bare prompt in
another tab/window of the same app — TuiOCR hijacked plain zsh typing (observed in VS Code).
Two complementary gates fixed it, verified live with the two-window Terminal.app case:
- **Shell-fresh yield**: a buffer report within 2 s of a keystroke means the user is typing at
  a prompt — the TUI path stands down (`TuiContextCoordinator.isShellActivelyReporting`).
- **OCR fingerprint (plan heuristic C.1‑3)**: the captured WINDOW must show Claude Code's own
  markers ("Claude Code" / "context)" / "esc to interrupt") before a snapshot is injected —
  the only per-window signal there is. Bare prompts never inject; the claude window always
  does.
Also in this round: TUI `inputFrameRect` spans the full pane width (the OCR text box ends at
the caret, which wrapped inline ghost text into a one-word column); `ShortcutAction` gained
`.terminalAccept` with a full Shortcuts-pane row (record/reset/clear + conflict checking), so
the shell accept key is user-customizable; per-app override UI switches extended accordingly.
E2E: 17 PASS / 0 FAIL — including first-ever fish pass (Terminal.app) and the buffer-grew
primary proof in Ghostty (`[git ch] → [git ch kout…]`). VS Code D-phases now SKIP by design:
embedded hosts are AX-served, so the shell-transcript probe correctly finds nothing.

**Shell-surface unification (2026‑06‑11, fourth round).** One rule now drives every
shell-facing behavior (`shellSurfaceProvider` in `CotabbyAppEnvironment`): a surface is a
shell when the frontmost app is a dedicated terminal, OR an embedded-terminal host
(`TerminalAppDetector.hostsEmbeddedTerminal` — VS Code, Cursor, Zed, JetBrains) with a live
shell-integration session. Consequences, all wired to that single rule:
- **Accept key**: the terminal shortcut (default `→`) applies on every shell surface — global
  across shells in any app, as requested. Keycap hint resolves identically
  (`resolvedAcceptanceHintLabel(forBundleIdentifier:isShellSurface:)`), so the pill always
  teaches the key that fires.
- **Rendering**: shell surfaces render INLINE gray ghost text instead of the popup card
  (`CompletionRenderModePolicy.mode(…isShellSurface:)` — auto rule; an explicit per-app
  "always popup" override still wins).
- **Routing**: embedded hosts do NOT inject shell-hook snapshots (their own AX tree serves
  the bare prompt better); their sessions still register for the shell-surface rule. The
  Claude Code TUI path now engages in embedded hosts too (`TuiSessionDetector` + capture
  gate accept them), with the capture constrained to the FOCUSED PANE's AX frame so editor
  chrome ("> Connect to…" welcome links) can't masquerade as the prompt line. Dedicated
  terminals keep full-window capture.
- **Session lifetime**: pruning is now pid-liveness (`kill(pid, 0)`), not 30 s of silence —
  a shell suspended under Claude Code stays a live session, so embedded hosts don't lose
  shell-surface behavior mid-TUI.
Verified live: Terminal.app + claude → typed "fix the bug in the login pa", OCR read it
exactly, accept grew the box. VS Code: TUI path engages (classification + injection logged);
pane-constrained capture activates when the terminal pane holds focus — needs the
interactive manual pass (blind automation cannot place VS Code pane focus).

**Stale shell-buffer guard (2026‑06‑11, third round).** Typing into Claude Code inside VS
Code's integrated terminal produced completions of the long-dead `$ claude` shell buffer
(llm-io showed the shell-transcript prompt ending `$ claude` → `"What is the best way to
install a package in Python?" | grep` pasted into the TUI). Cause: VS Code is not a
`TerminalAppDetector` terminal, so the TUI path never engages there, and the shell hook's
last report freezes once the TUI owns the tty — yet that injected snapshot kept serving
every keystroke-scheduled generation. Fix: Sub‑plan D's precedence invariant enforced in
`CotabbyAppEnvironment`'s keystroke observer — three consecutive keystrokes with a >2 s-old
shell report (keystrokes arriving but the shell not re-reporting ⇒ the shell no longer sees
input) clears the terminal injection, letting AX (VS Code) or the TUI path (real terminals)
take over. Verified in Terminal.app: all generations during a claude session now use the
Claude-Code prompt, zero stale shell completions; mid-word continuation confirmed
("how do i revert a com" → "mit in git?"). VS Code pane focus cannot be scripted reliably —
needs one manual retest there.

Three product bugs had silently disabled the entire TUI path and were fixed in this round:
1. `AppDelegate` built `CotabbyAppEnvironment` as a local and only copied out the services it
   knew — `tuiContextCoordinator` was deallocated ~6 ms after launch (deinit log proved it).
   AppDelegate now retains the coordinator like every other long‑lived service.
2. `TuiContextCoordinator.promptRegion` used `windowFrame.minY` in CG top‑left coordinates —
   capturing the TITLE BAR band instead of the bottom input box. Now `maxY - bandHeight`.
3. `TuiContextReader` picked the last non‑empty OCR line, which is Claude Code's status bar
   ("~ Opus 4.8 (1M context)"), not the input. Extraction is now prompt‑glyph aware
   (`❯` / `›` / `>`), with last‑line fallback.

### What landed in this round (beyond the original sub‑plans)

**Product fixes (Swift):**
- `TerminalCompletionPromptRenderer` (new, + tests): terminal sources get a shell‑transcript
  base‑model prompt; Claude Code TUI gets assistant‑message framing. Routed by `role` in
  `SuggestionRequestFactory`. Fixes prose completions like `g` → "reeting: hello…".
- Snapshot‑driven prediction scheduling for terminal sources
  (`SuggestionCoordinator+Input.scheduleTerminalSnapshotPredictionIfNeeded`): the hook's
  buffer report is the keystroke signal — required because CGEvent taps cannot see
  synthetic/automated input, and also covers programmatic buffer edits. Reschedules after
  reconciliation invalidates a session.
- Frontmost gating in `onSnapshotUpdate`: background hooked shells can no longer hijack
  focus / cancel the frontmost terminal's generations.
- `TerminalSession.shellType` follows `exec bash/fish` (same‑pid shell swap) and logs
  "switched shell" — previously the session silently kept the stale shell.
- Debug‑gated `{"type":"accept"}` IPC message (`TerminalIntegrationService` →
  `acceptCurrentSuggestion`), the only scriptable way to drive the real acceptance path.
- Claude Code TUI: providers rewired to `NSWorkspace.frontmostApplication` (the AX context
  is nil exactly when a TUI owns the terminal), a 1 s detection/OCR heartbeat
  (`TuiContextCoordinator.startHeartbeat`), and a success log
  ("ClaudeCodeTuiInput snapshot injected") so the path is observable.

**Hook fixes (scripts/shell-integration/):**
- All hooks: the double‑load guard is no longer exported (an exported guard disabled
  integration in every nested/exec'd shell); load banner moved to stderr.
- `cotabby.bash`: full rewrite — per‑printable‑key `bind -x` self‑insert wrappers report on
  every keystroke; editing keys re‑implement their readline defaults (the old report‑only
  bindings broke backspace/Ctrl‑keys); requires bash ≥ 4 with a clean bail‑out on macOS 3.2;
  unset‑READLINE printf fix.
- `cotabby.fish`: per‑printable‑key insert‑then‑report bindings; empty‑buffer JSON‑escape
  fix (empty values collapsed to empty lists and the first report of every session was lost).

**Test harness (scripts/test-terminal-acceptance-e2e.sh):**
- Buffer ground truth read from `llm-io.jsonl` (each terminal generation's prompt ends with
  the hook‑reported buffer) instead of fragile shell‑side dump bindings.
- Keystroke‑free Phase Z (Terminal.app `do script` + zsh `print -z` + screen read) that
  works without any Accessibility grant.
- `tell … end tell` typing fix (`tell X to <multiline>` types exactly one character — this
  invalidated all earlier "typing" results), shell‑switch verification, secure‑input
  pre‑check, accept via debug IPC.

### Still under test / known issues

1. **fish E2E cases** — the fish hook reports keystrokes when exercised directly, and the
   `exec fish` switch is now verified, but typed‑prefix generations don't appear in
   `llm-io.jsonl` during the E2E fish cases. Under investigation (next: capture the fish
   case window logs to see whether reports arrive and where they are dropped).
2. **Multi‑window terminal precedence** — TUI detection is app‑level (process tree under the
   terminal app's pid), so a `claude` running in a BACKGROUND window of the frontmost terminal
   app classifies the ACTIVE bare‑prompt window as Claude Code and the OCR injection fights
   the shell snapshots (observed when an orphaned claude window survived into later E2E
   phases). Refinement: gate on the active window — e.g. require the captured (active) window's
   OCR to contain a prompt‑glyph/claude fingerprint before injecting, or resolve the active
   window's tty foreground process instead of walking the whole app subtree.
3. **Completion quality** — mechanism proven, but Qwen3.5‑2B‑Base Q4 yields weak command
   completions (`git ch` → ` g --no-verify …`). Prompt/model tuning is follow‑up work;
   offline iteration via `llama-cli` is NOT representative (it applies a chat template).
4. **Unit tests** — compile clean; the app‑hosted runner hangs under headless CLI
   (`xcodebuild test` → "test runner hung before establishing connection"). Run the suite
   from Xcode GUI.
5. **Environment prerequisites discovered** (documented for whoever runs this next):
   Accessibility for the automation host (for Claude Code sessions that is the *nested*
   `~/Library/Application Support/Claude/claude-code/<ver>/claude.app`), no stuck
   secure‑input holder (`ioreg | grep SecureInput`; lock/unlock to clear), Homebrew `bash`
   + `fish` installed, hooks sourced in `~/.bashrc` / `~/.config/fish/config.fish`, and
   `/opt/homebrew/bin` on bash's PATH.
