# modules/languages.nix — the language runtimes the shell layer owns.
#
# D14 drops `mise` and declares the runtimes instead. D14's wording says
# `languages.node`; devenv 2.4.0 has NO such option. The Node ecosystem module
# is `languages.javascript` (measured in the pinned source,
# `src/modules/languages/javascript.nix`), and TypeScript is its own module.
# That correction is recorded in the map as D37.
#
# What replaces what:
#   mise `node`                 -> languages.javascript.package (nodejs_22)
#   mise shims npm/npx/pnpm/yarn-> languages.javascript.{npm,pnpm,yarn}
#   mise shim tsc               -> languages.typescript
#   mise shim typescript-language-server -> languages.javascript.lsp
#   mise `uv` + python          -> languages.python plus `uv` in tooling.nix
#
# The ~45 other npm globals behind the mise shims are OUT OF SCOPE by D18: they
# are personal tooling, not dependencies of anything declared here.
{ pkgs, lib, ... }:

{
  languages.javascript = {
    enable = true;
    package = pkgs.nodejs_22; # 22.23.3 in the locked nixpkgs
    npm.enable = true;
    pnpm.enable = true;
    yarn.enable = true;
    # `corepack` stays off: npm, pnpm and yarn are declared explicitly above,
    # and corepack would add a second way to reach the same three binaries.
    lsp.enable = true; # typescript-language-server
  };

  languages.typescript.enable = true;

  languages.python = {
    enable = true;
    # package defaults to pkgs.python3 (3.14.7 here). `version` is deliberately
    # NOT set: that option resolves through the `nixpkgs-python` input, which
    # this repo does not declare, and there is no reason to add one.
    venv.enable = true; # `uv venv` inside the repo, per the module's wiring
  };
}