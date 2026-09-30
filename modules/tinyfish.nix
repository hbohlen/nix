# modules/tinyfish.nix — the TinyFish CLI (`tinyfish`), for the shell layer.
#
# WHY THE SHELL LAYER AND NOT THE MACHINE LAYER (D51, D17). CONTEXT.md's
# machine-layer entry is explicit: netcup's Home Manager role installs the
# operator's `devenv` CLI and "other development tools stay in the shell
# layer". hosts/netcup/cli.nix is CLI-only for that reason, and `tinyfish` is
# not `devenv` — so it is a shell row: active while the project is entered,
# gone when it exits, on every machine the shell layer runs on.
#
# WHY A NEW MODULE RATHER THAN A ROW IN tooling.nix OR agents.nix (D25). Both
# existing modules name their source in their own headers: modules/tooling.nix
# is the non-agent tools from the LOCKED nixpkgs, modules/agents.nix is the
# agent CLIs from the pinned `llm-agents` input. `tinyfish` is neither. There
# is no `tinyfish` in nixpkgs — measured, `nix eval nixpkgs#tinyfish.name`
# answers "Did you mean tinymist, tinyssh or tunefish?" — and none in
# `llm-agents` either (its 205 published packages do not include it, unlike
# `hermes-agent`, `herdr` and the rest of modules/agents.nix). It is a THIRD
# source: a package published to the npm registry. Filing it under either
# existing module would make that module's header false, which is the failure
# the headers exist to prevent. D25's source rule is per-tool and names two
# sources plus `openspec` as an exception; this is a third, so it gets a file
# that says so rather than an exception smuggled into someone else's group.
#
# WHY THE PACKAGE HAS TO BE BUILT AT ALL. `@tiny-fish/cli` is published to the
# npm registry and nowhere else, so the derivation fetches that tarball
# directly and builds it with `buildNpmPackage`.
#
# WHY THE TARBALL AND NOT A GIT CHECKOUT. Upstream publishes `dist/` already
# compiled (`"files": ["dist/", "skill/", "README.md", "LICENSE"]`), so there
# is nothing to build: `dontNpmBuild` skips the package's `tsc` script, which
# could not run anyway because `typescript` is a devDependency. Fetching the
# published artefact also means the thing we install is byte-for-byte the thing
# `npm install -g` would have installed.
#
# WHY A VENDORED LOCKFILE. The published tarball ships NO package-lock.json —
# `tar tzf cli-0.47.0.tgz` lists `dist/`, `skill/`, `package.json`, `README.md`
# and nothing else — and `fetchNpmDeps` refuses a source without one:
#
#   ERROR: No lock file!
#   package-lock.json or npm-shrinkwrap.json is required to make sure
#   that npmDepsHash doesn't change when packages are updated on npm.
#
# Without it every build would re-resolve the semver ranges in package.json
# against whatever npm has that day, so the dependency set — and npmDepsHash —
# would drift for reasons nothing in this repository records.
# ./tinyfish/package-lock.json was generated once from THIS version's
# package.json (`npm install --package-lock-only`) and is committed.
#
# THE LOCKFILE CARRIES DEV DEPENDENCIES TOO, AND THAT IS NOT TRIMABLE.
# npm resolves the whole tree: the vendored file holds 179 package entries
# (vitest, vite, rollup, esbuild, oxlint, typescript, …) of which only seven
# are runtime dependencies. `npm install --package-lock-only --omit=dev`
# produces a byte-identical file — npm's `--omit` affects INSTALLING, not the
# lockfile's contents — and hand-pruning the dev entries would break the build,
# because npmConfigHook runs `npm ci`, which refuses a lockfile that does not
# satisfy package.json. The cost is confined to the dependency fetch:
# npmInstallHook runs `npm prune --omit=dev` before copying, so none of it
# reaches $out.
#
# `postPatch` is the mechanism, and it is not obvious: buildNpmPackage passes
# `postPatch` down to its default `npmDeps` fetchNpmDeps call as well as running
# it in the build, so this one line places the same bytes in front of both. That
# matters because npmConfigHook diffs the two lockfiles and fails the build if
# they differ.
{ pkgs, lib, ... }:

let
  version = "0.47.0";

  # A HARD REQUIREMENT OF THE PACKAGE, not a preference: its package.json
  # declares `"engines": { "node": ">=24.0.0" }`. The locked nixpkgs carries
  # nodejs_24 = 24.20.0.
  nodejs = pkgs.nodejs_24;

  tinyfish = pkgs.buildNpmPackage {
    pname = "tinyfish";
    inherit version nodejs;

    # The published tarball, pinned by hash. npm never rewrites a published
    # version, so this hash is stable for 0.47.0 and only changes when `version`
    # above does.
    #   sha256sum 91497bfaabb9f1d22a48d2ab0c3b738de1d6c32f91a38d9011c54efc3494457b
    src = pkgs.fetchurl {
      url = "https://registry.npmjs.org/@tiny-fish/cli/-/cli-${version}.tgz";
      hash = "sha256-kUl7+qu58dIqSNKrDDtzjeHWwy+Ro42QEcVO/DSURXs=";
    };

    postPatch = ''
      cp ${./tinyfish/package-lock.json} package-lock.json
    '';

    npmDepsHash = "sha256-dMLpOVGOoeNJIx5QLdq0tWv7srSOHB80fTuXyRWSPtM=";

    # dist/ is pre-compiled; the package's `build` script is `tsc`, and
    # typescript is a devDependency that never reaches $out.
    dontNpmBuild = true;

    # The published entry point starts with `#!/usr/bin/env node`. nodejs's own
    # install hook writes $out/bin/tinyfish as a bash wrapper, and this rewrites
    # any remaining `env node` shebang to the absolute store path of the
    # interpreter this derivation was built against — so the binary is
    # self-contained and does not depend on a `node` on the caller's PATH.
    postInstall = ''
      patchShebangs $out
    '';

    meta = {
      description = "TinyFish CLI — run web automations from your terminal";
      homepage = "https://docs.tinyfish.ai/cli";
      mainProgram = "tinyfish";
      platforms = [ "x86_64-linux" ];
    };
  };
in
{
  # `nodejs` is deliberately NOT in this list. Nothing here needs it on PATH
  # once the shebang above is absolute, and an `npm` on PATH would only make
  # `tinyfish upgrade` fail later with a read-only-store error instead of
  # failing immediately with a missing command. Upgrading is a version bump in
  # this file, never `tinyfish upgrade`: read from the published
  # dist/lib/cli-install.js, that command runs `npm install --global`, which
  # cannot work against the store.
  packages = [ tinyfish ];
}