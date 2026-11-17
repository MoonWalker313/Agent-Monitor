# Changelog

## 1.0.1 (2026-11-17)

Security fixes from a review of 1.0.0. Upgrading is recommended.

- A permission card can no longer be changed after it appears, and only the agent that asked can receive your answer. Before, another process on your Mac could make a request show different text from what the waiting agent had asked for.
- **Allow** ignores clicks for a moment after a request appears, so a popup can't slide under your pointer mid-click.
- Connecting or disconnecting Claude Code now keeps `settings.json`'s file permissions (it can contain API keys), follows dotfile symlinks instead of replacing them, and keeps its backup private.
- A permission request sent without waiting for an answer now shows as a plain message instead of an Allow/Deny card that couldn't reach the agent.

## 1.0.0 (2026-11-16)

First release.

**See every agent from the menu bar**
- A lamp in the menu bar shows whether anything needs you, with a count.
- The panel lists agents by what they need: permission requests first, then Needs you, Running and Done today.
- Click an agent to see its tasks (the last 20, newest first) and details; dismiss anything that no longer needs you.
- Agents that go quiet are marked "may be stuck"; ones that need you but stay silent for an hour are retired automatically.
- Today's totals: sessions, done, time agents waited on you, tokens and cost (when reported).

**Answer permission requests without switching windows**
- Each request shows what the agent wants in plain words, the exact command, and what it did just before.
- Allow, Deny or Answer in terminal, from the panel, a floating popup, or the notification (Allow in a notification only when the whole command fits, and only with your Mac unlocked).
- Nothing is approved without a click. If you don't answer, the agent asks in its own window as usual.

**Connect agents**
- Claude Code: one-click Connect / Disconnect (your other settings are kept; a backup is saved).
- Any command: `agentbar run -- <command>`. Check from Terminal with `agentbar status`.
- Your own agents: a documented local socket protocol, with bash, Python and Node examples.

**Settings**
- Alerts per type, popup on/off, stuck and silence timers, daily spending and token limits, history length, open at login.

**Private and local**
- No network listener: agents connect through a socket only your user account can open. Everything stays on your Mac; history is kept 30 days by default.

Requires macOS 13 or later, on Apple silicon or Intel. Not notarized: approve it once on first launch (see the READ ME in the .dmg).
