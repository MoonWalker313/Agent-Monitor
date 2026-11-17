# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos (native menu bar app: SwiftUI `MenuBarExtra` + AppKit panels; not one of the schema's listed values — closest conventions are Apple's macOS HIG)

## Users
People who run AI agents on their Mac and step away from them: developers running several coding agents in parallel (Claude Code and others), and non-developers using agents for writing, operations and research. They are usually focused on other work when an agent needs them, and many are not fluent in shell commands — they need to understand what an agent is asking before they approve it.

## Product Purpose
AgentBar lives in the macOS menu bar, shows what every agent is doing, and surfaces the moments an agent needs a human: a permission request, a question, a finished task, an error or a stuck run. Success is that agents never sit blocked unnoticed, and that the user approves or denies requests with confidence instead of guessing.

## Positioning
A single, always-present place on the Mac for all agents' status, that can answer an agent's permission request (Allow / Deny) without switching windows, and explains the request — the exact command, file or URL, plus what the agent did just before — so a non-expert can decide.

## Operating Context
- Glanced at from the menu bar many times a day; opened briefly, then dismissed.
- Permission requests interrupt other work via a floating popup and a macOS notification; the user decides in seconds to a minute.
- Agents report through a local Unix socket; Claude Code via hooks (`agentbar hook claude`). If nobody answers within the wait time (default 300 s), the agent asks in its own window.
- Distributed as a self-signed `.dmg` (no Apple notarization); macOS 13+.

## Capabilities and Constraints
- States: needs you (waiting / permission), running, may be stuck (stale), finished, error, stopped.
- Permission request fields: one-line summary, tool, exact detail (command/file/URL, up to 2,000 chars / 40 lines), project folder, last 5 activities.
- Today's totals: sessions, finished, time agents waited on you, tokens, cost (when reported).
- Decisions: Allow, Deny, Answer in terminal (defer). Nothing is approved without a click; notification "Allow" only when the whole command fits in the banner, and requires an unlocked Mac.
- All agent text is untrusted and rendered verbatim (never markdown).
- Undecided: settings UI (stale timeout, cost limits), a risk assessment of requests (none exists yet — must not be implied).

## Brand Commitments
- Name "AgentBar" is a working name.
- Must feel like a native macOS app (Control Center / system-panel level of fit), never web-like.

## Evidence on Hand
No users, testimonials or metrics yet. Demo data in the app is synthetic.

## Product Principles
1. Understand before deciding: every request shows exactly what will happen and the recent context, in plain language first and exact detail second.
2. Never approve by accident: Allow is always a deliberate, visible click; ambiguity falls back to the agent's own prompt.
3. Calm until it matters: quiet status by default; interruptions only for things that need a person.
4. Native first: behave like part of macOS — system type, materials, controls, keyboard and accessibility conventions.
5. Truthful: no invented risk scores or claims about what a command does beyond what the agent reported.

## Accessibility & Inclusion
Non-developer users: plain-language summaries before technical detail. Full VoiceOver labels, keyboard operation, Dynamic contrast (light/dark, Increase Contrast), Reduce Motion respected.
