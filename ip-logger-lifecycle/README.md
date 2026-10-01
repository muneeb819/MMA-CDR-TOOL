# IP Logger Lifecycle Visualizer

An interactive sequence diagram of the full request lifecycle of an IP logging
shortlink — link creation, traffic capture, a concurrent extraction fan, and
dual parallel output.

A self-contained educational visualizer. It contains **no working IP logger, no
network calls, and no real telemetry** — every payload is hard-coded sample data
written to illustrate the protocol, not to perform it.

## Run it

No install or build step. Open the file directly:

```
ip-logger-lifecycle/index.html
```

Or serve it locally if you prefer a real origin (needed for the
`navigator.clipboard` API — it is blocked on `file://` in some browsers, though
the app falls back automatically):

```bash
npx serve .          # or: python -m http.server 8080
```

Internet access is required on first load: Tailwind, FontAwesome and the Google
Fonts are pulled from CDNs.

## The model

Four phases, six steps. The important structural point: **steps 3 and 4 are not
sequential, and neither are 5 and 6.** Both pairs are concurrent branches that
fork from a common node and rejoin, and both are drawn that way on the canvas.

```
[ Link Creator ] ──> 1. Create Link ──> [ IP Logger Engine ] ──> Generates Short URL
[ Visitor ]     ──> 2. Click Link  ──┘
                                        │  fork
                        ┌───────────────┴───────────────┐
                        ▼                               ▼
              [ Passive Extraction ]          [ Active / GPS Extraction ]
               IP · User-Agent · Referrer      Device · Battery · GPS
                        └───────────────┬───────────────┘
                                        │  merge
                       ┌────────────────┴────────────────┐
                       ▼                                 ▼
        5. Path A · HTTP 301/302 Redirect    6. Path B · Data Persistence
                       │                                 │
            [ Target Destination ]              [ Creator Dashboard ]
```

| # | Phase | Step | Actor | Branch |
|---|-------|------|-------|--------|
| 1 | Short Link Creation | Create tracking link | Creator | — |
| 2 | Traffic Capture | Inbound click & routing | Visitor | — |
| 3 | Logging Engine | Passive extraction | System Event | fork L |
| 4 | Logging Engine | Active / GPS extraction | System Event | fork R |
| 5 | Dual Output | Path A — HTTP 301/302 redirect | System Event | out A |
| 6 | Dual Output | Path B — data persistence | System Event | out B |

Phase metadata lives in one `PHASES` map, so the badge, the legend chips and the
timeline JSON all read the same canonical names.

## Controls

| Action | Control |
|--------|---------|
| Next / previous step | `→` `←` keys, or the toolbar buttons |
| Play / pause | `Space`, or the play button |
| Reset to step 1 | `R`, or the reset button |
| Jump to a step | Click any arrow or extraction branch, or a phase chip |
| Change speed | Speed slider, 2.5s → 0.3s per step |
| Auto-loop | Loop checkbox (also enables wrap-around on `→`) |
| Inspect data | Right panel: actor, direction, flow, operations, JSON |
| Full timeline | "Raw Payload View" toggles a whole-run JSON dump |
| Copy | Copies the current step payload, or the full timeline |

## Project layout

```
ip-logger-lifecycle/
├── index.html   # entire app: markup, SVG diagram, styles, logic
├── validate.cjs # static wiring check (see below)
└── README.md
```

Structure inside `index.html`:

- **`<head>`** — CDN scripts, Tailwind theme (`cyber`/`neon` palettes), custom CSS
  for the grid backdrop, glow filters, concurrency rails and packet animation
- **`<svg>`** — 800×490 viewBox: 4 actor cards, dashed lifelines, 2 dashed
  parallel bands, 2 fork/merge nodes, 6 clickable message elements, 1 packet
- **`PHASES`** — canonical name + short label for each of the 4 phases
- **`stepsData`** — one object per step: phase, status, actor role, source and
  target, `flowIn`/`flowOut` lists, technical operations, `arrowId`, `packetPos`
  and the sample JSON payload
- **Controller** — `renderStep()` paints all UI from one step object; the rest
  handle playback, view toggling, clipboard and keyboard input

### Diagram geometry

Two dashed `parallel-band` rects group the concurrent regions, each with a
labelled chip (`EXTRACTION FAN · PARALLEL`, `DUAL OUTPUT · PARALLEL`). Inside
them, `.fork-rail` paths carry dashed rails between solid `circle` fork/merge
nodes. The extraction branches are rendered as labelled boxes rather than
lifeline arrows, because the work happens *inside* the engine — there is no
second participant to point at.

### Validation

Because the page is authored in one piece, a typo in an id or a coordinate can
silently break a step. `validate.cjs` parses the file, evaluates `PHASES` and
`stepsData`, and cross-checks them against the real DOM and SVG geometry:

```bash
node validate.cjs
```

It asserts that each step has all required fields, that every `arrowId` resolves
to a `<g>` wired to `goToStep()` and keyboard-focusable, that every `packetPos`
lies inside the viewBox, that payloads serialise, that each phase has at least
one step, that the two extraction branches **share a fork origin and diverge
left/right**, that both dual-output paths exist, that no step label box overlaps
another, that every shape is inside the viewBox, that all arrow markers are
defined, and that no id is duplicated. Exits non-zero on failure.

## Notes on the design

- **`TARGET DESTINATION` is now actually reached.** Path A terminates on that
  lifeline, matching the final destination in the flow model. Previously the
  lifeline existed with no arrow pointing at it.
- **The extraction fan merges before any output.** The merge node feeds the dual
  output fork, so the diagram cannot be read as "redirect happens before GPS
  returns" — which would be wrong.
- **Passive vs active is a real distinction in the data.** The passive payload
  carries `requires_client_script: false`; the active branch carries `true` and a
  separate `geolocation.permission` field, so "only if granted" is visible in the
  payload rather than only in prose.
- **Path A / Path B are colour-coded** (emerald = user delivery, blue = data
  persistence) and each is a complete trip from engine to its own terminus.

## Adding a step

Append an object to `stepsData`. It needs a `step` number, a `phase` key that
exists in `PHASES`, phase and status styling classes, inspector copy, a `role`
triple (`role`/`roleIcon`/`roleTone`), `source` and `target` pairs, an
`actions` array, at least one of `flowIn`/`flowOut` (each with a matching
`*Label`), an `arrowId` matching a `<g>` in the SVG, a `packetPos` of
`{startX, startY, endX, endY}` in viewBox coordinates, and a `payload` object.
The step counter, timeline JSON and button states all derive from the array
length, so no other edits are needed.
