# Tasks: reconcile-netcup-install-spec

Every task below is local. **No task contacts the host, the Nix store, or the
vault**, so no eval-or-check gate has to pass before any of them; the scope
proof in 3.3 is what keeps it that way.

## 1. Re-establish the contradiction (read-only)

- [x] 1.1 Record the stale requirement and its unmeetable precondition:
      `grep -n "requires no vault session" openspec/specs/netcup-install/spec.md`
      (line 52) and
      `grep -n 'no `secretspec.toml` in the repository' openspec/specs/netcup-install/spec.md`
      (line 63). Both must match *before* 4.1 touches the file — this is the
      evidence the change exists rather than being speculative.
      **Verified: 52 and 63, both matched.**
- [x] 1.2 Record that install resolves a secret by design:
      `grep -n "install.secrets" devenv.nix` (line 81,
      `secret = "TS_AUTH_KEY"`) and
      `grep -n "^TS_AUTH_KEY" secretspec.toml` (line 78).
      **Verified: devenv.nix:81 maps the path, secretspec.toml:78 declares the
      secret.**
- [x] 1.3 Record that `add-netcup-tailnet` modified only `netcup-machine`:
      `grep -n "Modified Capabilities" -A6 openspec/changes/archive/2026-09-27-add-netcup-tailnet/proposal.md`
      lists no `netcup-install` entry.
      **Verified: proposal.md:102-108 names `netcup-machine` alone.**
- [x] 1.4 Confirm the toolchain `design.md` cites:
      `./bin/devenv --version` → `devenv 2.4.0+b904dcb (x86_64-linux)` and
      `/nix/store/axhrys71dyh0l7gynicv8mfy9y9mjc4i-devenv-wrapped-2.4.0/bin/secretspec --version`
      → `secretspec 0.21.0`. Never bare `secretspec` — `PATH` carries 0.20.0
      (design R5).
      **Verified: both as cited, and bare `secretspec` reported 0.20.0.**

## 2. Write the delta

- [x] 2.1 `specs/netcup-install/spec.md` opens with `## ADDED Requirements`
      carrying *The install path resolves the repository's SecretSpec profile
      and needs no overlay membership* and its three scenarios —
      `grep -c "^#### Scenario:" openspec/changes/reconcile-netcup-install-spec/specs/netcup-install/spec.md`
      → ≥ 5 (3 added + 2 retired), and every scenario line starts with exactly
      `#### Scenario:` (three `#` fails silently).
      **Verified: 5 scenarios, all `####`; line 1 is `## ADDED Requirements`,
      `## REMOVED Requirements` at line 42.**
- [x] 2.2 The `## REMOVED Requirements` block reproduces the canonical
      requirement byte-for-byte before its `**Reason**:` —
      `grep -c "^### Requirement: The install path requires no vault session and no tailnet$" openspec/changes/reconcile-netcup-install-spec/specs/netcup-install/spec.md`
      → 1, and both original scenarios appear under it. The archive's
      header/scenario match is the strict gate here: it refuses to drop a
      scenario implicitly (recorded in `add-netcup-tailnet`'s tasks note).
      **Verified: header count 1; `diff` of the removed block against
      `sed -n '52,70p' openspec/specs/netcup-install/spec.md` → identical.**
- [x] 2.3 The delta names no behavior `netcup-tailnet` already owns (design D3):
      `grep -n "ConditionPathExists\|mode.*0600\|authKeyFile" openspec/changes/reconcile-netcup-install-spec/specs/netcup-install/spec.md`
      → no matches; those live in `openspec/specs/netcup-tailnet/spec.md`.
      **Verified: no matches.**

## 3. Validate scope

- [x] 3.1 `openspec validate reconcile-netcup-install-spec --strict` exits 0 —
      the gate `openspec/config.yaml` requires ("specs before code … lands with
      `openspec validate`").
      **Verified: "Change 'reconcile-netcup-install-spec' is valid", exit 0.**
- [x] 3.2 `openspec status --change reconcile-netcup-install-spec --json` shows
      every id in `applyRequires` with `status: "done"`.
      **Verified: `applyRequires: ["tasks"]`; proposal/design/specs/tasks all
      `done`.**
- [x] 3.3 Prove the change touches no configuration:
      `git diff --exit-code devenv.nix secretspec.toml devenv.yaml hosts scripts bin`
      exits 0, and `git status --porcelain` lists only `docs/handoff-followups.md`
      and `openspec/changes/reconcile-netcup-install-spec/`.
      **Verified with one deviation, recorded rather than smoothed over: the
      config `git diff` exits 0 (the assertion that matters), but
      `git status --porcelain` also lists `.opencode/commands/opsx-*.md`
      (staged, pre-existing — not created by this change) and an untracked
      0-byte `export` that predates this session. Neither is configuration; the
      tasks file's prediction of an exact porcelain list was too strict.**

## 4. Canonical metadata

- [x] 4.1 Replace the `Purpose` TBD line in
      `openspec/specs/netcup-install/spec.md` with the capability's real purpose
      (design D5) — verify: `grep -c "TBD - created by archiving" openspec/specs/netcup-install/spec.md`
      → 0, and `git diff --unified=0 openspec/specs/netcup-install/spec.md`
      shows exactly one hunk: the Purpose header, no requirement text changed.
      **Verified: count 0; diff is `@@ -4 +4,8 @@` — the Purpose line only.**
- [x] 4.2 The canonical specs still validate after that edit:
      `openspec validate --specs --strict` exits 0.
      **Verified: 6 passed, 0 failed.**

## 5. Archive and record

- [x] 5.1 `openspec archive reconcile-netcup-install-spec --yes` — verify:
      `grep -c "requires no vault session" openspec/specs/netcup-install/spec.md`
      → 0, and
      `grep -c "resolves the repository's SecretSpec profile" openspec/specs/netcup-install/spec.md`
      → ≥ 1, and the `Purpose` line is still present (archive merges; design D5).
      **Verified: 0 / 1 / Purpose still present. Archive report: `+ 1 added,
      - 1 removed, ~ 0 modified`, archived as
      `2026-09-28-reconcile-netcup-install-spec`. Two non-blocking warnings
      recorded for next time: proposal `Why` exceeded 1000 characters, and
      3 incomplete tasks (these three) — expected, since they are the archive
      tasks themselves.**
- [x] 5.2 `openspec validate --all --strict` exits 0 with every capability valid
      (the previous archive reported "5/5 specs valid"; this one covers the same
      set plus the corrected `netcup-install`).
      **Verified: 6 passed, 0 failed — all six capabilities, the change no
      longer listed because it is archived.**
- [x] 5.3 Mark ledger #1 complete in `docs/handoff-followups.md` §10 and leave
      the row pointing at this change's archive path — verify:
      `grep -n "reconcile-netcup-install-spec" docs/handoff-followups.md`
      shows the ledger row and the §10 reference updated.
      **Verified: ledger row #1 now reads DONE with the archive path, and §10's
      intro and contradiction paragraph name the archived change.**
