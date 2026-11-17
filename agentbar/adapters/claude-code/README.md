# Claude Code → AgentBar

Shows every Claude Code session in AgentBar, and lets you **Allow / Deny permission requests from the menu bar**.

## Install
**Easiest:** AgentBar ⚙︎ → Settings → Agents → **Connect** (also in the first-run setup guide). It adds these hooks to `~/.claude/settings.json`, keeps your other settings, and saves a backup as `settings.json.agentbar-backup`. **Disconnect** removes them again.

**By hand:** merge `settings.snippet.json` into `~/.claude/settings.json` (all projects) or `.claude/settings.local.json` (one project).

Then start a new Claude Code session (open sessions keep their old hooks until restarted).

## What you get
| Claude Code hook | AgentBar shows |
|---|---|
| SessionStart / SessionEnd | Session appears / stops |
| UserPromptSubmit | Running — "Working on: <your prompt>" |
| PostToolUse | Recent activity: "Edited Checkout.swift", "Ran swift build"… |
| **PermissionRequest** | **Card + popup with the exact command/file and Allow / Deny** |
| Notification (idle) | Needs you — waiting for your next message |
| Stop | Finished — ready for review |

## How Allow / Deny works
`agentbar hook claude` sends the request to AgentBar and **waits up to 300 s** for your answer, then prints
Claude Code's decision (`allow` or `deny`). If you click **Answer in terminal**, don't answer in time, or AgentBar
isn't running, it prints nothing, and Claude Code shows its normal permission prompt. Nothing is ever
approved without your click.

To answer faster or slower, change `--wait 300` (and keep `timeout` about 10 s higher).
