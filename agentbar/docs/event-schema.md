# AgentBar event schema v1

Agents report activity to AgentBar by sending **one JSON object per line** to a Unix socket at
`~/Library/Application Support/AgentBar/agentbar.sock`. The easiest way is the bundled CLI:

```bash
agentbar emit --agent my-agent --session 42 --event needs_input --message "Which branch?"
echo '{"agent":"my-agent","session_id":"42","event":"finished"}' | agentbar emit --json
```

Only processes running as the same macOS user can connect. There is no network port.

## Fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `v` | int | no | Schema version. Must be `1` if present. |
| `agent` | string | **yes** | Stable agent name, e.g. `claude-code`. Max 128 characters. |
| `session_id` | string | **yes** | Unique per run or conversation. `(agent, session_id)` identifies a session. Max 128. |
| `event` | string | **yes** | See *Event kinds*. |
| `timestamp` | string | no | ISO 8601 (`2026-11-16T14:03:22Z`, fractional seconds OK). Ignored, with a warning, if more than 5 minutes from the Mac's clock. |
| `title` | string | no | Short label, e.g. the project name. Max 80 (longer is truncated with "…"). |
| `message` | string | no | One-line status, e.g. `Permission: run npm install?`. Max 280. |
| `cwd` | string | no | Absolute working directory. Max 1024. |
| `open_url` | string | no | What to open when the user clicks the session. Allowed schemes: `https`, `vscode`, `vscode-insiders`, `cursor`, `windsurf`, `zed`, `jetbrains`, `iterm2`, `warp`, `x-github-client`. Never `file:`, `javascript:`, `data:`, `http:`, or URLs with credentials. |
| `activate_bundle_id` | string | no | App to bring to the front, e.g. `com.googlecode.iterm2`. |
| `activity` | string | no | What the agent just did ("Edited Checkout.swift"). The last 20 are kept as the session's *Tasks* (click a session to see them); the request card shows the latest 3. Max 120. |
| `request` | object | no | Only with `needs_permission` **and** `await_seconds`. `{ "id": str (required), "tool": str, "summary": str, "detail": str, "questions": [...] }`. Shown as a card with **Allow / Deny**, or, with `questions`, with the options to pick from (see *Questions*). `detail` (the exact command, file or URL) keeps line breaks, up to 2,000 characters / 40 lines. Without `await_seconds` it's shown as a plain message, since no answer could reach the agent. Once shown, a request's content can't be changed by later events with the same `id`. |
| `await_seconds` | int | no | With `request`: keep the connection open and reply with the user's decision (see *Permission decisions*). 1–600. |
| `usage` | object | no | `{ "input_tokens": int, "output_tokens": int, "cost_usd": number }`. **Deltas** since your last report; AgentBar sums them. Non-negative, at most 10M tokens / $1,000 per event. |

Unknown fields are ignored (forward compatible). `reply_channel` is reserved for a future version.

## Event kinds

| `event` | Session becomes | Alerts? |
|---|---|---|
| `started` | running | |
| `working` | running | |
| `heartbeat` | running. Stays *needs you* if it was waiting; revives a *stale* session | |
| `needs_input` | **needs you** | ✅ |
| `needs_permission` | **needs you** | ✅ |
| `finished` | finished | ✅ |
| `error` | error | ✅ |
| `stopped` | stopped | |

A **running** session with no events for 10 minutes (configurable per agent) is marked **stale ("may be stuck")** and alerts once. Send `heartbeat` during long silent work to prevent this. A waiting session never goes stale.

## Replies

AgentBar writes one JSON line back per event:

```json
{"ok":true,"running":2,"waiting":1}
{"ok":true,"running":2,"waiting":1,"warnings":["open_url dropped: scheme 'file' is not allowed"]}
{"ok":false,"error":"invalid event JSON: missing field 'session_id'"}
```

- **Required fields** that are missing or invalid reject the event (`ok: false`).
- **Optional fields** that are invalid are dropped and reported in `warnings`; the event is still accepted.

## Permission decisions

Send `needs_permission` with a `request` and `await_seconds`, and **keep the connection open**
(`agentbar` and `SocketClient.request` do this). AgentBar shows a card and a popup with Allow / Deny, and writes
one reply line when there's an answer:

```json
{"ok":true,"decision":"allow"}
{"ok":true,"decision":"deny","decision_message":"The user denied this from AgentBar."}
{"ok":true,"decision":"defer"}
{"ok":true,"decision":"allow","answers":{"Which database?":"SQLite"}}   (a request with questions)
```

Only one connection can wait on a given request `id`; a second one is refused.

`defer` means *don't decide here*: the user clicked **Answer in terminal**, nobody answered within
`await_seconds`, or AgentBar quit. Your agent should fall back to its own prompt. Closing the connection
early withdraws the request (the card disappears).

## Limits

- 16 KB per line; longer lines are rejected and the connection is closed.
- 20 events/s per session (bursts up to 40); extra events get `ok: false` with `rate limited`.
- Idle connections are closed after 5 s.

## Privacy

Everything stays on your Mac, in `~/Library/Application Support/AgentBar/agentbar.sqlite` (file mode `0600`). The event log keeps only the event kind and time; titles, messages and paths are kept only on the session's current row. History is deleted after 30 days, or right away with **Clear**.

## Questions

For a decision with options, add `questions` to the `request` (1–4 questions):

```json
{"agent":"my-agent","session_id":"7","event":"needs_permission","await_seconds":120,
 "request":{"id":"q1","summary":"Which database?","questions":[
   {"question":"Which database?","header":"DB","multiSelect":false,
    "options":[{"label":"Postgres","description":"Relational"},{"label":"SQLite"}]}]}}
```

Each question needs a unique `question` (max 300 characters) and 2–6 unique option `label`s (max 120);
`header` and `description` are optional. Malformed questions are dropped with a warning and the card
falls back to Allow / Deny. The user picks options and presses **Send answer**; the reply is `allow`
with `answers`, mapping each question to the chosen label (several labels joined with `", "` when
`multiSelect` is true). AgentBar only sends answers that are options it showed, and never answers a
question with a bare `allow`; `deny` means the user chose not to answer, `defer` that they'll answer
in the agent's own window.
