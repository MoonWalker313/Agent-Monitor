# AgentBar — PRD

**A macOS menu bar app that shows what your AI agents are doing and taps you on the shoulder when one needs you.**

| | |
|---|---|
| **Status** | Draft v0.2 — core technical decisions made |
| **Date** | 2026-11-16 |
| **Platform** | macOS 13 Ventura+, native Swift/SwiftUI menu bar app, distributed as an ad-hoc-signed `.dmg` (no Apple Developer account) |
| **Working name** | AgentBar (placeholder) |

---

## 0. Decisions Log

| # | Decision | Rationale |
|---|---|---|
| D1 | **Minimum OS: macOS 13 Ventura** | Unlocks SwiftUI `MenuBarExtra` and `SMAppService` (modern launch-at-login) with no legacy AppKit fallback. |
| D2 | **Native Swift + SwiftUI** (AppKit where needed) | Small binary, low idle CPU/battery, first-class menu bar and notification behavior. |
| D3 | **Event ingestion = Unix domain socket only, verified by peer UID. No localhost HTTP port, no shared token.** | See *Security model* below — best balance of zero-setup UX and real protection. |
| D4 | **No Apple Developer account. Ship an ad-hoc-signed, non-notarized `.dmg`.** | Zero cost and no account overhead. Trade-off: a one-time Gatekeeper approval on first launch (see P0-8), which onboarding must handle gracefully. |

### Security model for event ingestion (D3)

**Threats that matter:**
1. **Web pages in the user's browser** sending fake events (e.g. a malicious site POSTing to `localhost:PORT` or using DNS rebinding) — the most realistic attack on any local HTTP listener.
2. **Other user accounts** on the same Mac reading or injecting events.
3. **Malformed or hostile event content** (huge payloads, control characters, misleading text, malicious `open_url`s) — e.g. an event whose `open_url` launches an arbitrary app or `file://` path.

**Recommended design:**
- **No TCP/HTTP listener at all.** Browsers can't open Unix sockets, so threat 1 is removed entirely rather than mitigated.
- **Socket at `~/Library/Application Support/AgentBar/agentbar.sock`**, directory `0700`, socket `0600` → only the current user can connect.
- **Peer-credential check** on every connection (`getpeereid` / `LOCAL_PEERCRED`): reject any client whose UID ≠ the app's UID. This covers threat 2 even if file permissions are misconfigured.
- **No token.** Any process running as the same user could read a token file anyway, so a token adds setup friction (copying secrets into hook configs) without stopping a real same-user attacker. Same-user malware is out of scope — it already owns the account.
- **Treat all event content as untrusted:** 16 KB max event size; strip control/bidi characters; render as plain text (no markdown/HTML); cap `title` at 80 chars and `message` at 280; rate-limit each session to 20 events/s and drop the excess.
- **`open_url` allowlist:** accept only `https`, known editor/terminal schemes (`vscode://`, `cursor://`, `iterm2://`, etc.), and a bundle-ID activation hint. **Never `file://`, never executable paths, never shell commands.** The first time a new scheme is used, ask the user to confirm.
- **For tools that can only speak HTTP**, the bundled `agentbar` CLI is the bridge (`agentbar emit` → socket). No network listener is ever opened.

**UX result:** zero configuration. Install the CLI, paste the hook snippet, done — no ports, no tokens, no secrets in config files.

---

## 1. Problem Statement

Developers now run several AI agents at once — coding agents in terminals, agents inside IDEs, background automations — and each one periodically **stops and waits** for a permission approval, an answer, or a review. Because those agents live in scattered windows and tabs, the human only notices a blocked agent when they happen to look, so agents sit idle for minutes or hours, finished work goes unreviewed, failures go unnoticed, and token spend accumulates invisibly.

There is no single, always-visible place on the computer that answers: *"What are my agents doing right now, and which one needs me?"* Every minute an agent waits unnoticed is wasted parallelism — the main reason to run multiple agents in the first place.

## 2. Goals

1. **Cut agent idle-while-blocked time.** Median time from "agent needs input" to "user responds" drops below **60 seconds** for users with AgentBar running (baseline to be measured in beta; hypothesis: 5–15 min today).
2. **One glance = full picture.** A user can tell how many agents are running, waiting, done, or failed **without opening any other window** — from the menu bar icon alone in < 1 second, and from the dropdown in < 5 seconds.
3. **Works with any agent.** Any agent or tool can report into AgentBar through a documented, generic adapter with **≤ 15 minutes of setup** for a developer following the docs.
4. **Installs on any Mac (macOS 13+) with low friction.** A user goes from downloading the `.dmg` to seeing their first agent event in **< 5 minutes**, including the one-time Gatekeeper approval, and **≥ 90%** of users get past that approval step without help.
5. **Interrupts only when it matters.** ≥ 80% of attention popups are acted on (clicked through or explicitly dismissed), not ignored — a proxy for "notifications are signal, not noise."

## 3. Non-Goals (v1)

| Non-goal | Why it's out |
|---|---|
| **Controlling agents beyond permission decisions** (typing replies, stopping runs from AgentBar). *Changed 2026-11-16: Allow / Deny for permission requests is now in scope (P0-9), at the user's request.* | Each agent has its own approval model and security boundary; acting on a user's behalf across tools is risky and adapter-specific. v1 *routes you to* the agent; it doesn't *act for* you. Candidate for P2. |
| **Windows / Linux** | "Top bar app" + `.dmg` is a macOS form factor. Cross-platform would double UI work before the core loop is proven. |
| **Cloud sync / team dashboards** | Activity data is local and potentially sensitive (file paths, prompts). A personal, local-first tool ships faster and avoids a privacy/backend project. |
| **Full transcripts or log viewer** | AgentBar is a *status* surface, not an observability tool. Showing summaries + a jump-to link keeps scope tight. |
| **Screen-scraping / guessing agent state** from unmodified apps | Unreliable and brittle; also needs invasive permissions (Accessibility, Screen Recording). Agents must report via the adapter. |

## 4. Personas

- **Multi-agent developer (primary):** Runs 2–6 agents in parallel across terminals and IDEs. Wants to stay in flow on their own work and be pulled in only when an agent is blocked or done.
- **Agent/tool author (secondary):** Builds or maintains an agent, script, or automation and wants it to show up in AgentBar with minimal integration work.
- **Cost-conscious user (secondary):** Pays per token and wants to know when spend crosses a limit before the bill does.

## 5. User Stories

### Multi-agent developer
1. As a developer running several agents, I want to see at a glance in the menu bar how many agents are **waiting on me**, so that I know whether to switch context without opening anything.
2. As a developer, I want a **popup notification when an agent is waiting for permission or input**, so that it doesn't sit blocked while I'm focused elsewhere.
3. As a developer, I want to **click a notification or list item and land in the right terminal/IDE/session**, so that I can respond in one step.
4. As a developer, I want to be notified when an agent **finishes its task**, so that I can review the result while the context is still fresh.
5. As a developer, I want to be alerted when an agent **errors, crashes, or appears stuck** (no events for a configurable period), so that I don't wait on work that is never coming.
6. As a developer, I want a **today summary** (agents run, tasks finished, time spent waiting on me, tokens/cost), so that I understand how I'm using agents.
7. As a developer, I want to **mute or snooze** notifications (globally, per agent, or per event type), so that I can focus during meetings or deep work.
8. As a developer, I want AgentBar to **respect macOS Focus / Do Not Disturb**, so that it behaves like a good citizen on my machine.

### Cost-conscious user
9. As a user paying for tokens, I want to set a **daily cost or token threshold** and be alerted when it's crossed, so that I can stop runaway spend.

### Agent/tool author
10. As an agent author, I want a **simple, documented way to emit events** (CLI command or local HTTP call) so that my agent shows up in AgentBar without depending on an SDK.
11. As an agent author, I want **copy-paste reference adapters** (e.g. Claude Code hooks, a shell wrapper for any CLI agent) so that common setups work immediately.

### Edge cases
12. As a new user with **no agents connected**, I want an empty state that tells me how to connect my first agent, so that I'm not staring at a blank menu.
13. As a user whose agent **process dies without sending a "stopped" event**, I want AgentBar to mark it stale/disconnected rather than "running" forever.
14. As a user with **many sessions** (20+ in a day), I want the dropdown to stay readable — active and waiting items first, finished ones collapsed.
15. As a user, I want AgentBar to **launch at login** and keep working after sleep/wake, so that I never have to remember to start it.

## 6. Requirements

### P0 — Must-have (cannot ship without)

#### P0-1 Menu bar status icon
Persistent icon in the macOS menu bar reflecting aggregate state.
- [ ] Icon shows a distinct state for: **idle** (no active agents), **working** (≥1 running, none waiting), **needs attention** (≥1 waiting/errored).
- [ ] When ≥1 agent needs attention, a **count badge** shows the number waiting.
- [ ] State changes reflect within **1 second** of the event being received.
- [ ] Icon is legible in light and dark menu bars and supports template rendering.

#### P0-2 Dropdown summary panel
Clicking the icon opens a panel listing sessions and a daily summary.
- [ ] Sessions grouped and ordered: **Needs you → Running → Finished today → Errored/Stale**.
- [ ] Each row shows: agent name/icon, session label (e.g. project/folder), current state, time in state, and last status message (truncated, one line).
- [ ] Header shows today's totals: sessions run, tasks finished, total time agents waited on the user, tokens/cost (when reported).
- [ ] Clicking a row **opens the agent's source** via the `open_url` / app-activation hint supplied by the adapter; if none, it copies the session ID and shows the working directory.
- [ ] Empty state explains how to connect an agent and links to adapter setup.

#### P0-3 Generic agent adapter (event ingestion)
A local, agent-agnostic way for any tool to report activity.
- [ ] **Unix domain socket only** at `~/Library/Application Support/AgentBar/agentbar.sock` (dir `0700`, socket `0600`); **no TCP/HTTP listener** of any kind (D3).
- [ ] Every connection is checked with `getpeereid`; connections from a different UID are refused and logged.
- [ ] Bundled **CLI** (`agentbar emit …`) installed optionally to the user's PATH (from Settings, into `~/.local/bin` or `/usr/local/bin` with consent), wrapping the socket call.
- [ ] Versioned **event schema** (JSON) with at minimum: `agent`, `session_id`, `event` (`started`, `working`, `needs_input`, `needs_permission`, `finished`, `error`, `heartbeat`, `stopped`), `timestamp`, optional `title`, `message`, `cwd`, `open_url`, `usage` (`input_tokens`, `output_tokens`, `cost_usd`).
- [ ] Invalid events are rejected with a clear error message and don't crash the app.
- [ ] Event content is sanitized per the security model: 16 KB size cap, control/bidi characters stripped, plain-text rendering, `title` ≤ 80 / `message` ≤ 280 chars, 20 events/s per-session rate limit.
- [ ] `open_url` is accepted only for allowlisted schemes (`https`, known editor/terminal schemes, bundle-ID activation); `file://`, paths and commands are rejected. First use of a new scheme asks the user to confirm.
- [ ] Public docs with schema, examples in `bash`, `python`, and `node`.

#### P0-4 Reference adapters
- [ ] **Claude Code adapter:** hook config snippet mapping session start/stop, permission requests, notifications, and turn completion to AgentBar events.
- [ ] **Generic CLI wrapper:** `agentbar run -- <command>` that emits `started`/`finished`/`error` (by exit code) for any command-line agent.
- [ ] Settings screen shows each adapter's setup steps with copy buttons.

#### P0-5 Attention popups (macOS notifications)
Native notifications for the four attention triggers, each individually toggleable.
- [ ] **Needs input/permission** → notification immediately (default **on**).
- [ ] **Finished** → notification (default **on**).
- [ ] **Error / stuck** → notification on `error` event, or when a running session has had **no events for N minutes** (default 10, configurable) → marked *stale*.
- [ ] **Cost/token threshold** → notification once per threshold crossing per day.
- [ ] Clicking a notification performs the same "open source" action as the dropdown row.
- [ ] Notifications from the same session are **coalesced** (no more than 1 per session per 30 s, except `needs_*`).
- [ ] Respects macOS Focus/DND; requests notification permission on first run with an explanation.

#### P0-6 Session lifecycle & staleness
- [ ] A session is created on its first event and is identified by `(agent, session_id)`.
- [ ] Sessions with no event for the stale timeout are shown as **Stale** (not "Running").
- [ ] Finished/stopped sessions remain visible for the rest of the day, then roll into history.

#### P0-7 Local storage & privacy
- [ ] All data stored locally (e.g. SQLite in `~/Library/Application Support/AgentBar`).
- [ ] No network calls except an optional, user-enabled update check.
- [ ] History retained 30 days by default; user can clear all data from Settings.

#### P0-8 Distribution: ad-hoc-signed `.dmg` (no Apple Developer account)
- [ ] Ships as a `.dmg` with drag-to-Applications layout, built by a single script (`xcodebuild` → `codesign --sign -` → `hdiutil create`).
- [ ] App is **ad-hoc signed** (`codesign --force --deep --sign -`). Apple Silicon refuses to run fully unsigned binaries, so ad-hoc signing is required even without an account.
- [ ] **Not notarized.** On first open macOS will show *"Apple could not verify AgentBar is free of malware"*. This is expected and must be handled:
  - The `.dmg` window has a visible **"First launch? Read me"** file / background graphic with the steps.
  - **macOS 13–14:** right-click (or Control-click) AgentBar in Applications → **Open** → **Open**.
  - **macOS 15+:** double-click once (it is blocked) → **System Settings → Privacy & Security** → **Open Anyway** → authenticate. (The right-click shortcut no longer works on 15+.)
  - Advanced alternative documented in the README: `xattr -dr com.apple.quarantine /Applications/AgentBar.app`.
- [ ] Publish a **SHA-256 checksum** next to each `.dmg` so users can verify the download, since there's no Apple notarization.
- [ ] **Universal binary** (Apple Silicon + Intel).
- [ ] Minimum OS: **macOS 13 Ventura** (D1).
- [ ] Verified on a clean macOS 13, 14 and 15 machine that, after the one-time approval, **notifications, launch at login (`SMAppService`) and the socket all work** with ad-hoc signing.
- [ ] **Launch at login** option (default on during onboarding), and app recovers correctly after sleep/wake.
- [ ] Runs as a menu-bar-only app (no Dock icon).

#### P0-9 Answer permission requests from AgentBar *(added 2026-11-16)*
When an agent asks for permission, AgentBar shows what it wants and lets the user Allow or Deny without switching windows.
- [ ] The request card shows: the agent's one-line summary, the **exact** command / file / URL (monospaced, full, selectable), the tool, the project, and the last 3 activities for context.
- [ ] **Allow** and **Deny** on the card in the panel and in a floating popup that doesn't steal keyboard focus; **Answer in terminal** hands it back to the agent's own prompt.
- [ ] Notification: **Allow / Deny** buttons only when the whole command fits in the banner (≤100 characters, one line); otherwise **Review… / Deny**. Allow from a notification requires an unlocked Mac.
- [ ] Nothing is ever approved without a click. If AgentBar isn't running, the user doesn't answer within the wait time (default 300 s), or AgentBar quits, the agent falls back to its normal prompt.
- [ ] Claude Code: implemented with the `PermissionRequest` hook (`agentbar hook claude`).

### P1 — Nice-to-have (fast follows)

| ID | Requirement | Acceptance criteria |
|---|---|---|
| P1-1 | **Update check** | App checks a release feed (e.g. GitHub Releases) and offers a link to the new `.dmg`; user can disable. Sparkle-style in-place updates are possible without an Apple account (Sparkle uses its own EdDSA keys), but each ad-hoc build has a new code identity, so macOS may re-ask for notification permission after updating — test before committing to silent updates. |
| P1-2 | **Snooze & per-agent mute** | Snooze all for 15m / 1h / until tomorrow; mute a specific agent or event type. |
| P1-3 | **Global hotkey** to open the panel | Configurable shortcut; panel opens with keyboard focus on the first "Needs you" item. |
| P1-4 | **Additional reference adapters** | Documented adapters for at least 2 more popular agents (e.g. Codex CLI, Gemini CLI) where hooks exist. |
| P1-5 | **Weekly summary view** | Per-day chart of sessions, wait time, and cost for the last 7 days. |
| P1-6 | **Sound & persistent banner options** | Per-event-type: banner vs. alert style, optional sound. |
| P1-7 | **Process-presence detection** | Optional: detect known agent processes so a session appears even before its first event; never inferred as "needs input". |

### P2 — Future considerations (design for, don't build)

- **Act from AgentBar:** approve/deny permissions or send a short reply, for adapters that expose a safe, two-way control channel. → *Keep the event schema bidirectional-ready (reserve a `reply_channel` field).*
- **Remote agents:** cloud/CI agents reporting through a relay. → *Keep ingestion behind an interface so a remote transport can be added.*
- **Cross-platform** (Windows tray / Linux). → *Keep core state engine separate from the macOS UI layer.*
- **Team view / sharing** of anonymized stats.
- **Rules engine:** "only notify me for agent X in project Y after 6pm."

## 7. Success Metrics

Because the app is local-first, metrics come from **opt-in, anonymous usage telemetry** (off by default) plus beta interviews.

### Leading indicators (first 2–4 weeks)
| Metric | Target | Stretch | How measured |
|---|---|---|---|
| Install → first event received | ≥ 70% of installs within 24h | 85% | Opt-in telemetry: first-event timestamp |
| Time from download to first event | median < 5 min | < 3 min | Telemetry + onboarding timer |
| Median response time to `needs_*` popup | < 60 s | < 30 s | Time between `needs_*` and next `working` event for that session |
| Popup action rate (clicked or dismissed vs. ignored) | ≥ 80% | 90% | Notification interaction callbacks |
| Notifications muted/disabled within first week | < 20% of users | < 10% | Settings change events |

### Lagging indicators (1–3 months)
| Metric | Target | How measured |
|---|---|---|
| Week-4 retention (app still running) | ≥ 50% | Opt-in daily heartbeat |
| Avg concurrent agents per active user | +1 vs. their week-1 baseline | Telemetry |
| Third-party adapters published by others | ≥ 5 in 3 months | GitHub / docs submissions |
| Self-reported "I miss fewer blocked agents" | ≥ 70% agree | In-app survey at day 30 |

Evaluate at **1 week**, **1 month**, and **3 months** post-launch.

## 8. UX Notes (non-binding)

- **Icon states:** outline (idle) → animated/filled (working) → accent color + number badge (needs you). Avoid red unless something errored.
- **Panel:** ~360 pt wide, native `MenuBarExtra` window style; "Needs you" section pinned on top with a one-line reason ("Permission: run `npm install`?").
- **Install (before the app runs):** `.dmg` background shows "Drag to Applications" plus "First launch: see READ ME" with the macOS 13–14 and 15+ approval steps and screenshots.
- **Onboarding (3 steps):** allow notifications → enable launch at login → connect first agent (pick adapter, copy snippet, "Send test event" button).

## 9. Open Questions

| # | Question | Owner | Blocking? |
|---|---|---|---|
| ~~1~~ | ~~Minimum macOS version~~ → **Resolved: macOS 13+ (D1)** | — | — |
| ~~2~~ | ~~Native vs. Electron/Tauri~~ → **Resolved: native Swift/SwiftUI (D2)** | — | — |
| ~~3~~ | ~~Socket permissions vs. token~~ → **Resolved: socket + peer-UID check, no HTTP, no token (D3)** | — | — |
| ~~4~~ | ~~Apple Developer account~~ → **Resolved: none; ad-hoc-signed `.dmg` (D4)** | — | — |
| 4a | Revisit notarization if the first-launch approval step causes significant beta drop-off (> 10% of installs never reach first event). | Stakeholder | No |
| 5 | Can "jump to session" reliably focus a specific terminal tab/IDE window, or only the app? (Per-terminal AppleScript support varies.) | Engineering | No |
| 6 | Which agents expose enough hooks for `needs_input` detection beyond Claude Code? | Engineering | No |
| 7 | Pricing model, if any (free / one-time / open source)? | Stakeholder | No |
| 8 | Should message text (which can include prompts/file paths) be stored, or only status + length-capped summaries? | Design / Privacy | No |
| 9 | Default stale timeout — 10 min may be too short for long builds. Make it per-agent? | Design | No |

## 10. Timeline & Phasing

No hard external deadlines identified. Suggested phasing:

| Phase | Scope | Rough size |
|---|---|---|
| **0 — Spike** (≈1 week) | Event schema + Unix socket with peer-UID check + menu bar icon reacting to `agentbar emit`. Build an ad-hoc-signed `.dmg` and confirm notifications + launch at login work on macOS 13, 14 and 15. | 1 engineer |
| **1 — MVP** (≈3–4 weeks) | All P0: panel, notifications, staleness, Claude Code + CLI-wrapper adapters, local storage, ad-hoc-signed `.dmg` with first-launch instructions. Private beta with 10–20 multi-agent users. | 1–2 engineers + design pass |
| **2 — Public v1** (≈2–3 weeks) | Beta fixes, P1-1 update check, P1-2 snooze/mute, docs site for adapters, opt-in telemetry. | |
| **3 — Fast follows** | P1-3 → P1-7 based on beta feedback. | |

**Dependencies:** Xcode 15+ on the build machine; agent hook APIs (Claude Code hooks for the reference adapter); notification permission UX on macOS. No Apple Developer account needed.
