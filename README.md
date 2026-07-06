# SessionSwitch

A macOS menu-bar utility for per-session model & effort control of Claude
Code CLI sessions. Full product spec: [`PRD.md`](./PRD.md).

This repo has two parts:

- **`app/`** — the actual native macOS app (Swift Package Manager, zero
  third-party dependencies).
- **`design-lab/`** — the interactive design-exploration playground used to
  pick the app's visual language before any Swift was written.

## App

Menu-bar-only SwiftUI/AppKit app: discovers running `claude` CLI sessions
(Terminal.app, iTerm2, VS Code, JetBrains), shows each one's project/model/
state, and lets you switch model/effort per session via the menu bar
dropdown, a global hotkey (⌥⌘M) Spotlight-style quick picker, and saved
presets — all injected via AppleScript and verified against Claude Code's
on-disk session state.

```sh
cd app
swift build -c release
.build/release/SessionSwitch
```

See [`app/README.md`](./app/README.md) for full build/run instructions,
what works in v1 vs. known limits, the permissions walkthrough, the
FR-by-FR status table, and the manual test checklist.

## Design Lab

10 interactive design directions for SessionSwitch. Pick one.

    cd design-lab && python3 -m http.server 4400

Open http://localhost:4400 — click a card. ←/→ cycles variants, 1–0 jumps,
⌘K opens the quick picker inside any variant.

Engine self-test: `node shared/engine.test.mjs`

The shipping app's visual language ("Mono Glass": dark, ink `#f2f2f2`, dim
`#9a9a9a`, amber/cyan/red used only as status signals) was picked from
variant 11 in this lab — see `design-lab/variants/11-mono-glass/`.
