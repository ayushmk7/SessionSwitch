# SessionSwitch

A menu-bar-only macOS app for seeing every running Claude Code CLI session on
your machine and switching its model/effort with a click or a global hotkey,
without ever focusing the terminal it's running in. See `../PRD.md` for the
full product spec; this document covers the v1 build, what actually works,
and how to verify it.

## Build & run

Requires macOS 14+, Xcode/Swift 5.9+ toolchain. Zero third-party
dependencies (pure SwiftPM).

```sh
cd app
swift build -c release          # release binary at .build/release/SessionSwitch
swift test                       # full unit test suite (headless, no UI)
.build/release/SessionSwitch     # run it — a "◐ N" glyph appears in the menu bar
```

For iterative development, `swift build`/`swift run` (debug) work the same
way. The app is menu-bar-only (`NSApplication.shared.setActivationPolicy(.accessory)`)
— no Dock icon, no regular window until you open Preferences.

Debug/CLI flags (`main.swift`):

- `--smoke-test`: constructs the full store/injector/presets/controller/picker
  stack, renders one menu, prints `SMOKE OK`, exits — never starts the live
  refresh timer or registers the global hotkey. Used in CI/QA to prove the
  stack wires together without spinning up a real menu bar session.
- `--dump-sessions`: runs one real `Discovery`/`StateReaderV1` scan against
  this machine and prints one line per discovered session (pid, project,
  terminal app, tty, model, state, read-only reason if any), then exits.
  No menu bar UI is shown. Useful for verifying session discovery without
  having to visually inspect the menu, e.g.:

  ```sh
  .build/debug/SessionSwitch --dump-sessions
  # pid=12345 project=SessionSwitch app=Terminal tty=ttys003 model=claude-sonnet-5 state=idle
  ```

## What works in v1

- **Discovery** (FR-1, FR-4, FR-5): finds running `claude` CLI processes via
  `ps`/`lsof` process/tty/cwd scanning + ancestry walk to the owning terminal
  app. Works for sessions started before the app launched. Terminal.app and
  iTerm2 sessions are fully controllable; everything else (VS Code, JetBrains,
  unknown terminals, no-tty/piped sessions) is marked **read-only** with a
  reason shown in the menu.
- **Live state** (FR-2 partial, FR-3): project name, current model, and
  working/idle state refresh every 2s by tailing Claude Code's on-disk
  `~/.claude/projects/<munged-cwd>/*.jsonl` session log (bounded 256 KB tail
  read — see FR-37 below). **Effort level is not shown** — Claude Code's
  on-disk state doesn't record it (see Known Limits).
- **Switching** (FR-6, FR-8, FR-9): `/model`/`/effort` slash commands are
  injected via AppleScript (`do script`/`write text`) into the exact tty of
  the target Terminal.app/iTerm2 tab. Model changes are verified by
  re-reading state within a 5s window (`.verified`/`.unverified`); effort
  changes are fire-and-forget (`.assumed` — there is no on-disk effort field
  to verify against). A per-session FIFO queue means a second request never
  overwrites a first one still in flight.
- **Busy-session behavior** (FR-8): while a session is `.working`, requests
  queue and drain automatically once it goes idle (shown as a `pending`
  label). **New in Task 9**: a Preferences toggle ("Queue changes while
  session is busy") lets you force immediate injection instead — see
  `UserDefaults` key `inject.queueWhenBusy` (default `true`).
- **Menu bar UI** (FR-15 to FR-17): "◐ N" title (amber `!` suffix when
  anything is pending); per-session Model/Effort/Preset submenus; Refresh
  Now; Preferences…; Quit.
- **Presets** (FR-28 partial, FR-29): three starter presets (Deep Work,
  Balanced, Cheap & Fast). Preferences lets you rename, delete, and restore
  the seed defaults. Creating brand-new presets and reordering are **not**
  implemented in v1 (see Known Limits/FR table).
- **Global hotkey quick picker** (FR-24, FR-25, FR-27): ⌥⌘M opens a
  Spotlight-style panel (Carbon global hotkey, no Accessibility permission
  needed). Type to filter by project name, Tab cycles Model/Effort/Preset,
  ↑/↓ navigate, Enter applies, Esc cancels.
- **Preferences window** (new in Task 9): Injection behavior toggle,
  live Automation-permission status for Terminal.app/iTerm2 with a button to
  jump to System Settings, Launch at Login (SMAppService), and preset
  management. Forced dark appearance (`.darkAqua`) — the app has no
  light-mode Mono Glass treatment.
- **Privacy** (FR-37): state reading never parses message content — only a
  bounded tail scan for the literal `"model":"…"` field and file mtimes. No
  network calls anywhere in the app.

## Known limits (v1)

- **VS Code / JetBrains terminals are read-only.** They're discovered and
  shown in the menu (correct project/tty/terminal-app), but the app cannot
  script them — no AppleScript dictionary, and Accessibility-based keystroke
  injection was out of scope for this v1 slice. Confirmed live on this
  machine via `--dump-sessions`: real VS Code-hosted `claude` sessions show
  up correctly marked `READONLY(Code not scriptable in v1)`.
- **Effort is unverifiable.** Claude Code's on-disk jsonl state never
  records the current effort level, so: (a) the menu/picker never show a
  session's *current* effort (no checkmark, unlike Model), and (b) an
  `/effort` injection resolves `.assumed` immediately rather than being
  confirmed against real state. This is a hard constraint of the current
  on-disk format, not a bug — see `docs/superpowers/plans/2026-07-06-app-v1.md`.
- **Quick picker's `.onKeyPress` interaction with the search `TextField` is
  live-verify-only.** SwiftUI's `.onKeyPress(.upArrow/.downArrow/.tab/.return)`
  is attached to the whole `PickerView` and is documented to intercept those
  keys even while the `TextField` holds focus, but no headless test (XCTest
  has no real key-event/focus loop) or `--smoke-test` run can exercise this.
  **Needs a manual check**: `swift run`, press ⌥⌘M, confirm typing filters
  the list AND ↑/↓/Tab/Enter/Esc all still work while the search field is
  focused.
- **`cwd` resolution can silently come back empty for some pids.** Observed
  live on this machine: `lsof -a -p <pid> -d cwd -Fn` returns nothing for a
  handful of real `claude` processes (cross-session/user boundary in this
  environment), which surfaces as a blank project name in the menu — the
  terminal app / tty / read-only detection for that session still work
  correctly, only the project label is affected.
- **No frontmost-window detection.** FR-26 ("act on the frontmost terminal
  window's session by default") isn't implemented — the quick picker's
  default selection is just the first non-read-only session in
  project-name-sorted order, not whichever terminal window actually has
  keyboard focus.
- **Model catalog is a static, hardcoded list of 4 models** (Fable 5, Opus
  4.8, Sonnet 5, Haiku 4.5), not built dynamically from the user's Claude
  Code installation (FR-11/FR-13/FR-14 deferred; matches the app-v1 plan's
  explicit "deferred to v1.1" note).
- **`SMAppService.mainApp.register()`/`unregister()` require a real `.app`
  bundle.** This is a plain SwiftPM executable (no bundle). Verified live on
  this machine, the failure mode is inconsistent: `unregister()` throws
  `SMAppServiceErrorDomain Code=1 "Operation not permitted"`, while
  `register()` can return *without* throwing yet leave `status` stuck at
  `.notFound` (a silent no-op). Preferences checks the resulting `status`
  after the call either way and shows a "requires a proper .app bundle" note
  whenever it doesn't match what was requested, rather than trusting the
  absence of a thrown error — this is expected for a `swift build` binary; a
  notarized `.app` distribution (out of scope here) would not hit this.
- **`Permissions.swift` API naming correction**: the originating task brief
  named the automation-status API `AEDeterminePermissionToAppleEvents`. That
  symbol does not exist in the macOS SDK (checked against
  `AE.framework/Headers/AppleEvents.h` directly) — the real, documented API
  for exactly this "check without prompting" behavior is
  `AEDeterminePermissionToAutomateTarget` (10.14+), which is what's actually
  implemented; it returns the identical four raw codes the brief specified
  (`noErr`/`errAEEventNotPermitted`/`errAEEventWouldRequireUserConsent`/`procNotFound`).
- No floating per-window overlay badge (PRD §6.5 / Milestone M4), no "New
  Session…" launcher (FR-10), no per-preset hotkeys (FR-30), no org-policy
  clamp detection (FR-35), no notification-center integration (a transient
  menu-bar title flash is used instead — see Task 7's report) — all out of
  scope for this 9-task v1 slice.

## Permissions walkthrough

SessionSwitch needs **Automation** (AppleEvents) permission to script
Terminal.app and/or iTerm2 — this is what actually lets `/model`/`/effort`
get typed into a session's tab. There is no Accessibility permission
requirement anywhere in this app (the global hotkey uses Carbon's
`RegisterEventHotKey`, which needs no permission at all).

1. Open **Preferences…** from the menu bar icon.
2. The **Permissions** section shows a live status for Terminal and iTerm2:
   - `granted` — already permitted (cyan).
   - `denied` — permission was explicitly refused; fix in System Settings.
   - `not determined` — never asked yet; the *first* real injection attempt
     against that app will trigger the system's consent prompt.
   - `not running (will prompt on first use)` — the target app isn't running
     right now, so macOS can't evaluate the relationship yet.
3. Click **Open System Settings…** to jump straight to
   *Privacy & Security → Automation*, where you can toggle SessionSwitch's
   access to each app once it's appeared there (it appears after the first
   real injection attempt, not before).
4. If you fat-finger a denial: quit and relaunch SessionSwitch after
   re-enabling it in System Settings — automation permission changes aren't
   always picked up mid-process by AppleEvents.

## FR → status mapping (PRD §6)

| FR | Requirement (short) | Status |
|----|----------------------|--------|
| FR-1 | Detect running Claude Code sessions (Terminal/iTerm2/VS Code/JetBrains) | Done — all four discovered; only Terminal/iTerm2 controllable |
| FR-2 | Show project, model, effort, state, terminal app | Partial — no effort (unverifiable, see Known Limits) |
| FR-3 | Refresh within 2s | Done — 2s poll |
| FR-4 | Discover pre-existing sessions | Done |
| FR-5 | Mark uncontrollable sessions read-only + reason | Done |
| FR-6 | Inject via AppleScript/Accessibility, verify | Done for Terminal/iTerm2 via AppleScript; no Accessibility/IDE path |
| FR-7 | Don't clobber typed input; queue by default | Done via queue-by-default (not literal cut/restore) |
| FR-8 | Queue while busy + user can force immediate | Done (Task 9 adds the force toggle) |
| FR-9 | Verify within 5s, show requested-vs-applied on mismatch | Done for model; effort has no verification source |
| FR-10 | "New Session…" launcher | Not implemented |
| FR-11 | Dynamic model catalog from installation | Not implemented — static 4-model catalog |
| FR-12 | Valid effort levels per model, warn on mismatch | Partial — offers only valid levels; no explicit clamp-warning UI |
| FR-13 | Custom models via env/gateway | Not implemented |
| FR-14 | Catalog refresh on launch/demand | Not implemented |
| FR-15 | Menu bar count + attention indicator | Done |
| FR-16 | Dropdown list, model/effort chips, single-click apply | Done (submenus, not chips) |
| FR-17 | Preset row + New Session/Preferences/Refresh | Partial — preset+Preferences+Refresh done; no New Session |
| FR-18 | Row click focuses terminal window | Not implemented |
| FR-19–23 | Floating per-window overlay badge | Not implemented (M4, out of scope) |
| FR-24 | Global hotkey opens picker | Done (⌥⌘M) |
| FR-25 | Filterable picker, Tab/arrows/Enter/Esc | Done |
| FR-26 | Default to frontmost terminal window's session | Not implemented — defaults to first non-read-only match |
| FR-27 | ≤3 keystrokes hotkey→applied | Partial — reachable, but not frontmost-aware |
| FR-28 | Create/rename/reorder/delete presets | Partial — rename/delete/restore done; no create/reorder |
| FR-29 | Ship starter presets | Done |
| FR-30 | Per-preset global hotkeys | Not implemented |
| FR-31 | Preferences: hotkeys, badge, injection, launch-at-login, per-app enablement, notif verbosity | Partial — injection + launch-at-login done; rest not implemented |
| FR-32 | Persist locally, no cloud sync | Done (UserDefaults only) |
| FR-33 | Never write settings.json by default; opt-in write w/ backup | N/A — feature not offered at all (trivially never writes) |
| FR-34 | Failure notification + rollback displayed state | Partial — menu-bar flash + state resync; no descriptive notification |
| FR-35 | Org-policy clamp display | Not implemented |
| FR-36 | Detect out-of-band `/model` changes, don't fight user | Done (natural consequence of polling live state) |
| FR-37 | Never read message content, no network calls | Done |

## Manual test checklist

Everything below needs a live macOS session with real Terminal.app/iTerm2
windows — none of it is exercisable by `swift test` or `--smoke-test`.

1. **Build & launch**: `swift build -c release && .build/release/SessionSwitch`.
   Confirm a "◐ N" glyph appears in the menu bar (N = number of discovered
   sessions) with no Dock icon.
2. **Real discovery**: open a Terminal.app tab, `cd` into any project, run
   `claude`. Within ~2s, confirm a new row appears in the SessionSwitch menu
   with the correct project name, "Terminal", and its tty.
3. **Model switch + Automation prompt**: from that row's Model submenu, pick
   a different model. First time ever scripting Terminal.app, macOS will
   show an Automation consent dialog — approve it. Confirm the command
   actually lands in the terminal (you'll see `/model <alias>` typed and
   run) and the menu bar briefly flashes a cyan ✓.
4. **Busy-session queue**: while the session is actively responding
   (working, cyan dot), request another model change. Confirm it shows as
   `pending` (amber) in the menu and drains automatically once the response
   finishes.
5. **Force-immediate toggle**: open Preferences, turn OFF "Queue changes
   while session is busy". Repeat step 4 — the change should now inject
   immediately instead of waiting for idle. Turn it back on afterward.
6. **iTerm2**: repeat steps 2–3 in an iTerm2 tab if installed; same consent
   dialog + verification flow, `write text` instead of `do script`.
7. **Read-only session**: open the same `claude` session inside VS Code's
   integrated terminal. Confirm it appears in the menu marked read-only
   ("Code not scriptable in v1") with disabled Model/Effort/Preset submenus.
8. **Preset apply**: use the Preset submenu (or the quick picker's Preset
   mode) to apply "Deep Work" to an idle session; confirm both the model
   *and* effort slash commands land, in order.
9. **Quick picker**: press ⌥⌘M. Confirm the panel opens centered, typing
   filters sessions by project name, Tab cycles Model → Effort → Preset,
   ↑/↓ move the selection, Enter applies and closes, Esc cancels. This is
   the manual check for the `.onKeyPress`-vs-focused-`TextField` caveat
   above.
10. **Permissions status**: open Preferences → Permissions. Confirm the
    Terminal/iTerm2 rows reflect reality (`granted` after step 3/6's
    consent; `not running (will prompt on first use)` if you quit that app
    first). Click "Open System Settings…" and confirm it lands on
    *Privacy & Security → Automation*.
11. **Launch at Login**: toggle it on in a `swift build` debug/release
    binary; confirm it shows the "requires a proper .app bundle" note rather
    than crashing (expected for an unbundled SwiftPM binary).
12. **Presets management**: rename a preset, delete one, then "Restore
    Defaults" and confirm the original three come back.
