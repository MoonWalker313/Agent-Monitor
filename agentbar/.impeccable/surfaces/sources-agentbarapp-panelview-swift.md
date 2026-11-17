---
version: 1
slug: "sources-agentbarapp-panelview-swift"
primary_target: "Sources/AgentBarApp/PanelView.swift"
related_targets: ["Sources/AgentBarApp/RequestViews.swift","Sources/AgentBarApp/AgentBarApp.swift"]
---

# Surface: AgentBar menu bar panel + permission popup

Scope: SwiftUI MenuBarExtra panel (PanelView), permission request card (RequestCard), floating request popup, session rows, menu bar status icon. Mode: Operate (native macOS).
Audience: developers and non-developers running AI agents; job: notice what needs them and decide on permission requests with understanding.
Constraints: native controls only (SwiftUI Button/Menu/Toggle), SF Pro + SF Mono for code, follows system light/dark, VoiceOver, Reduce Motion, all agent text verbatim.

## Direction contract
THESIS: Every agent is a cue on a stage manager's board; nothing happens until you give the go. Refuses the category's grey list with one blue accent.
OWN-WORLD: Blackout panel (dark) / house-lights panel (light, warm grey) following system appearance. Cue lamps carry state: standby amber, running blue, done green, error red, stuck dim amber, stopped unlit. Gaffer-tape labels: small mono project tag on a tape-grey chip. Go = green prominent button. Every lamp also has a glyph and a word.
STORY: Glance: the menu bar lamp says whether anything is standing by. Open: standing-by cues lead, each saying in plain words what the agent wants, then the exact command, then what it did before. Decide: Allow (Go), Deny (Hold), or hand back to the terminal.
FIRST VIEWPORT: Header row (AgentBar, "1 standing by · 2 running", settings menu). Standing-by cue cards lead, full width: lamp + tape label + waiting time; plain headline; exact command block; "Before this" lines; Deny / Allow trailing, Answer in terminal leading. Below: cue list rows (lamp, project, agent · state · last activity, time). Footer: today's totals.
FORM: Standby, Go (theatre cue-light board), my top-ranked grounded candidate (1 of 7), chosen by the user over the assigned The Pass. seed:e496a80698e1dfae
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

Signature interaction: the cue lamp. A standing-by lamp breathes slowly (static under Reduce Motion); on Allow it flashes green once and the cue folds back into the list (200 ms ease-out).
Translation note: the chosen card was dark-only in spirit; PRODUCT.md commits to native light/dark, so the stage palette ships in both appearances.
