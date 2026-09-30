# modules/shell.nix — nushell as a first-class shell, and the token export.
#
# D26/D29: nu is the interactive shell INSIDE the devenv shell, and the shell a
# new pane spawns. It is NOT the OS login shell — zsh stays that, which sidesteps
# the documented caveat that nu cannot source /etc/profile and would therefore
# skip the nix profile scripts.
#
# THE SHELL TYPE IS NOT SET HERE. It is `shell: nu` in devenv.yaml, because the
# pinned 2.4.0 resolves the shell in this order (measured in
# `devenv-core/src/settings.rs`, `resolve_with_shell_hint_env_and_login_shell`):
#
#   1. `devenv.yaml`'s `shell:` — highest priority
#   2. the hook's `_DEVENV_SHELL_HINT`
#   3. `$SHELL`
#   4. the login shell
#   5. bash
#
# An UNSUPPORTED value falls back to bash with a warning; a MISSING BINARY does
# not, which is why Q3b declares `nushell` as a package below rather than
# trusting the fallback.
{ pkgs, lib, config, ... }:

let
  # carapace supports nu through its own subcommand, not through a wrapper
  # script: `carapace _carapace nushell` prints a snippet that sets
  # `$env.config.completions.external.completer`.
  carapace = "${pkgs.carapace}/bin/carapace";
in

{
  packages = [
    pkgs.nushell # the `nu` binary; D26, and the reason the fallback is real
  ];

  enterShell = ''
    # D36 — THE TOKEN, EXPORTED ONCE INSTEAD OF BACKFILLED PER PANE.
    #
    # What this replaces: each of `bb-pane-run.sh`, `tailnet-enroll.sh` and
    # `self-deploy-verify.sh` re-read the same file and re-exported the same
    # variable, because a pane does not inherit the shell that spawned it. All
    # fifteen scripts are deleted (D33), so the export lives somewhere panes DO
    # inherit: the activation environment.
    #
    # WHY THE FILE AND NOT SECRETSPEC: declaring this token as a secretspec
    # secret would be circular — secretspec's 1Password provider calls `op`,
    # which is what needs the token.
    #
    # D45 (ticket 07, 2026-09-29) REMOVED THE BOOTSTRAP REQUIREMENT. While
    # `secretspec.enable` was true, activation resolved the profile BEFORE
    # `enterShell` ran, so a tokenless activation died at the provider gate
    # (measured 2026-09-28: "OnePassword authentication required ... set
    # OP_SERVICE_ACCOUNT_TOKEN") and the token had to come from the shell rc.
    # The integration is now OFF, a tokenless `devenv test` is green, and this
    # export is a CONVENIENCE: panes spawned from an activated shell can run
    # `secretspec run` or `devenv machines` without re-reading the file.
    if [ -z "''${OP_SERVICE_ACCOUNT_TOKEN:-}" ] && [ -r "$HOME/.config/op-sa-token" ]; then
      export OP_SERVICE_ACCOUNT_TOKEN="$(cat "$HOME/.config/op-sa-token")"
    fi
  '';

  enterTest = ''
    # A smoke test, not an acceptance suite (fog item 6: `tests` is for a simple
    # env assertion). Ticket 05's acceptance is that the shell has what the
    # placement table promised.
    set -euo pipefail

    for tool in gh git jj op nixd carapace nu uv wrangler openspec; do
      command -v "$tool" >/dev/null || { echo "missing from the shell: $tool"; exit 1; }
    done

    for tool in hermes herdr claude codex opencode2 agent-browser parallel-cli luvus; do
      command -v "$tool" >/dev/null || { echo "missing from the shell: $tool"; exit 1; }
    done

    for tool in node npm pnpm yarn tsc typescript-language-server python3; do
      command -v "$tool" >/dev/null || { echo "missing language tool: $tool"; exit 1; }
    done

    # D6: the toolchain that has `machines` must be the one on PATH.
    devenv --version | grep -q '2\.4\.0' || {
      echo "wrong devenv on PATH: $(command -v devenv) $(devenv --version 2>&1)"
      exit 1
    }

    echo "shell layer ok"
  '';

  # carapace's nu completer is generated, not copied: `devenv shell` prints it
  # through this script so no stale snippet is checked into the repo.
  scripts.carapace-nu.exec = ''
    ${carapace} _carapace nushell
  '';

  # THE NU HOOK, GENERATED RATHER THAN CHECKED IN.
  #
  # Measured in the pinned source (`nix/workspace.nix:209-210`): devenv installs
  # its own nu hook at `$out/share/nushell/vendor/autoload/devenv.nu`, and
  # `devenv hook nu` prints the same text. nushell loads that path when the
  # `devenv` PACKAGE is on its vendor autoload search path — which is a property
  # of how devenv is installed, not of this config.
  #
  # This script is here so the hook is one command away when that path does not
  # line up:
  #   devenv-hook-nu | save --force ($nu.default-config-dir | path join autoload/devenv-hook.nu)
  #
  # OPEN (fog item 24): whether `bin/devenv`'s install already puts that
  # directory on nushell's search path on this workstation. It is only
  # observable once the shell is realised, so it is not guessed at here.
  #
  # D6: it calls the repo's OWN wrapper, not bare `devenv`. On this workstation
  # bare `devenv` is the profile's 2.2.2, which has no `machines` and a
  # different hook generator.
  scripts.devenv-hook-nu.exec = ''
    ${config.devenv.root}/bin/devenv hook nu
  '';
}