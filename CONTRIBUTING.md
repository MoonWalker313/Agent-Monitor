# Contributing

Thanks for helping. AgentBar is a small native macOS app; changes should keep it **native, calm and safe**.

## Setup

```bash
git clone https://github.com/ololadetobi/Agent-Monitor.git
cd Agent-Monitor/agentbar
swift build
swift run agentbar-selftest
```

Xcode 15+ or the Command Line Tools are enough. To try the app, build the `.dmg` (`scripts/build-dmg.sh`) and open `dist/AgentBar.app`.

## Before opening a pull request

- **Tests pass:** `swift run agentbar-selftest`. Add checks for new behaviour; for anything touching the socket, permission requests or file writes, add a regression test.
- **Release build passes:** `scripts/build-dmg.sh` runs the tests against the optimized build and the packaged CLI. Some bugs only appear there.
- **UI changes:** follow [agentbar/DESIGN.md](agentbar/DESIGN.md) (native controls, the cue-lamp states, colour never the only signal), and check light and dark. `AgentBar --snapshot <folder>` renders the panel, popup, settings and setup guide with sample data, without touching your real AgentBar data.
- **Agent-provided text** is untrusted: render it with `Text(verbatim:)`, never as Markdown, and validate new event fields in `EventCodec`.
- **Copy:** plain language, controls named by their action, no em dashes.
- **Docs:** update `agentbar/docs/event-schema.md` for protocol changes and `agentbar/CHANGELOG.md` for user-visible ones.

## Security issues

Please report them privately; see [SECURITY.md](SECURITY.md).
