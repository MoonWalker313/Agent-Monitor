# Connecting agents to AgentBar

Three ways, from easiest to most flexible.

## 1. Claude Code: one click
**AgentBar ⚙︎ → Settings → Agents → Connect** (or the setup guide on first launch).
This adds AgentBar's hooks to `~/.claude/settings.json`, keeps your other settings, and saves the previous file as `settings.json.agentbar-backup`. **Disconnect** removes only AgentBar's hooks. Restart open Claude Code sessions afterwards.

You get every session, its tasks (edits, commands, prompts), and permission requests with **Allow / Deny** in AgentBar. If you don't answer within 5 minutes, or click *Answer in terminal*, Claude asks in the terminal as usual. Details: [`adapters/claude-code/README.md`](../adapters/claude-code/README.md).

## 1b. Cursor, Gemini CLI and Antigravity: one click
**Settings → Agents → Connect** next to each. What each can do depends on what the tool lets outside programs see:

| | Sessions and tasks | Knows it's waiting for you | Allow / Deny in AgentBar | Settings file |
|---|---|---|---|---|
| Cursor | ✅ edits, commands, finished | — | ✅ terminal commands (opt-in) | `~/.cursor/hooks.json` |
| Gemini CLI | ✅ prompts, tools, finished | ✅ when it asks permission | — you answer in Gemini | `~/.gemini/settings.json` |
| Antigravity (IDE, app, CLI) | ✅ prompts, edits, commands, finished | — | ✅ terminal commands (opt-in) | `~/.gemini/config/hooks.json` |

- **Opt-in approvals** (Cursor, Antigravity): turn on *Answer … terminal commands here*. Each terminal command then waits up to 60 seconds for Allow / Deny in AgentBar, then the tool asks as usual. Answering in AgentBar sends `allow` / `deny`; *Answer in terminal*, no answer, or AgentBar being closed sends `ask`, never silence. (Cursor runs a command when a hook stays silent, so the adapter always replies.)
- Restart open sessions or windows after connecting.
- Gemini CLI's hooks can report that it's waiting for permission but can't answer it, so AgentBar shows *Needs you* and you answer in Gemini.
- These hooks cover each tool's **own** agent. Another agent running inside the tool (for example OpenCode in Antigravity's terminal) isn't seen by them; run it with `agentbar run -- opencode` instead.
- From Terminal: `agentbar connect cursor --approvals`, `agentbar disconnect antigravity`, and so on.

**Troubleshooting:** if an agent doesn't show up, create the file `~/Library/Application Support/AgentBar/hook-debug`, use the agent once, and look at `hook-debug.log` next to it: it lists every hook call and AgentBar's reply. Antigravity also logs hook-file problems in `~/.gemini/antigravity/log/`. Delete both debug files afterwards, since the log can contain your prompts.

## 2. Any command: `agentbar run`
Install the command once: **Settings → Agents → agentbar command → Install** (links `~/.local/bin/agentbar`).

```bash
agentbar run -- npm run build
agentbar run --agent trainer --title "model v2" -- python train.py
```
AgentBar shows it as running, then **Done** (exit 0) or **Error** with the exit code. The command runs exactly as before: same output, same input, same exit code, even if AgentBar isn't open. A heartbeat every minute stops long, quiet jobs from looking stuck.

Check from Terminal: `agentbar status` (or `agentbar status --json`).

## 3. Your own agent or script: events
Send one JSON event per line to the socket, or use `agentbar emit`. The schema is in [event-schema.md](event-schema.md). Examples:

| File | Shows |
|---|---|
| [`adapters/examples/emit.sh`](../adapters/examples/emit.sh) | Reporting steps from a shell script |
| [`adapters/examples/emit.py`](../adapters/examples/emit.py) | Python over the socket, including **asking permission and waiting for Allow / Deny** |
| [`adapters/examples/emit.mjs`](../adapters/examples/emit.mjs) | Node.js over the socket |

Tips:
- Use a stable `agent` name and a new `session_id` per run.
- Send `activity` with each step ("Edited README.md"); the last 20 show as the session's tasks.
- Send `heartbeat` during long silent work; a running session that's silent for 10 minutes is marked *may be stuck*.
- End with `finished`, `error` or `stopped`. A session that needs the user but stays silent for an hour is retired automatically.
