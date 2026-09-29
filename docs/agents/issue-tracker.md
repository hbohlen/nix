# Issue tracker: Local Markdown

Issues, specs and tickets for this repo live as markdown files under
`.scratch/`, which is untracked on purpose (see `.gitignore`). There is no
external tracker — no board, no database, no CLI. The files are the tracker.

## Layout

- One effort per directory: `.scratch/<effort-slug>/`
- The **map** (wayfinder) is `.scratch/<effort-slug>/map.md`
- The **spec**, when one exists, is `.scratch/<effort-slug>/spec.md`
- **One ticket per file**: `.scratch/<effort-slug>/issues/NN-<slug>.md`,
  numbered from `01`, never a single combined tickets file
- Triage state is the `Status:` line near the top of each ticket file (see
  `triage-labels.md` for the role strings)
- Comments and conversation history append to the bottom of the file under a
  `## Comments` heading

The live effort today is `.scratch/devenv-layering/` — the shell-vs-machine
layering map and its decision tickets. It is the worked example this doc
describes.

## The `Status:` line leads

A ticket's `Status:` line is the state. Nothing else records it, so the file is
updated in the same action as the state change: `open` -> `claimed` before work
starts, `claimed` -> `resolved` with the answer when it is done. The map's
`Status:` header follows its tickets; it does not lead them.

## When a skill says "publish to the issue tracker"

Create a new file under `.scratch/<effort-slug>/`, creating the directory if
needed. Break multi-part work into one file per ticket, numbered in dependency
order, and express dependencies with `Blocked by:` lines rather than one long
file.

## When a skill says "fetch the relevant ticket"

Read the file at the referenced path. The user normally passes the path or the
issue number directly.

## Wayfinding operations

Used by `/wayfinder`. The **map** is `.scratch/<effort>/map.md`; each **child
ticket** is `.scratch/<effort>/issues/NN-<slug>.md`.

- **Type**: a `Type:` line records `research` / `prototype` / `grilling` /
  `task`.
- **Blocking**: a `Blocked by: NN, NN` line near the top. A ticket is unblocked
  when every file it lists is `resolved`.
- **Frontier**: scan `issues/` for files that are open, unblocked and unclaimed;
  first by number wins.
- **Claim**: set `Status: claimed` and save before any work.
- **Resolve**: append the answer under an `## Answer` heading, set
  `Status: resolved`, then append a context pointer (gist + file) to the map's
  Decisions-so-far in `map.md`.

## Why local markdown

The design record and the tracker are the same artifact, so a decision ticket
can cite its own evidence without a second system to keep in step. The cost is
that nothing dispatches work: an agent picks the frontier up by reading the
files. If this repo ever grows a real dispatch queue again, this doc is the one
place that says where issues live.
