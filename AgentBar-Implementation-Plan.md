# AgentBar — Implementation Plan

**Based on:** [AgentBar-PRD.md](AgentBar-PRD.md) v0.2
**Date:** 2026-11-16
**Scope:** P0 (MVP + private beta), with hooks left in place for P1/P2.
**Team assumption:** 1 engineer full-time, with occasional design help. Rough total: **6–7 weeks** to private beta.

---

## 1. Architecture Overview

```
 ┌──────────────────────────┐        ┌───────────────────────────────────────────────┐
 │  Agents                  │        │  AgentBar.app  (menu bar only, LSUIElement)    │
 │                          │        │                                               │
 │  Claude Code hooks ──┐   │        │  ┌─────────────┐   ┌──────────────────────┐   │
 │  agentbar run -- cmd ├──►│ agentbar CLI ─► Unix socket ─► SocketServer        │   │
 │  any script/tool  ───┘   │  (emit / hook / run)  │   │  (peer-UID check,    │   │
 │                          │        │  └─────────────┘   │   framing, limits)   │   │
 └──────────────────────────┘        │                    └─────────┬────────────┘   │
                                     │                              ▼                │
                                     │                    ┌──────────────────────┐   │
                                     │                    │ EventValidator +     │   │
                                     │                    │ Sanitizer + URL gate │   │
                                     │                    └─────────┬────────────┘   │
                                     │                              ▼                │
                                     │  ┌──────────┐   ┌──────────────────────┐      │
                                     │  │ SQLite   │◄──┤ SessionEngine (actor)│      │
                                     │  │ (GRDB)   │   │ state machine, stale │      │
                                     │  └──────────┘   │ timer, daily totals  │      │
                                     │                 └───┬──────────────┬───┘      │
                                     │                     ▼              ▼          │
                                     │         ┌──────────────────┐ ┌────────────┐   │
                                     │         │ AppState (@Main) │ │ Notifier   │   │
                                     │         │ → MenuBarExtra UI│ │ (UNUser…)  │   │
                                     │         └──────────────────┘ └────────────┘   │
                                     └───────────────────────────────────────────────┘
```

**Key principles**
- **Core logic in a UI-free Swift package (`AgentBarCore`)**, so it can be unit-tested headlessly and reused for a future Windows/Linux port (PRD P2).
- **One-way data flow:** socket → validate → engine → (store, UI, notifier). Nothing in the UI writes to the engine except user actions (mute, clear, open).
- **The engine is a Swift `actor`**; the UI observes a `@MainActor` snapshot that the engine publishes on each change.

## 2. Tech Stack

| Concern | Choice | Notes |
|---|---|---|
| Language / UI | Swift 5.9+, SwiftUI `MenuBarExtra(.window)` + AppKit where needed | macOS 13+ (D1, D2) |
| Project generation | **XcodeGen** (`project.yml`) | Reproducible project with no merge conflicts in `.pbxproj` |
| Persistence | **GRDB.swift** (SQLite) | Proven, lightweight, works on macOS 13 (SwiftData needs 14) |
| CLI parsing | **swift-argument-parser** | For the `agentbar` CLI |
| Socket | BSD sockets + `DispatchSource` | Needed for `getpeereid`; Network.framework doesn't expose peer credentials |
| Notifications | `UserNotifications` (`UNUserNotificationCenter`) | Categories + `userInfo` carries the session key |
| Launch at login | `ServiceManagement` `SMAppService.mainApp` | macOS 13+ API |
| Packaging | `xcodebuild` → `codesign --sign -` → `hdiutil` | Ad-hoc signed, not notarized (D4) |
| Tests | XCTest (core), a shell-driven socket integration test, manual VM matrix | |

## 3. Repository Layout

```
agentbar/
├── project.yml                     # XcodeGen spec
├── Packages/
│   └── AgentBarCore/               # Swift package, no AppKit/SwiftUI imports
│       ├── Sources/AgentBarCore/
│       │   ├── Schema/             # AgentEvent, EventKind, Usage (Codable, v1)
│       │   ├── Validation/         # EventValidator, Sanitizer, URLPolicy
│       │   ├── Engine/             # SessionEngine (actor), SessionState, DailyTotals
│       │   ├── Persistence/        # GRDB models + migrations
│       │   ├── Transport/          # SocketServer, SocketClient, LineFramer
│       │   └── Config/             # Paths, Settings model
│       └── Tests/AgentBarCoreTests/
├── App/                            # AgentBar.app target
│   ├── AgentBarApp.swift           # @main, MenuBarExtra
│   ├── AppState.swift              # @MainActor ObservableObject bridge to engine
│   ├── UI/                         # StatusIcon, PanelView, SessionRow, SummaryHeader,
│   │                               # EmptyState, SettingsView, OnboardingView
│   ├── Notifications/Notifier.swift
│   ├── Actions/OpenAction.swift    # open_url / bundle activation via URLPolicy
│   ├── System/LoginItem.swift, CLIInstaller.swift
│   └── Resources/Info.plist, Assets.xcassets
├── CLI/                            # `agentbar` command-line tool target
│   ├── main.swift
│   ├── EmitCommand.swift
│   ├── RunCommand.swift
│   └── HookCommand.swift           # `agentbar hook claude` (reads hook JSON on stdin)
├── adapters/
│   ├── claude-code/settings.snippet.json
│   └── examples/emit.sh, emit.py, emit.mjs
├── scripts/
│   ├── build-dmg.sh
│   └── dmg/ (background.png, "First launch - READ ME.rtf")
└── docs/
    ├── event-schema.md
    └── adapters.md
```

The CLI binary ships **inside the app bundle** at `AgentBar.app/Contents/MacOS/agentbar`. Settings → "Install command-line tool" symlinks it into `~/.local/bin` (default, no admin prompt) or `/usr/local/bin` (with admin consent).

## 4. Key Design Details

### 4.1 Event schema v1 (`AgentBarCore/Schema`)

```json
{
  "v": 1,
  "agent": "claude-code",
  "session_id": "8f3c…",
  "event": "needs_permission",
  "timestamp": "2026-11-16T14:03:22Z",
  "title": "agentbar repo",
  "message": "Permission: run `npm install`?",
  "cwd": "/Users/me/code/agentbar",
  "open_url": "vscode://file/Users/me/code/agentbar",
  "activate_bundle_id": "com.googlecode.iterm2",
  "usage": { "input_tokens": 1200, "output_tokens": 340, "cost_usd": 0.021 },
  "reply_channel": null
}
```

- `event` ∈ `started | working | needs_input | needs_permission | finished | error | heartbeat | stopped`.
- `timestamp` is optional (server time is used if it's missing or more than 5 minutes off).
- `usage` is **incremental** (a delta since the last report), so the engine just sums it.
- `reply_channel` is reserved for the P2 "act from AgentBar" feature and ignored in v1.
- Unknown fields are ignored, which keeps the schema forward-compatible.

### 4.2 Transport

- **Path:** `~/Library/Application Support/AgentBar/agentbar.sock`. On launch: create the directory with `0700`, `unlink` any stale socket, `bind`, `chmod 0600`, `listen`.
- **Peer check:** call `getpeereid(fd)` right after `accept`; if the UID isn't `getuid()`, close the connection and log it.
- **Framing:** newline-delimited JSON, one event per line. The server replies one line per event: `{"ok":true}` or `{"ok":false,"error":"…"}`.
- **Limits:** 16 KB per line (longer lines → error, then drop the connection); max 64 concurrent connections; 5 s read timeout; 20 events/s per session (token bucket), with extra events dropped and counted.
- **CLI behavior if the app isn't running:** exit code 0 with a stderr warning by default, so agent hooks never fail just because AgentBar is closed. `--strict` turns that into exit code 2.

### 4.3 Validation & sanitizing

- `Sanitizer`: removes C0/C1 control characters and bidi overrides (U+202A–202E, U+2066–2069), collapses whitespace, and truncates `title` to 80 and `message` to 280 characters (whole grapheme clusters).
- `URLPolicy`: allows `https`, plus an allowlist (`vscode`, `vscode-insiders`, `cursor`, `windsurf`, `zed`, `jetbrains`, `iterm2`, `warp`, `x-github-client`). Rejects `file`, `javascript`, `data`, and anything else. The first time a new allowlisted scheme is used, the app asks the user to confirm, and remembers the answer in Settings.
- `activate_bundle_id` must match a reverse-DNS pattern and an installed app (`NSWorkspace.urlForApplication(withBundleIdentifier:)`).
- Text is always rendered with `Text(verbatim:)`, never markdown.

### 4.4 Session engine (state machine)

```
            started/working/heartbeat
   (new) ─────────────────────────────► RUNNING ◄───────────────┐
                                          │  │                   │ working/heartbeat
                         needs_input /    │  │ finished           │
                         needs_permission ▼  ▼                    │
                                       WAITING   FINISHED ────────┤ (a new turn reopens it)
                                          │                       │
                       error ─────────► ERRORED                    │
           no event for staleTimeout ──► STALE ────────────────────┘
                                 stopped ─► STOPPED (terminal)
```

- Key: `(agent, session_id)`.
- Tracks `stateEnteredAt` and `totalWaitingOnUser` (accumulated time spent in WAITING), which feeds the "time agents waited on you" summary.
- A **stale sweeper** runs every 30 s. The default timeout is 10 min, overridable per agent in Settings.
- **Daily rollover** at local midnight: finished/stopped sessions move to history, and daily totals reset.
- Emits `EngineChange` values (`.stateChanged(old,new)`, `.usageUpdated`, `.thresholdCrossed`) for the UI and the Notifier.

### 4.5 Notifier

| Trigger | Condition | Default | Coalescing |
|---|---|---|---|
| Needs you | → `WAITING` | On | None — always delivered |
| Finished | → `FINISHED` | On | Max 1 per session per 30 s |
| Error / stuck | → `ERRORED` or `STALE` | On | Max 1 per session per 30 s |
| Cost / tokens | Daily total crosses a threshold | On if a threshold is set | Once per threshold per day |

- `UNNotificationRequest.identifier = "\(agent)/\(session)/\(kind)"`, so a newer notification replaces an older one of the same kind.
- `userInfo` carries the session key. Clicking a notification runs `OpenAction` for that session.
- Focus/DND is respected by macOS automatically; use `interruptionLevel = .timeSensitive` only for *Needs you*, and only if the user opts in.

### 4.6 Claude Code adapter (`agentbar hook claude`)

The CLI reads the hook JSON from stdin and maps it to an event. This means users paste one snippet, and changes to the mapping ship with app updates rather than requiring users to edit their config.

| Claude Code hook | AgentBar event |
|---|---|
| `SessionStart` | `started` (title = folder name of `cwd`) |
| `UserPromptSubmit` | `working` |
| `PreToolUse` / `PostToolUse` | `heartbeat` (keeps stale detection accurate) |
| `Notification` | `needs_permission` if the message mentions permission, else `needs_input` |
| `Stop` | `finished` |
| `SessionEnd` | `stopped` |

- `usage`: best effort, by reading new lines from the hook's `transcript_path` and summing token usage since the last report. Cost is computed from a local price table, flagged as an estimate in the UI.
- The snippet lives in `adapters/claude-code/settings.snippet.json`; Settings has a "Copy snippet" button. **Verify hook names and payload fields against current Claude Code docs during M4**, since they may have changed.

### 4.7 Generic wrapper (`agentbar run -- <cmd>`)

Sends `started`, then runs the command with inherited stdio and forwards signals, sends a `heartbeat` every 60 s while it's alive, and finally sends `finished` (exit 0) or `error` (non-zero, with "exit N" as the message). It exits with the child's exit code. `--agent`, `--title` and `--session` flags are optional; the default session ID is a UUID.

## 5. Milestones & Tasks

Estimates are in engineer-days (d).

### M0 — Spike & de-risk (week 1) · ~5d
| # | Task | Est |
|---|---|---|
| 0.1 | Repo, `project.yml`, the three targets (App, CLI, Core package), CI that builds and runs `swift test` | 1d |
| 0.2 | Minimal `SocketServer` with `getpeereid` + `agentbar emit` → the menu bar icon changes color | 1.5d |
| 0.3 | Minimal `build-dmg.sh` (universal binary, ad-hoc signed, CLI embedded) | 1d |
| 0.4 | **Risk test** on clean macOS 13, 14, 15 VMs (UTM): Gatekeeper approval steps, notification permission + delivery, `SMAppService` login item, notification permission after installing a rebuilt `.dmg` | 1.5d |

**Exit criteria:** an event sent from the terminal changes the icon on all three OS versions; the four risk items are documented, with workarounds if needed. **Go/no-go point for D4 (no Apple Developer account).**

### M1 — Core engine (week 2) · ~5d
| # | Task | Est |
|---|---|---|
| 1.1 | Schema v1 types + JSON decoding + `docs/event-schema.md` | 0.5d |
| 1.2 | `Sanitizer`, `URLPolicy`, `EventValidator` + unit tests (aim for 100% branch coverage here) | 1d |
| 1.3 | Production `SocketServer`: framing, limits, rate limiter, timeouts, error replies | 1d |
| 1.4 | `SessionEngine` state machine, stale sweeper, daily totals, rollover + tests (inject a clock) | 1.5d |
| 1.5 | GRDB schema (`sessions`, `events`, `daily_totals`, `settings`), migrations, 30-day pruning, "Clear all data" | 1d |

**Exit criteria:** `swift test` covers every state transition and every validation rule; a load test of 1,000 events/s across 50 sessions shows no crash and correct counts.

### M2 — Menu bar UI (week 3) · ~5d
| # | Task | Est |
|---|---|---|
| 2.1 | `AppState` bridge (engine → `@Published` snapshot, at most 10 updates/s) | 0.5d |
| 2.2 | Status icon: idle / working / needs-attention template images, badge count, accessibility labels | 1d |
| 2.3 | Panel: summary header, grouped sections (Needs you → Running → Finished → Errored/Stale), `SessionRow`, collapsed Finished list after 5 items | 2d |
| 2.4 | `OpenAction`: open URL / activate app / fall back to copying the session ID and showing `cwd`; new-scheme confirmation prompt | 0.5d |
| 2.5 | Empty state linking to adapter setup | 0.5d |
| 2.6 | Light/dark/high-contrast pass, VoiceOver labels | 0.5d |

**Exit criteria:** the PRD P0-1 and P0-2 acceptance criteria pass; the icon reflects events within 1 s.

### M3 — Notifications & Settings (week 4) · ~4.5d
| # | Task | Est |
|---|---|---|
| 3.1 | `Notifier`: permission request with explanation, four triggers, coalescing, replacement identifiers, click handling | 1.5d |
| 3.2 | Cost/token thresholds (daily, per user) + crossing detection | 0.5d |
| 3.3 | Settings window: per-trigger toggles, stale timeout (global + per agent), thresholds, URL schemes, launch at login, data retention, "Clear all data" | 1.5d |
| 3.4 | `LoginItem` via `SMAppService`; sleep/wake handling (re-run the stale sweep on wake, re-create the socket if needed) | 1d |

**Exit criteria:** PRD P0-5 and P0-6 pass, including after sleep/wake and a forced quit.

### M4 — CLI & adapters (week 5) · ~4.5d
| # | Task | Est |
|---|---|---|
| 4.1 | `agentbar emit` (flags + `--json` stdin), `--strict`, helpful error messages | 0.5d |
| 4.2 | `agentbar run -- cmd` (signal forwarding, heartbeat, exit code passthrough) | 1d |
| 4.3 | `agentbar hook claude` + transcript usage parser + price table; check against current Claude Code hooks docs | 1.5d |
| 4.4 | `CLIInstaller` (symlink into `~/.local/bin`, PATH check + guidance) | 0.5d |
| 4.5 | Example emitters (bash/python/node) + `docs/adapters.md` | 0.5d |
| 4.6 | Onboarding: notifications → login item → pick adapter → copy snippet → "Send test event" | 0.5d |

**Exit criteria:** following only the docs, a fresh user connects Claude Code in ≤ 15 min (PRD Goal 3), tested with 2–3 people.

### M5 — Packaging & release (week 6) · ~3d
| # | Task | Est |
|---|---|---|
| 5.1 | Final `build-dmg.sh` (see §6), version stamping from git tag | 1d |
| 5.2 | `.dmg` design: background with "Drag to Applications" + **"First launch – READ ME"** with macOS 13–14 and 15+ steps and screenshots | 1d |
| 5.3 | GitHub Release workflow: upload `.dmg` + `SHA256SUMS.txt`; README install section | 0.5d |
| 5.4 | Clean-VM install test matrix (§7.3) | 0.5d |

### M6 — Private beta (weeks 6–7) · ongoing
- 10–20 multi-agent users; opt-in anonymous telemetry (off by default) for the PRD's leading metrics.
- Track: install → first event, first-launch approval drop-off (**> 10% triggers revisiting notarization, PRD Q4a**), popup action rate, and how often notifications get muted.
- Bug-fix buffer: 3–5d.

## 6. Build & Packaging Script (sketch)

```bash
#!/usr/bin/env bash
set -euo pipefail
VERSION="${1:?usage: build-dmg.sh <version>}"
BUILD=build; APP="$BUILD/Release/AgentBar.app"; DMG="dist/AgentBar-$VERSION.dmg"

xcodegen generate
xcodebuild -project AgentBar.xcodeproj -scheme AgentBar -configuration Release \
  -derivedDataPath "$BUILD/dd" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build
cp -R "$BUILD/dd/Build/Products/Release/AgentBar.app" "$APP"

# Ad-hoc sign inside-out (the CLI first, then the app); avoid --deep
codesign --force --sign - --options runtime "$APP/Contents/MacOS/agentbar"
codesign --force --sign - --options runtime "$APP"
codesign --verify --strict --verbose=2 "$APP"
lipo -info "$APP/Contents/MacOS/AgentBar"   # must list x86_64 arm64

STAGE=$(mktemp -d); cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
cp "scripts/dmg/First launch - READ ME.rtf" "$STAGE/"
mkdir -p dist
hdiutil create -volname "AgentBar $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
(cd dist && shasum -a 256 "$(basename "$DMG")" > "SHA256SUMS.txt")
```

(Use `create-dmg` or a `.DS_Store` template for the background image and icon positions.)

## 7. Testing Strategy

### 7.1 Unit (AgentBarCore, runs in CI)
- Schema decoding: valid, missing required fields, unknown fields, wrong types, `v` mismatch.
- Sanitizer: control and bidi characters, emoji/grapheme truncation, whitespace.
- URLPolicy: each allowed scheme, `file://`, `javascript:`, uppercase or mixed-case schemes, URLs with credentials.
- Engine: every state transition, stale timeout with an injected clock, midnight rollover, waiting-time accounting, usage summing, threshold crossed exactly once.
- Rate limiter and framer edge cases (partial lines, 16 KB + 1 byte).

### 7.2 Integration (CI, macOS runner)
- Start the server on a temp socket path → `agentbar emit` round trip → correct state.
- Socket file mode is `0600` and the directory is `0700`.
- `agentbar run -- false` → `error` with exit code 1; `agentbar run -- sleep 2` → `finished`.
- A Claude Code hook fixture JSON for each hook type → expected event.
- App not running → `emit` exits 0 with a warning; `--strict` exits 2.

### 7.3 Manual clean-machine matrix (each beta build)
| | macOS 13 Intel / VM | macOS 14 Apple Silicon | macOS 15 Apple Silicon |
|---|---|---|---|
| First-launch Gatekeeper approval following the READ ME | ✓ | ✓ | ✓ (Open Anyway flow) |
| Notification permission + delivery + click → open | ✓ | ✓ | ✓ |
| Launch at login after reboot | ✓ | ✓ | ✓ |
| Upgrade to a new `.dmg`: permissions kept? | ✓ | ✓ | ✓ |
| Sleep/wake, Focus mode | ✓ | ✓ | ✓ |

### 7.4 Security checks
- From a second macOS user account: connecting to the socket fails (permissions) and the attempt is logged.
- Confirm no listening TCP ports: `lsof -iTCP -sTCP:LISTEN -a -p $(pgrep AgentBar)` returns nothing.
- Fuzz the socket with random bytes and oversized lines: no crash, connection dropped.
- Hostile `open_url` values (`file:///Applications/Calculator.app`, `javascript:`, a `vscode://` URL with embedded commands) → rejected or confirmation prompt shown.

## 8. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Ad-hoc builds lose notification or login-item permission on each update | Medium | High | Test in M0.4. If confirmed: keep the bundle ID stable, explain in release notes, and add an in-app "re-enable notifications" check; re-evaluate the Apple Developer account. |
| macOS 15+ "Open Anyway" flow confuses users | High | Medium | Illustrated READ ME in the `.dmg`; measure drop-off in beta; notarization is the fallback (PRD Q4a). |
| Claude Code hook names or payloads change | Medium | Medium | Keep the mapping inside `agentbar hook claude`, not in the user's config; use fixture tests; pin the docs version. |
| Token usage isn't available from many agents | High | Low | Cost alerts only apply to agents that report usage; the UI shows "—" otherwise. |
| "Jump to session" can't focus a specific terminal tab | High | Low | v1 activates the app plus copies the session/cwd; per-terminal deep links in P1. |
| Notification fatigue | Medium | High | Coalescing, per-trigger toggles, snooze (P1-2); watch the mute rate in beta. |

## 9. Definition of Done (MVP / private beta)

- [ ] Every PRD P0 acceptance criterion is checked off.
- [ ] CI is green: unit + integration tests.
- [ ] The §7.3 manual matrix passes on macOS 13, 14 and 15.
- [ ] The §7.4 security checks pass.
- [ ] `.dmg` + `SHA256SUMS.txt` are published on a GitHub Release, with the README install steps.
- [ ] Claude Code adapter and `agentbar run` documented and tested by at least 2 people outside the team.

---

## 10. M0 Spike — Results (2026-11-16)

**Built:** `agentbar/` — Core package (schema, validation, state machine, Unix socket server and client), SwiftUI menu bar app with notifications + launch-at-login diagnostics, `agentbar emit` CLI, self-test runner, and `scripts/build-dmg.sh` producing a 779 KB universal, ad-hoc-signed `.dmg` with a SHA-256 checksum.

**Verified on the build Mac (macOS 26.6, Apple Silicon):**
- [x] Release self-test: 43/43 checks, including 200 concurrent clients, an oversized event, a second instance, and the packaged CLI end-to-end.
- [x] Socket `srw-------`, folder `drwx------`, **no TCP listener** (`lsof`).
- [x] Universal binary (`x86_64 arm64`), `minos 13.0`, `codesign --verify --strict` passes.
- [x] `spctl` says **rejected**, as expected for an app Apple hasn't notarized: downloaded copies will need the one-time approval.
- [ ] Menu bar icon states: not checked automatically (no screen capture permission). **Check by hand.**
- [ ] Notifications + launch at login with ad-hoc signing: **needs a hand test** using the panel's diagnostics buttons.
- [ ] Clean macOS 13 / 14 / 15 machines (task 0.4): **not done.** Needs VMs or spare Macs.

**Changes to the plan from what we learned:**
1. **No Xcode needed.** Building uses SwiftPM + `build-dmg.sh` (Command Line Tools only) instead of XcodeGen/`xcodebuild`.
2. **The CLI lives in `Contents/Helpers/agentbar`**, not `Contents/MacOS/agentbar`: on the default case-insensitive disk, `agentbar` and `AgentBar` would be the same file.
3. **Tests run as an executable** (`agentbar-selftest`), because XCTest/Swift Testing aren't usable with Command Line Tools alone. Move them to Swift Testing if Xcode is ever adopted.
4. **Always test the release build.** Two bugs showed up only with `-c release`:
   - the CLI silently sent nothing (an outer `var` assigned inside `do/catch` came out empty under `-O`); fixed by returning the lines from a function, plus a check that the reply count matches the number of events sent;
   - the client lost the server's error reply when the server closed mid-write (EPIPE); fixed by reading the reply after a failed write.

   `build-dmg.sh` now runs the release self-test against the packaged CLI before making the `.dmg`.

## 11. M1 Core Engine — Results (2026-11-16)

**Built:**
- Schema v1 with `timestamp`, `cwd`, `open_url`, `activate_bundle_id` and `usage`; documented in `agentbar/docs/event-schema.md`.
- `URLPolicy`, `BundleIDPolicy`, and a per-session token-bucket `RateLimiter` (20/s, burst 40).
- Invalid optional fields are **dropped with a warning** in the reply instead of rejecting the whole event, so a slightly-off adapter still shows up.
- Engine: a `stale` state (per-agent timeout; waiting sessions never go stale), daily totals (sessions, finished, live waiting-on-you time, tokens, cost), cost and token limits that alert once per day, midnight rollover, and restore after restart.
- Persistence: **system SQLite directly, not GRDB** (no third-party dependency). Batched background writes every 0.5 s, versioned schema, 30-day retention, clear all, `0600` files. The event log stores only kind + time.
- App: today's totals in the header, a "may be stuck" state with an alert, cost/token alerts, storage error display, and a flush on any quit path.

**Verified:**
- [x] Release self-test **146/146** (138 core + 8 CLI end-to-end).
- [x] **Load test: 1,000 events across 50 sessions through socket → engine → SQLite in 25 ms in the release build (about 40k events/s; target 1k/s)**, all persisted, totals exact.
- [x] Live app: events → quit → relaunch restores sessions and totals; `file://` link dropped with a warning; a quit right after an event still saves it; the socket is removed on quit.

**Not done yet / carried forward:**
- Settings UI for the stale timeout and cost/token limits (M3). The engine supports them, but the app uses defaults (10 min, no limits).
- Waiting time that crosses midnight is counted entirely on the day the wait ended (simplification).
- Still unchecked by hand from M0: menu bar icon, notifications, launch at login; clean macOS 13/14/15 machines.

## 12. Permission decisions + activity summary (2026-11-16, user request)

**Why:** The user asked to Allow / Deny permission requests from AgentBar and to see a summary of what the agent wants. This moves the PRD's P2 "act from AgentBar" into scope as **P0-9**, for permission decisions only.

**How it works:**
- `needs_permission` events can carry `request {id, tool, summary, detail}` and `await_seconds`. The agent's connection stays open. AgentBar replies `allow` / `deny` when the user clicks, or `defer` on timeout, on **Answer in terminal**, or when AgentBar quits. If the agent disconnects, its card is withdrawn.
- `agentbar hook claude` (pulled forward from M4) maps the Claude Code hooks to events and records recent activity (`Edited X`, `Ran Y`). For `PermissionRequest` it waits and prints Claude Code's decision JSON; it prints nothing on `defer`, so Claude asks in the terminal as usual.
- UI: a request card (summary, exact command, tool and project, last 3 activities, Allow / Deny / Answer in terminal) in the panel and in a floating popup that doesn't steal focus. Notification actions: Allow / Deny for short commands only, otherwise Review… / Deny; Allow requires an unlocked Mac.
- Database migration v2 adds `recent_activity`. Pending requests are never persisted.

**Verified:** release self-test **194/194**. This covers the Allow/Deny round trip past the 5 s idle timeout, expiry → defer, agent disconnect → card withdrawn, quit → defer, migration from a v1 database, and the Claude hook end-to-end (allow / deny / defer / AgentBar not running).

**Not yet verified:**
- A real Claude Code session with the hooks installed.
- Whether Claude Code shows its terminal prompt while the hook is still waiting, or only after it returns. If only after, consider a shorter default `--wait`.

## 13. M2 (Menu bar UI) + M3 (Notifications & Settings): Results (2026-11-16, v0.2.0)

**M2:** done during the "Standby, Go" redesign (see `agentbar/DESIGN.md`), plus:
- Updates are batched: the panel redraws at most 10 times a second.
- Each cue row expands to show its tasks (last 20) and details, with Dismiss.
- "Done today" shows 5 and folds the rest behind "Show all".
- Links that open another app ask once per scheme ("Open" / "Always open").
- Sessions that need you but stay silent are retired after 1 hour (configurable).

**M3:**
- **Settings window** (⌘, from the panel's gear menu):
  - one toggle per alert type (permission, questions, finished, errors/stuck, daily limits) and a popup on/off toggle;
  - "may be stuck" timer (5–60 min) and "stop showing silent agents" timer (30 min–8 h);
  - daily spending and token limits;
  - open at login; history length (7/30/90 days, pruned immediately); clear history; trusted link schemes;
  - Claude Code connection status, with "Copy setup".
- **Alert grouping:** at most one alert per agent and kind every 30 s. Permission alerts are never grouped.
- **Sleep/wake:** on wake, AgentBar re-checks for stuck and silent agents and recreates the socket if it's gone.
- **Verified:** release self-test **208/208**; Settings rendered in light and dark.
- **Not verified:** alerts and sleep/wake on a real Mac session (needs a hand test); the per-agent stuck timeout exists in the engine but has no UI yet.

**Next: M4 (CLI & adapters).** Remaining: `agentbar run -- <cmd>`, `agentbar status`, a CLI installer into `~/.local/bin`, example emitters (bash/python/node), and a first-run onboarding flow.

## 14. M4 CLI & adapters: Results (2026-11-16, v0.3.0)

**Built:**
- `agentbar run [--agent] [--title] -- COMMAND`:
  - reports started → done or error, with the exit code and duration;
  - passes the command's input and output and its exit code through unchanged (127 if not found), and forwards TERM/HUP/QUIT;
  - sends a heartbeat every 60 s, and still runs when AgentBar is closed.
- `agentbar status [--json]`: a new `{"query":"status"}` socket query. Permission requests are listed first, and large replies are handled when the socket buffer is full.
- **Claude Code one-click Connect / Disconnect** (`ClaudeSetup`):
  - adds or removes only AgentBar's hooks, keeping your other hooks and settings;
  - backs up the file (`settings.json.agentbar-backup`) before every write, and refuses to touch an unreadable file;
  - replaces its own hooks on re-connect instead of duplicating them, and handles app paths with spaces.
- **CLI installer:** `~/.local/bin/agentbar` symlink to the bundled command, without needing an admin password; an existing file that isn't AgentBar's is left alone.
- **First-run setup guide** (alerts → open at login → connect agents → sample request), shown once and available from the gear menu.
- Example emitters (`adapters/examples/emit.sh|py|mjs`; the Python one includes the Allow/Deny wait) and `docs/adapters.md`.

**Found and fixed during testing:** hook detection missed quoted paths. Apps installed under a path with spaces would have been shown as "Not connected", and Disconnect would have left their hooks behind.

**Verified:** release self-test **240/240** (Claude settings transforms and file round trip, status query including a 20 KB reply, `run` exit codes / missing command / AgentBar closed, `status` output). Live `agentbar status` against the installed app lists this session.

**Not verified:** the setup guide and Connect button clicked by hand; the TERM forwarding in `run` (only exit codes are tested).

**Next: M5 (packaging & release)**: `.dmg` window design with a background, release notes, GitHub Releases workflow, and the clean macOS 13/14/15 install matrix (still open from M0).

## 15. M5 Packaging & release: Results (2026-11-16, v1.0.0)
- App icon (cue lamps) and .dmg background drawn by code (`scripts/render-art.swift`); designed .dmg window via dmgbuild in `.build-tools/` (plain .dmg fallback).
- Single version source (`VERSION`); the CLI reads its version from the app bundle.
- `CHANGELOG.md`, README install section, first-launch READ ME updated for the setup guide, `.github/workflows/release.yml` (tag → build → GitHub Release), `docs/release-checklist.md`.
- Verified: release self-test 240/240; `hdiutil verify`; Gatekeeper rejects a quarantined copy, as expected (approval documented).
- Not done: the clean macOS 13/14/15 matrix (no VMs here, so it's a checklist); the release workflow is untested (the project is not a git repository yet).
