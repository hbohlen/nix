> Provenance: consolidated from two parallel research passes (dispatcher task t_7b6bc62d + delegation sa-1-4541a9cb). This version keeps the deeper findings: the node-addon boot failure of the stock llm-agents build and the tested overrideAttrs fix, the flock/storage analysis, and the checked-against-live-state migration list.

# Digest: dsh via llm-agents.nix on this shell

Card t_7b6bc62d, measured 2026-09-29 on the workstation (x86_64-linux).
Repo: /home/hbohlen/nix (jj/git, working copy qpyqmxvx).

## Verdict

NO-GO for the plain one-line declaration `llm.dsh` in modules/agents.nix.
The package builds and substitutes, but the web profile CANNOT boot under the
Node.js the package wraps.

GO with a package override of about six lines (tested, store path below). The
override keeps dsh in modules/agents.nix, which is what D25/D30 ask for.

## Q1. Does `llm-agents.packages.dsh` build or cache-hit?

Cache hit. No compile.

- Pinned input: `llm-agents` at rev `e28ea84e78517e5d05ae0c399da00e848e207261`
  (devenv.lock, node `llm-agents`).
- Attribute: `packages.x86_64-linux.dsh` -> name `dsh-0.1.7-rc.2`,
  version `0.1.7-rc.2` (nix eval of the pinned rev).
- Store path: `/nix/store/54w6kag4km3mgdj11zrviy59rnhw647b-dsh-0.1.7-rc.2`
- Nar size 719,802,736 B; closure 686.5 MiB.
- `nix path-info --store https://cache.numtide.com` finds that path, so the
  numtide substituter served it. The workstation declares the cache in
  /etc/nix/nix.custom.conf (`extra-substituters = https://cache.numtide.com`,
  key `niks3.numtide.com-1:...`). The netcup host declares the same cache in
  hosts/netcup/self-deploy.nix.
- `/nix/store/54w6.../bin/dsh --version` prints `0.1.7-rc.2`.

## Q2. Version delta 0.1.5-rc.1 -> 0.1.7-rc.2

Release list from the GitHub API for deepseek-ai/deepseek-harness. The delta
crosses: 0.1.5-rc.2, 0.1.6-alpha.1, 0.1.6-alpha.2, 0.1.7-alpha.1,
0.1.7-alpha.2, 0.1.7-rc.1, 0.1.7-rc.2.

Breaking or migration-relevant, by release:

0.1.5-rc.2 (2026-09-10) - feedback dialog only. No state change.

0.1.6-alpha.1 (2026-09-15):
- DeepSeek default moves to the Messages protocol. Remove a manually configured
  legacy official root, or set `https://api.deepseek.com/anthropic`.
- Ralph is off by default.
- The built-in E2B execution backend is removed.
- PTC package and service names unify to the `ptc-runtime` family; old names
  are incompatible.
- Workflow executor becomes `workflow-ptc`.
- `agent/session-start` becomes the async serial `agent/created`.
- Session sync history reads `snapshotEvents`, `eventAt`, `ownEvents` are
  deprecated.
- Team mode uses `spawn_teammate`; `subagent` and `subagent_fork` close.
- Node PTC runs in a separate process; `process.env` is empty.
- Config hot reload loses transaction rollback.
- Request image cache moves to `DSH_HOME/cache/attachments/request-images`.

0.1.6-alpha.2 (2026-09-17):
- Plugin dependencies use runtime resolution; Plugin Manager supports runtime
  unloading.
- The default model list removes V4 Flash and V4 Flash Vision Exp.
- Client Sessions support multiple coexisting instances (API and slot changes).

0.1.7-alpha.1 (2026-09-22):
- Session log upgrades to V4, with a developer batch migration tool. Some V3
  sessions that lack turn-end records stay compatible.
- Attachments held only in custom events are no longer read or exported.
- The official DeepSeek adapter uses Messages only; the `protocol` option is
  removed.
- Workspace file reads unify to `readBytes`.
- Agent presets are declared and installed by plugin bundles. Old directory
  presets must migrate. The settings page drops copy/delete/open-directory.
- Settings are saved by the current Profile's plugin config. The old
  settings.yaml is imported ONCE only. Custom settings plugins must adapt.
- `--dump-config-schema` is added.

0.1.7-alpha.2 (2026-09-22):
- Custom `spill-policy` config: `maxInlineBytes` becomes `maxInlineTokens`.

0.1.7-rc.1 (2026-09-23):
- Session held by another DSH instance: the UI asks the user to exit that
  instance and retry.
- A new blank session no longer reuses existing history or gets occupied by
  another instance.
- Web deployment under a reverse-proxy SUBPATH is fixed.
- Unreadable optional plugin packages no longer abort the profile load.
- Plugin install and start check compatibility with the current DSH version;
  an exact version can be granted an exception.
- Plugin bundles load several patch files in order.

0.1.7-rc.2 (2026-09-24): scheduled tasks, desktop onboarding, keyboard
shortcuts, dynamic tool additions. No state migration.

Newer than the pin, and worth noting: 0.2.0-rc.1 (2026-09-28) and 0.2.0-rc.2
(2026-09-29) exist upstream. The pinned llm-agents rev carries 0.1.7-rc.2.

### What this means for the running 3080 setup

Measured against the live state, not assumed:

- ~/.dsh/settings.yaml holds six plugin key groups: ui-onboarding, llm-pi-ai,
  agent-default-model, ui-conversation, agent-presets, ui-chat.
- It holds NO `protocol` key and no legacy official DeepSeek root. The default
  model is the `longcat` route on the `llm-pi-ai` provider with
  `api: openai-completions`. So the Messages-only change does not bite here.
  The `llm-pi-ai` row still exists in the 0.1.7-rc.2 web tree
  (`- id: llm-pi-ai`, `name: '@deepseek-ai/dsh-llm-pi-ai'`).
- The REAL migration to plan for is the settings move: settings.yaml is
  imported once by 0.1.7 and then lives in the profile's plugin config.
- ~/.dsh/.agent-presets is EMPTY, so the preset migration has nothing to move.
  The `agent-presets.default: standard` key still needs the `standard` preset
  to exist in the new bundle-declared set.
- No custom `spill-policy` and no PTC package names appear in the live state,
  so those two renames do not bite either.

## Q3. Does the Nix-built dsh keep DSH_HOME at ~/.dsh?

DSH_HOME resolution is correct, and the build carries no store-path
assumptions. The web profile does NOT work under the packaged Node.js.

DSH_HOME behaviour, measured with the store binary:

- DSH_HOME unset -> defaults to `$HOME/.dsh`. With `HOME=/tmp/probehome-a` the
  binary created `/tmp/probehome-a/.dsh/profiles/web/{package.json,cordis.yml,
  cordis.patch.yml,pnpm-workspace.yaml}`.
- `DSH_HOME=/tmp/dshprobe2` is honoured.
- The composed tree of the two runs is byte-identical (empty diff), so nothing
  in the composition depends on the store path or on HOME.
- The shipped template materializes `profiles/web` with
  `"dependencies": {}` and bundles `["@deepseek-ai/dsh-base",
  "@deepseek-ai/dsh-web-app"]`. In-box bundles need no dependency entry.

Bundle resolution, measured with a scratch home that carried the REAL
profiles/web manifest and DANGLING `@deepseek-ai/*` symlinks (the state after
mise dies):

- `@deepseek-ai/dsh-base` and `@deepseek-ai/dsh-web-app` still resolve. The
  dump succeeded (exit 0, 1248 lines) with no error.
- `dshmarket` and `@hbohlen/remote-settings` were skipped with:
  `dsh: cannot resolve profile bundle "dshmarket" from the dsh installation or
  <home>/profiles/web; run 'dsh plugin --profile web install' if its
  dependency is not installed`.
- 491 symlinks under ~/.dsh point into the mise install
  (`/home/hbohlen/.local/share/mise/installs/node/22.23.1/...`). 242 of them
  are `profiles/node_modules/@deepseek-ai/*`. ZERO are inside
  `profiles/web/node_modules`, which is pnpm-store material. So the web
  profile's own node_modules survives mise's death; only the hoisted fallback
  tree dangles. `@hbohlen/remote-settings` is a relative link to
  `~/.dsh/plugins/remote-settings`, a real directory.

remote-settings plugin under 0.1.7-rc.2, checked against the store tree:

- The plugin injects `webServer` and calls `ctx.webServer.tapIndex(...)`.
  `tapIndex` is still present in
  `@deepseek-ai/dsh-host-webserver/lib/index.js` and its type declarations.
- The shim sets `globalThis.__DSH_TRANSPORT__.ownsHost = true`. The client
  predicate is unchanged in 0.1.7-rc.2:
  `isLoopback: transport?.ownsHost === true || pageLocation === void 0 ||
  isLoopbackHostname(pageLocation.hostname)`, and the string `ownsHost` is in
  the bundled frontend `dist/assets/index-Q6zc2uHV.js`.
- Its declared peer range `@deepseek-ai/dsh-host-webserver >=0.1.0-rc.6
  <0.2.0` admits 0.1.7-rc.2.

### The blocking defect

The package boots NOTHING. `dsh web` dies at profile boot:

```
dsh: fatal uncaught exception: Error: dsh: host preparation failed:
node-addon-require-builtin unsupported: Unsupported/no-getter (x64 sysv getter
is not a recognized this->field accessor ...)
    at Object.requireBuiltin (.../node-addon-native-custom-loader/lib/index.js:559:28)
    at internalModules (.../@deepseek-ai/dsh-app-boot/lib/index.js:1575:26)
    at installRuntimeInterception (.../@deepseek-ai/dsh-app-boot/lib/index.js:1641:80)
```

Root cause, isolated:

- The wrapper runs `nodejs-24.20.0/bin/node --expose-internals .../lib/bin.js`.
- `@deepseek-ai/dsh-app-boot/lib/index.js:1574` calls
  `createRequire(import.meta.url)("node-addon-require-builtin")` and then
  `addon.requireBuiltin(...)` five times, with NO check of
  `process.execArgv` and no fallback.
- `@deepseek-ai/cordis-plugin-loader/lib/index.js:11` does check the flag
  (`if (process.execArgv.includes("--expose-internals")) try { return require(id) }`)
  and only then falls back to the addon. That is the path that works.
- `node-addon-native-custom-loader` probes the V8 layout and recognizes only
  official nodejs.org builds. Nix builds Node from source, so the probe fails.

Measured, both paths, both Node builds (a small script, run with
`--expose-internals`):

- node v24.20.0 (the package's own, nix-built):
  flag path OK, addon path FAILED with the message above.
- node v22.23.1 (mise, an official nodejs.org build):
  flag path OK, addon path OK.

End-to-end, on throwaway homes and free ports, with the live state untouched:

- Store lib under its own node 24 -> fatal boot failure (no HTTP).
- SAME store lib under the official node 22 -> boots, serves
  `http://127.0.0.1:3096/?token=...`, and a token fetch returns HTTP 200,
  34,304 bytes, `<title>DeepSeek Harness</title>`, assets 200.
- The mise-installed 0.1.5-rc.1 baseline behaves the same way under node 22.

Two negative results worth recording:

- `dsh.override { nodejs = pkgs.nodejs_22; }` is NOT a fix. That build
  (`/nix/store/8iz7l6x4sw0ijnrv8881av9qa4racmfy-dsh-0.1.7-rc.2`, wrapped
  `nodejs-22.23.3`, also nix-built) fails with the identical error.
- Changing the Node version is therefore not the lever. The Node BUILD is.

### The fix that works

Make `dsh-app-boot` use the flag path, which the wrapper already enables.
Tested expression (the same call form modules/agents.nix would use, because
`llm.dsh` is `inputs.llm-agents.packages.<system>.dsh`):

```nix
llm.dsh.overrideAttrs (old: {
  postInstall = (old.postInstall or "") + ''
    substituteInPlace \
      $out/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-app-boot/lib/index.js \
      --replace-fail \
        'const addon = createRequire(import.meta.url)("node-addon-require-builtin");' \
        'const addon = { requireBuiltin: (id) => createRequire(import.meta.url)(id) };'
  '';
})
```

Result: `/nix/store/4mghfizzljzkmpy6s2y1cx455pdcj04p-dsh-0.1.7-rc.2` builds.
It boots under its OWN wrapped node 24.20.0 and serves the real page:
launch URL printed, token fetch HTTP 200, 34,304 bytes,
`<title>DeepSeek Harness</title>`.

The same one-line change upstream (or a fixed addon) removes the need for the
override.

## Q4. Two instances, one DSH_HOME

Today both live instances share `~/.dsh`. Neither process sets DSH_HOME, so
both take the default:

- PID 1246653: `.../bin/dsh web --host 127.0.0.1 --port 3080 --no-open
  --trusted-host ...`, cwd `/home/hbohlen`, up 9h59m. The mise npm global
  0.1.5-rc.1.
- PID 63359: `node --import tsx/esm apps/cli/src/bin.ts web --port 3081
  --no-open --trusted-host dsh-dev.hbohlen.space`, cwd
  `/home/hbohlen/projects/deepseek-harness`, up 13d20h.

What the design actually guards:

- SESSION LOGS ARE SAFE. Every log read and write goes through a handle, and
  "the handle is the single door the cross-process write lease guards"
  (docs/subsystems/persistence.md). The JSONL provider takes a non-blocking
  POSIX `flock(2)` on `session.lock`
  (packages/session/session-persistence-jsonl/src/lease.ts), held until the
  handle closes or the process dies. A second instance cannot write a session
  the first holds. 0.1.6-alpha.2 added the user-facing prompt for exactly this
  case, and 0.1.7-rc.1 fixed the blank-session reuse bug around it.
- SESSION-QUERY SQLITE IS NOT SHARED. Its config is `path: ':memory:'`,
  `openAt: never` in the composed tree. No shared database file.
- THE STORAGE DOMAIN IS NOT SAFE IN PRINCIPLE. The backend is `json` with
  `root: dshHomePath('storages')` (composed tree, rows storage-json and
  storage-domain). `dsh-storage-json` publishes each changed file atomically,
  but the `single` layout "owns an in-memory unit projection" and each write
  "serializes its complete state, and atomically replaces `<unit>.json`"
  (packages/storage/storage-json/README.md). Two processes each holding a full
  projection of one unit therefore LOSE UPDATES: last writer wins for the whole
  file. The storage doc also records that cross-process change push is a known
  limitation, so one instance does not see the other's writes.

Why 13 days produced no visible damage: the shared `single`-layout units are
small and rarely written. `~/.dsh/storages/` holds only `workspace.json`
(mtime 2026-09-18) and the `session_projcache` pair. And the two instances run
from DIFFERENT working directories, so their session directories carry
different workspace keys today (`--home-hbohlen--` for 3080,
`--home-hbohlen-hbosys-projects-deepseek-harness--` for 3081). The exposure is
real but has been idle, which matches the observation.

Answer: it is safe for the session logs and unsafe for the shared storage
units. Give the dev instance its own DSH_HOME before the switchover. Do not
rely on "no visible damage yet".

## Q5. Shell declaration shape

The line that was asked for, in modules/agents.nix, beside the existing rows:

```nix
llm.dsh # `dsh`; the harness the dsh.hbohlen.space ingress serves (D25)
```

That alone is a NO-GO, per Q3. The declaration that builds AND boots is the
override in Q3.

I did NOT edit modules/agents.nix: the child card t_c5e0ec11 owns the shell
declaration and the 3080 process. I also did NOT edit
.scratch/devenv-layering/map.md, per the card.

Placement-table follow-up note (for the map owner, not applied here): the
`dsh` row moves from the mise npm global to the shell, from the pinned
`llm-agents` input, with the `dsh-app-boot` override. The mise copy then dies
with mise at D14.

## Alternatives if the override is rejected

1. Leave the mise copy until D14. It works today (official node 22). It dies
   when mise dies, and the web profile then has no runtime.
2. Pin the npm version via nodejs in tooling.nix. This does NOT avoid the
   defect: the addon needs an official nodejs.org build, and every nixpkgs Node
   is source-built. It only works if the Node is an official build, which is
   what mise provides and what nixpkgs does not.
3. An upstream fix in llm-agents.nix (or in dsh) that honours
   `--expose-internals` in dsh-app-boot. This removes the override.

## Measured facts, for reuse

- llm-agents pin: e28ea84e78517e5d05ae0c399da00e848e207261
- dsh store path: /nix/store/54w6kag4km3mgdj11zrviy59rnhw647b-dsh-0.1.7-rc.2
- patched store path: /nix/store/4mghfizzljzkmpy6s2y1cx455pdcj04p-dsh-0.1.7-rc.2
- nodejs_22 override path (fails): /nix/store/8iz7l6x4sw0ijnrv8881av9qa4racmfy-dsh-0.1.7-rc.2
- packaged Node: nodejs-24.20.0, wrapper adds `--expose-internals`
- official Node that works: /home/hbohlen/.local/share/mise/installs/node/22.23.1/bin/node
- mise dsh on PATH: 0.1.5-rc.1