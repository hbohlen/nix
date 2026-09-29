# 0004 — Self-updating CLIs keep a durable copy AND gain a shell shadow

Every self-updating agent CLI keeps its native install (in `~/.local/bin`, or
netcup's home-manager role) and is additionally declared in the devenv shell.
Inside the project the declared copy wins; outside it, the native install is
what survives a broken shell. This is deliberate duplication: a single source
was rejected because an agent that cannot start is worth more dead than
misconfigured, and the workstation PATH already resolves `~/.local/bin` ahead
of `/usr/bin`, so the shadow is authoritative where it matters. Same reasoning
left the Arch `git` install and netcup's `agents.nix` in place (D9).
