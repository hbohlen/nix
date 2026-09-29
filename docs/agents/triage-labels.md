# Triage Labels

The skills speak in terms of five canonical triage roles. This repo's tracker is
local markdown (see `issue-tracker.md`), so a "label" is the ticket's `Status:`
line: write the role string there. There is no label object to apply.

| Label in mattpocock/skills | Label in our tracker       | Meaning                                  |
| -------------------------- | -------------------------- | ---------------------------------------- |
| `needs-triage`             | `Status: needs-triage`     | Maintainer needs to evaluate this issue  |
| `needs-info`               | `Status: needs-info`       | Waiting on reporter for more information |
| `ready-for-agent`          | `Status: ready-for-agent`  | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `Status: ready-for-human`  | Requires human implementation            |
| `wontfix`                  | `Status: wontfix`          | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), write the
corresponding role string on the ticket's `Status:` line.

## States this table does not name

Wayfinder tickets move through a lifecycle that is not a triage role:
`open` -> `claimed` -> `resolved`. A ticket triaged `ready-for-agent` is still
`open` until an agent claims it. A `Blocked by:` line is a dependency edge, not
a state.
