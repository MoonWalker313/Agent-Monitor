# AgentBar Design System: "Standby, Go"

A stage manager's cue-light board, built from native macOS controls. Every agent is a cue; anything waiting on the user is a cue **standing by**, and nothing happens until the user gives the go. Surface brief: `.impeccable/surfaces/sources-agentbarapp-panelview-swift.md`.

## Principles
- **Native first.** SF Pro for UI, SF Mono only for exact commands and the tape label. Native Menu, Toggle, Button roles, alerts. Follows the system appearance: a blackout panel in dark mode, a house-lights panel in light mode.
- **Understand before deciding.** A request card reads, top to bottom: who is asking → what it wants, in plain words → the exact command → what it did before → Answer in terminal / Deny / Allow.
- **Colour is never alone.** Every state has a lamp colour, an SF Symbol and a word.

## Tokens (`Sources/AgentBarApp/Theme.swift`)
| Token | Light | Dark | Use |
|---|---|---|---|
| panel | #F2F1EE | #161618 | Panel and popup ground |
| cue | #FFFFFF | #232326 | Grouped cue rows, Deny button |
| cueHover | #F7F6F3 | #2B2B2F | Row hover |
| standby | #FFF6E3 | #251E11 | Standing-by request card |
| standbyEdge | #E8B65A | #7A5A1C | Request card border (1px) |
| hairline | #DEDBD4 | #343438 | Dividers, row group border |
| ink / inkSecondary / inkTertiary | #1D1D1F / #5F5E63 / #77767B | #F2F2F7 / #A8A8AD / #8E8E93 | Text |
| tape / tapeInk | #E4E0D7 / #47443D | #3A3A3D / #D6D6DB | Project tape label |
| script / scriptInk | #F8F3E7 / #4F3800 | #0F0F10 / #FFD58A | Exact-command block |
| amber / amberInk | #F0A01C / #8A5600 | #FFB020 / #FFC14D | Standing by, needs you, may be stuck |
| blue / blueInk | #0A7AFF / #0060CC | #0A84FF / #5EAEFF | Running |
| green / greenInk | #2DB653 / #1C7A37 | #30D158 / #5EDB7F | Done, Go flash |
| red / redInk | #E5372B / #C0261B | #FF453A / #FF7A70 | Error |
| unlit | #B9B6AF | #4A4A4E | Stopped, may be stuck (unlit lamp), empty board |
| go | #1F7A36 | #248A3D | Allow button fill (white label) |

Lamp fills are graphics; any text in a state colour uses the `…Ink` token (≥4.5:1 on its ground).

## Type scale
Request headline 15 semibold · project name 13 medium · body/caption 11–12 · section labels caption semibold · command 12 SF Mono · tape 10 SF Mono medium · times monospaced digits.

## Components
- **CueLamp**: 10pt circle (16pt in empty state), soft glow when lit. Standing-by lamps breathe (1.4s ease-in-out), held still under Reduce Motion. On Allow it flashes green for 180ms before the card folds away (200ms ease-out, opacity + 0.97 scale).
- **TapeLabel**: project name in 10pt mono on a tape chip, radius 2.
- **StateTag**: SF Symbol + word in the state's ink colour.
- **CueCard** (request): standby ground, 1px standby edge, radius 10, padding 14, spacing 12. Copy button on the command; command block scrolls past 110pt.
- **CueRow**: lamp, project, agent, relative time; StateTag + message or last activity. Plain button, hover tint; opens the agent's window when it reported a link or app.
- **Groups**: "Needs you", "Running", "Done today", shown only when non-empty, on a `cue` rounded group with hairline dividers inset past the lamp.
- **Buttons**: `GoButtonStyle(.go)` green fill with white semibold label, `GoButtonStyle(.hold)` cue fill. Both radius 7, 6/12 padding. A custom style so Allow stays green in the non-activating popup, where a stock prominent button would go grey. "Answer in terminal" is a link button.
- **Menu bar icon**: template SF Symbols; circle (idle), circle.inset.filled (running), circle.fill + count (needs you).

## Layout
Panel 400pt wide: header (12/14 padding) → notices → divider → board (padding 14, groups 14 apart, max height 560, scrolls) → divider → two-line footer. Popup 400pt, non-activating floating panel, top-right under the menu bar, "Later" hides it.

## Copy
Plain verbs, no em dashes. Requests read "Wants to …". States: Standing by, Needs you, Running, May be stuck, Done, Error, Stopped. Empty board: "No agents on stage".
