# 0003 — Agent CLIs from the pinned llm-agents input, not nixpkgs

`hermes`, `herdr`, `claude`, `codex`, `opencode2`, `agent-browser`,
`parallel-cli` and `luvus` come from the `llm-agents` flake input rather than
nixpkgs. Reason: the input pins exact versions of tools that change daily, and
the netcup host already consumes the same input, so one declaration serves both
machines. The cost is accepted and recorded in `modules/agents.nix`: the input
deliberately does not follow nixpkgs, so the shell closure carries a second
nixpkgs — a larger download and a second evaluation on the workstation.
