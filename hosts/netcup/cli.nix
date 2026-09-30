# Home Manager has no automatic rollback, so keep this role CLI-only.
{
  pkgs,
  inputs,
  ...
}:

let
  system = pkgs.stdenv.hostPlatform.system;

  # The `?dir=src/modules` input has no package output. Read the root flake by
  # its locked NAR hash to keep the CLI on the module input's exact source.
  # `sourceInfo` and `narHash` are upstream metadata rather than a public API.
  devenvPackage =
    let
      devenvInput =
        inputs.devenv
        or (throw "The devenv input is required for the host's devenv package");
      fullDevenvInput =
        if devenvInput ? packages then
          devenvInput
        else if devenvInput ? sourceInfo && devenvInput.sourceInfo ? outPath then
          let
            sourceInfo =
              if devenvInput.sourceInfo ? narHash then
                devenvInput.sourceInfo
              else
                builtins.fetchTree {
                  type = "path";
                  path = devenvInput.sourceInfo.outPath;
                };
          in
          builtins.getFlake (
            builtins.unsafeDiscardStringContext "path:${sourceInfo.outPath}?narHash=${sourceInfo.narHash}"
          )
        else
          throw "The devenv input does not expose packages or locked source metadata";
    in
    fullDevenvInput.packages.${system}.devenv
    or (throw "The devenv input does not provide a devenv package for ${system}");
in
{
  home.username = "hbohlen";
  home.homeDirectory = "/home/hbohlen";

  home.stateVersion = "26.11";

  # `doppler` is OPERATOR CONVENIENCE, NOT A PRECONDITION (ADR 0013). SecretSpec's
  # Doppler provider talks to `https://api.doppler.com` over REST — "No `doppler`
  # CLI is required" — so removing this package cannot break resolution on this
  # host. What it buys is the way to read the store by hand: the token dashboard,
  # `doppler activity`, and creating or rotating a config-scoped service token
  # without carrying a laptop through it.
  #
  # The token itself is NOT here. `~/.config/doppler-token` is placed by the
  # operator, never by this role and never by SecretSpec: the provider's own
  # credential cannot be resolved through that provider (the circularity the
  # Token-file entry in CONTEXT.md records).
  home.packages = [
    pkgs.mosh
    pkgs.doppler
  ];

  programs.devenv = {
    enable = true;
    package = devenvPackage;
    enableBashIntegration = false;
    enableFishIntegration = false;
    enableNushellIntegration = false;
    enableZshIntegration = false;
  };
}
