# Issue tracker: Hermes Kanban

Issues, specs and tickets for this repo live as cards on a Hermes Kanban board (SQLite board; the `default` board's DB is `~/.hermes/kanban.db`). Drive it with `hermes kanban <verb>`, or with the `kanban_*` tools from inside an agent session.

The board is the tracker. Nothing about an issue lives in this repo — cards are not files, and there is no `.scratch/` convention here.

## Conventions

- **Create an issue**: `hermes kanban create "<title>" --body "..." --assignee <profile> [--triage] [--parent <id>] [--json]`. Use a quoted body or a file for multi-line text.
- **Read an issue**: `hermes kanban show <task-id>` — prints the body, comments, runs and events.
- **List issues**: `hermes kanban list` with `--status <s>`, `--assignee <profile>`, `--tenant <t>`, `--limit N`.
- **Comment on an issue**: `hermes kanban comment <task-id> "<body>"` (tool: `kanban_comment`). Comments are the conversation history; there is no separate thread object.
- **Move state**: `hermes kanban unblock`, `promote`, `request-review`, `request-changes`, `complete`, `archive`, `block`. There is no "apply a label" operation — see `triage-labels.md`.
- **Attach a file**: `hermes kanban attach <task-id> <path>` (tool: `kanban_attach`; URLs via `kanban_attach_url`).
- **Depend on another ticket**: `hermes kanban link <parent> <child>`, or `--parent <id>` at create time. A child waits in `todo` until every parent reaches `done`.

Task ids are `t<N>`, and there is a single number space — a bare `t42` always means the card, never a file.

## When a skill says "publish to the issue tracker"

Create a card with `hermes kanban create`. Default to `--created-by` untouched and assign the profile that should do the work. Break multi-part work into one card per ticket and link them with `--parent` rather than writing one long card.

## When a skill says "fetch the relevant ticket"

Run `hermes kanban show <task-id>`. The card body, every comment, prior runs and the event log are all in that one output — read it before asking the user for context.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a parent card holding the Notes / Decisions-so-far / Fog body. Each **child ticket** is a card created with `--parent <map-id>`, carrying its question in the body.

- **Blocking**: a `task_links` parent→child edge, set at create time (`--parent`) or later (`hermes kanban link`). A ticket is unblocked when every parent is `done`.
- **Frontier query**: list the map's children, drop any with an unfinished parent or a live claim; first in map order wins. `--status` takes a single value, not a repeatable flag, so either read the whole board with `hermes kanban list --json` and filter, or run `--status ready` and `--status todo` as two calls.
- **Claim**: assign the ticket to a profile and let the dispatcher start it. The claim is the board's, not a file's — no manual `Status:` line to write.
- **Resolve**: `hermes kanban complete <id> --summary "<answer>"` (tool: `kanban_complete`), then append a context pointer (gist + card id) to the map's Decisions-so-far with a comment on the map card.

## Who picks work up

The dispatcher runs inside the Hermes gateway (`kanban.dispatch_in_gateway: true` by default). A card only moves `ready -> running` while the gateway is running, so start it with `hermes gateway start` before expecting autonomous work to begin.

Two rules that bite quietly:

- **The assignee must be a real profile.** A card whose `--assignee` is not an installed Hermes profile is dropped by the dispatcher and sits in `ready` forever. Check with `hermes profile list`.
- **Per-board isolation.** Workers get `HERMES_KANBAN_BOARD` pinned, so a card only ever sees its own board. Use `hermes kanban --board <slug>` (or `hermes kanban boards switch <slug>`) to work on a different one.

## Workspaces

A card executes in an isolated workspace, configured per card:

- `--workspace scratch` (default): a throwaway temp dir. Good for research, specs and planning tickets.
- `--workspace worktree:<path>` or `--project <slug>`: a git worktree anchored to a repo, with a deterministic branch. Use this for tickets that change code in this repo. `hermes project create` + `hermes project bind-board` wires a project to a board so the anchor is implicit.