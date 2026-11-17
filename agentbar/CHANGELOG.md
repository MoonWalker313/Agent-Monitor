# Changelog

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
