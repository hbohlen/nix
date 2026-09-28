# Triage Labels

The skills speak in terms of five canonical triage roles. Hermes Kanban has **no label vocabulary** — the `tasks` table carries no label or tag column. Each role therefore maps onto a card **status**, or onto a **block kind** where the card is parked waiting on a person.

This file maps those roles to the actual state used on this board.

| Label in mattpocock/skills | State in our tracker                                               | Meaning                                  |
| -------------------------- | ------------------------------------------------------------------ | ---------------------------------------- |
| `needs-triage`             | status `triage` (`hermes kanban create --triage`)                  | Maintainer needs to evaluate this card   |
| `needs-info`               | status `blocked`, `block_kind = needs_input`                       | Waiting on reporter for more information |
| `ready-for-agent`          | status `ready`, `assignee` = an installed profile                  | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | status `blocked`, `block_kind = capability` (or `--initial-status blocked`) | Requires human implementation    |
| `wontfix`                  | status `archived` (`hermes kanban archive <id>`)                   | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the state from the right-hand column. There is no label to apply: set the status, or block with the matching kind — `hermes kanban block <id> --kind needs_input`, and the `kanban_block(kind=...)` tool from inside a session.

## States this table does not name

Kanban's machine is wider than the five roles. These states have no triage-role equivalent and are reached by the normal lifecycle, not by triage:

| Status      | Reached by                                                              |
| ----------- | ----------------------------------------------------------------------- |
| `todo`      | Parent-gated: waiting on another card, or waiting to be promoted         |
| `scheduled` | `hermes kanban schedule` — parked on time, not on a human                |
| `running`   | Claimed and executing by a worker                                        |
| `review`    | `kanban_request_review` — implementation done, awaiting a verdict. This is explicitly **not** a block |
| `done`      | `kanban_complete`                                                        |

Review is its own lane, not a blocked card: a reviewer approves with `kanban_complete`, sends actionable rework back with `kanban_request_changes`, and reserves `kanban_block` for a genuine external escalation (that last case is the `capability` / `needs_input` rows above).