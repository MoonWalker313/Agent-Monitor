# Security

AgentBar can approve actions on your Mac on an agent's behalf, so it's built to be conservative. This page describes what it protects against, how, and how to report a problem.

## Reporting a vulnerability

Please **don't open a public issue**. Use **Security → Report a vulnerability** on this repository (a private security advisory), or contact the maintainer through their GitHub profile. Include the AgentBar version (`agentbar version`), your macOS version, and steps to reproduce.

## Threat model

| Threat | Protection |
|---|---|
| A web page or another computer sending fake events | **No network listener at all.** Agents connect through a Unix domain socket, which browsers and remote machines can't reach. |
| Another user account on the same Mac | The socket's folder is `0700` and the socket `0600`; every connection's user ID is checked with `getpeereid` and refused if it isn't yours. |
| Malformed or hostile event content | Events are size-limited (16 KB), rate-limited (20/s per session), validated, and stripped of control and bidirectional-override characters. Text is always shown verbatim, never as Markdown. |
| An agent making AgentBar open something dangerous | Links are allow-listed (`https` and known editor/terminal schemes only; never `file:`, `javascript:`, `data:` or `http:`); links that open another app ask first. |
| Approving something other than what you saw | A request's content can't be changed after it's shown; only the first agent waiting on a request ID can receive the answer; the answer is delivered only if it matches exactly what was displayed. |
| Approving something AgentBar decided on its own | Only Cursor and Antigravity commands that are strictly read-only pass without asking, and only while *Only ask about commands that change things* is on. Anything AgentBar can't fully parse asks: writes (`>`), pipes into other programs it doesn't know, `$` variables, substitutions, paths to programs, options that write or run programs (`find -exec`, `sort -o`…), and reads of credential files. Claude Code only calls AgentBar when it would ask you itself, so its requests always show. |
| Answering a question with something that wasn't offered | Answers are checked against the options shown, both in AgentBar and in the hook, before they reach the agent; a question can't be answered with a bare Allow. |
| Accidental approval | Nothing is approved without a click. **Allow** ignores clicks for a moment after a request appears, so a popup can't slide under your pointer mid-click. Notification **Allow** appears only when the whole command fits in the banner and requires an unlocked Mac. If you don't answer, the agent asks in its own window. |
| Leaking your Claude Code settings | Connect/Disconnect change only AgentBar's own hooks, keep the file's permissions (it can contain API keys), follow dotfile symlinks, save a private (`0600`) backup, and refuse to touch a file they can't parse. |

**Out of scope:** malware already running as your user. It could read your files, and Claude Code's, directly; AgentBar doesn't try to defend against it beyond the request-integrity checks above.

## What AgentBar stores

Everything stays in `~/Library/Application Support/AgentBar/` (folder `0700`, files `0600`):

- **Sessions:** agent, project name and folder, current status message, the last 20 task descriptions (for Claude Code these include the first line of your prompts, e.g. "You asked: …"), token and cost totals if reported.
- **Event log:** only the event kind and time, never message text.
- **Daily totals.**

If you turn on hook troubleshooting (`hook-debug`), every hook call is also written to `hook-debug.log` (0600) in the same folder until you delete the flag file; it can contain prompts and the agents' account details, so delete it after use.

History is deleted after 30 days by default (7, 30 or 90 in Settings), or immediately with **⚙︎ → Clear History**. AgentBar never reads your files or full transcripts, and sends nothing over the network.

Preferences are in the standard macOS preferences for `dev.agentbar.AgentBar`.

## Distribution

Releases are built by GitHub Actions from the tagged source, universal (Apple silicon + Intel), ad-hoc signed with the hardened runtime, and published with SHA-256 checksums. They're **not notarized** by Apple, so macOS asks you to approve AgentBar once. Verify a download with `shasum -a 256 AgentBar-*.dmg` against `SHA256SUMS.txt`.

## Last review

**2026-11-17 (v1.0.0 → v1.0.1):** reviewed the socket, input validation, the permission path, file writes, the CLI and the published `.dmg` (no personal paths or details in the binaries). Fixed in 1.0.1:
- a waiting request's text could be replaced by a later event with the same ID, so you might approve something other than what was shown;
- a second connection could take over a waiting request;
- writing Claude Code settings could widen the file's permissions or replace a dotfile symlink;
- **Allow** could be clicked the instant a popup appeared.

Regression tests cover each of these.
