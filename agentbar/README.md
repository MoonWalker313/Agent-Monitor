# AgentBar

A macOS menu bar app that shows what your AI agents are doing, and lets you answer them (Allow / Deny) when they need you.

## Install
1. Download `AgentBar-<version>.dmg` (and check it against `SHA256SUMS.txt`).
2. Open it and drag AgentBar to Applications.
3. Approve it once on first launch. It isn't notarized by Apple; the READ ME in the `.dmg` shows how for macOS 13–14 and 15+.
4. The setup guide connects Claude Code and installs the `agentbar` command. Other agents: see [docs/adapters.md](docs/adapters.md).

Requires macOS 13 or later (Apple silicon or Intel). What's new: [CHANGELOG.md](CHANGELOG.md).

## Requirements
- macOS 13+ to run. To build: Xcode **Command Line Tools** only (`xcode-select --install`). No Xcode, no Apple Developer account.

## Build
```bash
swift build                          # debug build of everything
swift run agentbar-selftest          # core tests; set AGENTBAR_CLI=<path to agentbar> for CLI end-to-end
python3 -m venv .build-tools && .build-tools/bin/pip install dmgbuild==1.6.2   # once, for the designed .dmg window
scripts/build-dmg.sh                 # version from VERSION → dist/AgentBar.app, AgentBar-<v>.dmg, SHA256SUMS.txt
```
`build-dmg.sh` builds arm64 + x86_64, merges them with `lipo`, ad-hoc signs (helper first, then app), runs the
**release** self-test against the packaged CLI, then creates the `.dmg`.

## Try it
```bash
open dist/AgentBar.app
CLI=dist/AgentBar.app/Contents/Helpers/agentbar
$CLI emit --agent claude-code --session s1 --event working --title "my repo" --message "Editing files"
$CLI emit --agent claude-code --session s1 --event needs_permission --message "Run npm install?" --verbose
echo '{"agent":"script","session_id":"job","event":"finished"}' | $CLI emit --json
```
Event kinds: `started, working, heartbeat, needs_input, needs_permission, finished, error, stopped`.

## Layout
| Path | What |
|---|---|
| `Sources/AgentBarCore` | UI-free core: event schema + validation (`AgentEvent`, `Policies`), state machine with stale/totals/thresholds (`SessionEngine`), SQLite store (`SessionDatabase`, `EngineStore`), Unix socket (`Socket`) |
| `docs/event-schema.md` | Event schema v1 for adapter authors |
| `Sources/AgentBarApp` | SwiftUI `MenuBarExtra` app, notifications, launch-at-login |
| `Sources/AgentBarCLI` | `agentbar` CLI (`emit`), shipped at `AgentBar.app/Contents/Helpers/agentbar` |
| `Sources/AgentBarSelfTest` | Test runner (XCTest / Swift Testing need full Xcode) |
| `scripts/` | `build-dmg.sh`, Info.plist template, `.dmg` READ ME |

## Security model (as built)
- Unix domain socket at `~/Library/Application Support/AgentBar/agentbar.sock` — directory `0700`, socket `0600`.
- Peer UID verified with `getpeereid` on every connection; other users are refused.
- **No TCP listener** (verify: `lsof -nP -iTCP -sTCP:LISTEN -a -p $(pgrep -f AgentBar.app/Contents/MacOS/AgentBar)` prints nothing).
- Every event is validated: 16 KB line cap, control/bidi characters stripped, title ≤ 80 / message ≤ 280 chars,
  always rendered as plain text. A second instance refuses to take over a live socket.

## Data
`~/Library/Application Support/AgentBar/agentbar.sqlite` (0600, WAL). Sessions, today's totals, and an event log
(kind + time only). 30-day retention; **Clear** in the panel deletes everything. Override paths with
`AGENTBAR_HOME`, `AGENTBAR_SOCKET`, `AGENTBAR_DB`.
