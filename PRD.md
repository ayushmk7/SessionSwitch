# PRD: SessionSwitch — Per-Session Model & Effort Control for Claude Code on macOS

**Version:** 1.0 (Draft)
**Author:** [Your name]
**Date:** July 5, 2026
**Status:** Draft for review

---

## 1. Overview

SessionSwitch is a lightweight macOS utility that lets a developer see every running Claude Code session on their machine and change the model and effort level of any individual session with a single click. Each session keeps its own independent setting — one terminal can run a frontier model at high effort for hard debugging while another runs a faster model at low effort for routine chores — without the developer ever typing `/model` or `/effort` by hand.

The switcher is surfaced in three complementary ways: a persistent menu bar dropdown, a floating overlay badge pinned near each Claude Code window, and a global-hotkey quick picker for keyboard-driven switching.

## 2. Problem Statement

Claude Code exposes model and effort controls, but they are buried in per-session ceremony. Today, changing either one requires the developer to focus the right terminal, interrupt whatever the agent is doing, and type a slash command (`/model`, `/effort`) or restart the session with CLI flags (`--model`, `--effort`). Developers who run several parallel Claude Code sessions — a common workflow with git worktrees and multi-agent setups — face three recurring pains:

1. **No visibility.** There is no single place to see which model and effort level each running session is using. The status bar inside each terminal shows it, but only for the focused window.
2. **High friction to change.** Switching model or effort is a multi-step, per-terminal action. Developers routinely leave sessions on the wrong (usually most expensive) configuration because switching is annoying.
3. **Cost and quality mismatch.** Model and effort are independent axes with real cost and latency consequences. Running a flagship model at maximum effort for a trivial rename wastes tokens and rate-limit budget; running a small model at low effort on a hard architectural problem wastes the developer's time.

## 3. Goals

1. Reduce a model or effort change on any running session to a single click or a two-keystroke hotkey flow.
2. Give the developer an always-available, glanceable view of every Claude Code session and its current model + effort.
3. Support truly independent per-session settings — changing one session never affects another.
4. Never corrupt, interrupt, or degrade the underlying Claude Code session.

### Non-Goals (v1)

- Controlling Claude Desktop chat windows, Claude Code on web, or the Claude API directly.
- Windows or Linux support.
- Managing organization/managed settings, availableModels policies, or admin effort caps (the app must *respect* these, not manage them).
- Cost dashboards or token-usage analytics (candidate for v2).
- Automatic model routing based on task content (candidate for v2).

## 4. Target User

A single primary persona: the **multi-session power developer** on macOS. They run 2–8 concurrent Claude Code sessions across Terminal, iTerm2, VS Code, and/or JetBrains terminals. They are cost- and rate-limit-aware (often on Pro/Max plans) and already understand the model-vs-effort tradeoff. They want control, not automation.

## 5. User Stories

1. As a developer, I can see all my running Claude Code sessions in one menu bar list, each showing project directory, model, effort, and busy/idle state, so I always know what is running where.
2. As a developer, I can click a session in the menu bar and pick a new model from a submenu, and that session switches within seconds.
3. As a developer, I can click an effort chip (e.g., low / medium / high / higher tiers where supported) on the floating badge attached to a Claude Code window, and only that session changes.
4. As a developer, I can press a global hotkey, see a quick picker of sessions, arrow/type to one, and apply a saved preset (model + effort combo) with Enter.
5. As a developer, I can define presets like "Deep Work" (flagship model, high effort) and "Cheap & Fast" (small model, low effort) and apply them in one action.
6. As a developer, I can set a default preset that new sessions launched through the app start with.
7. As a developer, if a switch fails (unsupported model, org cap, session busy), I get a clear notification explaining what happened and what was actually applied.

## 6. Functional Requirements

### 6.1 Session Discovery & Monitoring

- **FR-1:** The app SHALL detect all running interactive Claude Code CLI sessions on the machine, including those inside Terminal.app, iTerm2, VS Code integrated terminals, and JetBrains terminals. Detection strategy: process scanning for `claude` processes, correlated with Claude Code's on-disk session/state data and, where available, its status-line/hooks integration points.
- **FR-2:** For each session, the app SHALL display: project directory (or session name if set), current model, current effort level, session state (idle / working / awaiting permission), and the host terminal app.
- **FR-3:** Session state SHALL refresh within 2 seconds of a change (polling or file-watch on Claude Code state files; hook-based push where feasible).
- **FR-4:** Sessions started before the app launched SHALL still be discovered.
- **FR-5:** The app SHALL gracefully mark sessions it can see but cannot control (e.g., a session inside an SSH remote, or a terminal app it lacks Accessibility access to) with a "read-only" indicator and a tooltip explaining why.

### 6.2 Applying Changes to a Live Session

Claude Code changes model and effort mid-session via the `/model` and `/effort` slash commands. The app applies changes through a tiered mechanism:

- **FR-6 (primary mechanism):** The app SHALL inject the appropriate slash command (e.g., `/model <alias-or-id>`, `/effort <level>`) into the target session's terminal via macOS Accessibility APIs / scripting bridges (AppleScript for Terminal.app and iTerm2; Accessibility keystroke injection for IDE terminals), then confirm the change by re-reading session state.
- **FR-7 (safety):** The app SHALL NOT inject while the session is mid-prompt with user-typed text in the input buffer. If text is present, the app SHALL preserve it (cut, inject command, restore) or queue the change until the input is clear, per a user setting. Default: queue and notify.
- **FR-8 (busy sessions):** If the agent is actively working, the app SHALL queue the change and apply it at the next idle point, showing a "pending" state on the session row/badge. The user MAY force immediate injection.
- **FR-9 (verification):** Every switch SHALL be verified against actual session state within 5 seconds. On mismatch (e.g., an org cap clamped the requested effort to a lower level), the app SHALL show what was requested vs. what was applied.
- **FR-10 (new sessions):** The app SHALL offer a "New Session…" action that launches Claude Code in a chosen directory and terminal with `--model` and `--effort` flags pre-applied from a preset.

### 6.3 Model & Effort Catalog

- **FR-11:** The app SHALL build its model list dynamically from what the user's Claude Code installation actually offers (parsing `/model` picker data / config / documented aliases), rather than hardcoding model names. Aliases (e.g., `sonnet`, `opus`, `haiku`, `opusplan`) and full model IDs SHALL both be supported.
- **FR-12:** The app SHALL know which effort levels each model supports (levels vary by model; some models do not support effort at all) and SHALL only offer valid levels for the target session's current or pending model. When the user picks an unsupported combination, the app SHALL warn and show the fallback level Claude Code will actually use.
- **FR-13:** Custom models configured via environment variables or gateway setups SHALL appear in the list if Claude Code exposes them in its picker.
- **FR-14:** The catalog SHALL refresh on app launch and on demand, so new model releases appear without an app update.

### 6.4 Surface 1 — Menu Bar Dropdown

- **FR-15:** A persistent menu bar icon SHALL show, at a glance, the count of running sessions and an attention indicator if any session awaits permission.
- **FR-16:** The dropdown SHALL list all sessions. Each row: project name, model chip, effort chip, state dot. Clicking the model chip opens a model submenu; clicking the effort chip cycles or opens levels — both are single-click applies.
- **FR-17:** The dropdown SHALL include a preset row per session ("Apply preset →") and global actions: New Session, Preferences, Refresh.
- **FR-18:** A session row click SHALL focus/raise the corresponding terminal window.

### 6.5 Surface 2 — Floating Per-Window Overlay

- **FR-19:** For each detected Claude Code window, the app SHALL render a small floating badge (pill) docked to a corner of that window showing the session's model + effort.
- **FR-20:** The badge SHALL track window move/resize/minimize/space-switch within 100 ms perceived latency and hide when the window is occluded, minimized, or in a different Space.
- **FR-21:** Clicking the badge SHALL expand it into a compact picker: model list on one side, effort levels on the other, presets along the bottom. One click on any item applies and collapses.
- **FR-22:** The badge SHALL be per-display and DPI aware, draggable to any corner (position remembered per app), and fully disableable globally or per terminal app in Preferences.
- **FR-23:** The badge SHALL never intercept keyboard focus from the terminal.

### 6.6 Surface 3 — Global Hotkey Quick Picker

- **FR-24:** A user-configurable global hotkey (default: ⌥⌘M) SHALL open a Spotlight-style picker centered on screen.
- **FR-25:** The picker SHALL list sessions, filterable by typing project names. Arrow keys navigate; Tab toggles between "choose model," "choose effort," and "choose preset" modes; Enter applies; Esc cancels.
- **FR-26:** The picker SHALL support acting on the session belonging to the frontmost terminal window by default (zero navigation needed for the common case: hotkey → pick preset → Enter).
- **FR-27:** The full flow — hotkey to applied change — SHALL be achievable in ≤ 3 keystrokes for the frontmost session.

### 6.7 Presets

- **FR-28:** Users SHALL be able to create, rename, reorder, and delete presets. A preset = model + effort level (+ optional color/icon).
- **FR-29:** The app SHALL ship with sensible starter presets (e.g., Deep Work, Balanced, Cheap & Fast) that the user can edit, built from whatever models the installation exposes.
- **FR-30:** Presets SHALL be assignable to per-preset global hotkeys (e.g., ⌥⌘1 applies preset 1 to the frontmost session).

### 6.8 Preferences & Persistence

- **FR-31:** Preferences SHALL cover: hotkeys, badge visibility/position, injection behavior (queue vs. force), launch at login, per-terminal-app enablement, and notification verbosity.
- **FR-32:** The app SHALL persist presets and preferences locally (no cloud sync in v1).
- **FR-33:** The app SHALL NOT write to Claude Code's `settings.json` by default. Optional (off by default): "Set default model/effort for future sessions," which writes the documented `model` / effort fields to user-level settings with an explicit confirmation, a timestamped backup of the file, and a note that shell env vars and managed settings can take precedence.

### 6.9 Errors, Conflicts & Guardrails

- **FR-34:** If an injected command fails (session died, terminal unscriptable, command rejected), the app SHALL surface a notification with the reason and roll back its displayed state to reality.
- **FR-35:** If organization policies (managed settings, model restrictions, effort caps) constrain a request, the app SHALL display the applied (clamped) value and label it "limited by org policy."
- **FR-36:** The app SHALL detect out-of-band changes (user typed `/model` manually) and update its display rather than fighting the user.
- **FR-37:** The app SHALL never send any prompt text, code, or session content anywhere. It reads only session metadata.

## 7. Technical Approach (Summary)

- **Platform:** Native macOS app (Swift/SwiftUI + AppKit for NSStatusItem, borderless overlay NSPanels, and CGEvent/AXUIElement for window tracking and injection). Menu-bar-only app (LSUIElement), no Dock icon.
- **Session discovery:** `NSWorkspace`/`libproc` process enumeration for `claude` processes → map PID → TTY → owning terminal window; cross-reference Claude Code's local state directory for session metadata (model, effort, project path). A Claude Code status-line or hook script (installed optionally by the app, with user consent) can push richer, lower-latency state.
- **Command injection:** AppleScript (`osascript`) for Terminal.app/iTerm2 "write text" APIs where available; Accessibility keystroke synthesis as the fallback for IDE terminals. All injection paths append a newline and verify via state read-back.
- **Window tracking for overlays:** Accessibility API (AXObserver) for window frame/visibility events; overlay panels at `.floating` level, click-through except on the pill itself.
- **Permissions required:** Accessibility (mandatory for injection + window tracking), Automation/AppleEvents per terminal app (prompted on first use), optionally Screen Recording only if window-occlusion detection requires it (avoid if possible). First-run onboarding SHALL walk through granting these with live status checks.
- **Distribution:** Direct download (notarized DMG) — Accessibility-dependent apps are a poor fit for Mac App Store sandboxing. Sparkle for auto-updates.

## 8. UX Notes

- Model chips use short display names; hovering shows full model ID and a one-line cost/speed hint.
- Effort chips use a filled-bars glyph (▁▃▅▇) so relative effort is readable at a glance without text.
- Pending changes render as a pulsing outline on the chip until verified.
- All three surfaces share one state store — a change made in any surface reflects everywhere within one refresh tick.
- Dark/light mode native; respects Reduce Motion.

## 9. Non-Functional Requirements

- **Performance:** Idle CPU < 0.5%; memory < 80 MB with 8 sessions; overlay tracking must not cause visible lag in terminal rendering.
- **Reliability:** Injection success rate ≥ 99% on supported terminals; zero instances of corrupting a session's input buffer in QA.
- **Compatibility:** macOS 14+; Claude Code v2.x; Terminal.app, iTerm2, VS Code, JetBrains (tier 1). Ghostty, Warp, Kitty, Alacritty and tmux-multiplexed sessions are tier 2 (best-effort read-only in v1, full support evaluated for v1.1).
- **Resilience to Claude Code updates:** All Claude Code-specific parsing (state files, picker data) isolated behind a versioned adapter layer; unknown formats degrade to read-only mode with an "update SessionSwitch" prompt, never a crash.
- **Privacy/Security:** No network calls except the update check. No analytics in v1. No reading of conversation content.

## 10. Success Metrics

- Median time-to-switch (user intent → verified change): ≤ 3 seconds via any surface.
- ≥ 90% of switches performed through the app (vs. manual slash commands) among active users after 2 weeks, measured locally and shown to the user (no telemetry upload).
- Injection failure rate < 1%.
- Qualitative: user can state the model/effort of every running session without focusing any terminal.

## 11. Milestones

1. **M1 — Engine (2–3 wks):** Session discovery, state reading, injection for Terminal.app + iTerm2, verification loop.
2. **M2 — Menu bar (1–2 wks):** Full dropdown UI, presets, New Session.
3. **M3 — Hotkey picker (1 wk):** Quick picker + per-preset hotkeys.
4. **M4 — Overlays (2 wks):** Window tracking, badges, expand-to-pick.
5. **M5 — Hardening (1–2 wks):** IDE terminals, org-policy clamp handling, onboarding for permissions, notarization.

## 12. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Claude Code changes state-file format or slash-command behavior | Switching breaks | Versioned adapter layer; read-only degradation; fast-follow updates |
| Accessibility injection is fragile in IDE terminals | Tier-1 promise slips | AppleScript-first for scriptable terminals; explicit tiering; queue-and-verify design |
| Injection collides with user typing | Trust-destroying UX bug | FR-7 buffer preservation; queue-by-default; extensive QA scenario matrix |
| Org-managed settings silently clamp requests | User confusion | FR-9/FR-35 requested-vs-applied display |
| Multiple sessions in one tmux pane/window | Ambiguous targeting | v1: mark as read-only; v1.1: tmux `send-keys` integration |

## 13. Open Questions

1. Should the app optionally install a Claude Code hook/status-line script for push-based state (faster, richer) vs. staying purely observational (zero footprint)? Recommended: optional, on by default with clear consent in onboarding.
2. Effort semantics differ by model and evolve across Claude Code releases (available levels, defaults, per-model resets after switching). How aggressively should the app normalize this vs. mirror Claude Code's own picker verbatim? Recommendation: mirror verbatim, annotate.
3. Is "apply preset to ALL sessions at once" wanted (e.g., end-of-day downshift to cheap mode)? Cheap to add; slight foot-gun.
4. Should v1.1 add a "budget guard" (warn when N sessions are simultaneously on flagship+max-effort)?

## 14. Out of Scope / Future (v2+)

Cost & token dashboards; automatic per-task model routing; Claude Desktop and Claude Code-on-web control; Windows/Linux; team-shared preset sync; tmux/SSH remote session control.