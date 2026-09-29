# 0005 — zsh stays the login shell; nu is only the project shell

Nu becomes the interactive shell inside the devenv project and the shell new
panes spawn, but never the OS login shell. zsh stays that, which sidesteps the
documented caveat that nu cannot source `/etc/profile` and would skip the nix
profile scripts. `shell: nu` is declared in `devenv.yaml` — the
highest-priority source in the pinned 2.4.0's resolution order — and `nushell`
is declared as a package because a missing binary does not fall back the way an
unsupported value does. The nix profile's nushell entry was removed (D40) so
the declared nu is the only nu inside the project.
