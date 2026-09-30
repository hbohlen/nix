# TypeSafe Jev as a dsh plugin

Status: research complete, recommendation made, nothing installed.
Measured 2026-09-30 on the workstation, dsh 0.1.7-rc.2, profile `web`.
Sources fetched 2026-09-30. Confidence tiers per `why/references/epistemics.md`:
**Direct** = the source states it, **Supported** = converging indirect evidence,
**Inferred** = my reading, **Unknown** = searched and not found.

## Errata (2026-09-30, adversarial re-verification)

Every claim below was re-checked against its primary source after this report was
written. The body is left as written; these corrections supersede it.

1. **Rate limits are wrong in the body and in the Budget section.** Correct values
   are **250,000 tokens per second / 1,200 requests per minute** ([models.md](https://docs.typesafe.ai/models.md)),
   not "100k tokens/sec and 40 req/sec". That is roughly 30x the request headroom
   assumed below, so the hot-path risk in Option C is overstated in magnitude
   (the shared-limit argument itself still holds). The "adjusting dynamically,
   can change without notice" wording is correct.
2. **The cancellation bug is worse than described, and one mitigation is
   insufficient.** A maintainer comment (2026-09-25) reproduces the crash *with
   the SDK's own timeout, no caller signal involved*: "the per-attempt `timeout`
   firing while the response body is still arriving is enough" (Node 22.22.2,
   `@typesafe-ai/sdk@0.6.0`, `client.ts:421`). The SDK default per-attempt timeout
   is 10s, so **internal aborts can kill the host even when the cancellation
   signal is never forwarded**. "Do not forward the cancellation signal" is
   therefore not a valid mitigation; issuing the POST with plain `fetch` is.
   The issue remains **open** with no shipped fix (a fix branch exists but the
   author hit a CreatePullRequest permission error), so "once the bug is settled"
   has no timeline. Independent corroboration: `@jkudish/jev-mcp` states its
   direct-fetch path "avoids the SDK cancellation crash (typesafe-sdk-js#2)".
3. **The SDK surface is not "one method plus three builders."** `TypeSafeClient`
   also exposes `readonly models: Models` with `list(): APIPromise<ModelCard[]>`.
   Everything else in that row is exact.
4. **`jev_triage` reads host files.** Its npm description says "a many-item triage
   with server-side file reads"; the tarball contains `node:fs` / `readFileSync`.
   The Egress section below accounts only for agent output and repo content — the
   triage tool can pull arbitrary readable host files into `state`. This is a
   standalone reason to prefer a self-owned tool over mounting `jev-mcp`.
5. **Jaggedness lists nine failure modes, not five.** The body omits **#7
   contradictory instructions and criteria, #8 common-sense structural
   invariants, #9 generation**. The language warning is not on that page at all;
   it belongs to [models.md](https://docs.typesafe.ai/models.md). The page is
   stamped "Applies to `jev-1.13`. Last reviewed 2026-09-17." Note #8: "don't
   carry a threshold tuned on a Noul over to a Choice" — which undercuts the
   "tuned confidence thresholds" framing below and argues for returning raw
   probabilities instead.
6. **The batching numbers need a caveat.** 12.2x cheaper is solid; the 10.0x
   latency figure sums *sequential* single calls, and the cookbook itself says
   "Fire them concurrently and the gap shrinks, but the 13x token cost stays."
   Both were measured on `jev-1.12`, not `jev-1.13.0`.
7. **`templates/mcp/` is not in [typesafe-ai/skills](https://github.com/typesafe-ai/skills).**
   The full recursive tree is 9 entries with exactly one `SKILL.md`; there is no
   `templates/` directory. The Sources section attributes it to an installed
   `cordis-plugin-development` skill, which does not exist on this machine.
8. **Minor omissions:** `529 Overloaded` is a documented status the SDK retries
   via 5xx (the Errors row never mentions it). A Score takes 2–10 levels and
   `instructions` accepts string, object, or array — both relevant to tool-schema
   design.

## Decision

Integrate Jev as a **judgment tool the agent calls**, not as a model. Ship it as a
`dsh-mcp-client` bundle first (two YAML/JSON files, no code), then replace the
bridge with a native Host plugin once the Node cancellation bug below is settled.

Jev cannot be dsh's model. TypeSafe's own docs say so in one sentence: "Jev is
**not** a drop-in replacement for the LLM behind Claude Code, Cursor, opencode,
Copilot" and "There is no `model: "jev-latest"` setting that turns your coding
agent into a Jev-powered agent" ([coding-agents](https://docs.typesafe.ai/introduction/coding-agents.md)).
**Direct.** That closes off the `llm-pi-ai.providers` route in
[dsh/settings.yaml](../../dsh/settings.yaml): Jev does not speak chat-completions,
so it cannot sit beside `deepseek` or `opencode-go`. What it replaces is the
prompt-and-parse step, not the assistant.

What Jev actually is: a System One decision model. You POST a `state` (text or
JSON) plus a map of typed questions, and get back typed answers with calibrated
probabilities. Three question types: `noul` (probability a statement is true),
`choice` (one option from a set you define, full distribution), `score`
(probability-weighted position on a rubric you define). ([API reference](https://docs.typesafe.ai/api.md), [primitives index](https://docs.typesafe.ai/llms.txt)) **Direct.**

Why that is worth wiring into an agent runtime: the calls are cheap and fast
enough to run on every candidate. Price is $42 per billion input tokens with free
output ($0.042/Mtok), so a 20k-token state costs well under a cent
([models](https://docs.typesafe.ai/models.md)). **Direct.** A TypeSafe cookbook
measures batching 13 questions into one call as 12.2x cheaper and 10.0x faster
with no change in answers ([parallel questions](https://docs.typesafe.ai/cookbooks/parallel_questions.md)). **Direct, their measurement, not mine.** The job
shape this fits is the one agents already fan out by hand: classify a batch,
rerank retrieval hits, check a claim against its source, gate a "tests pass"
claim on evidence.

## Contract, measured first-hand

| Item | Value | Source |
|---|---|---|
| Endpoint | `POST https://api.typesafe.ai/v1/systemone` | [api.md](https://docs.typesafe.ai/api.md) |
| Auth | `Authorization: Bearer <key>`, env name `TYPESAFE_API_KEY` | api.md, SDK `ENV` map |
| Models | `GET /v1/models`; alias `jev-latest` → `jev-1.13.0`, `jev-preview` → same today | [models.md](https://docs.typesafe.ai/models.md) |
| Limits | 100k tokens/sec, 40 req/sec, "adjusting dynamically", can change without notice | models.md |
| Context | 64k per request; 32k for state plus the longest question; max 255 choice options | models.md, api.md |
| Input | text only, no image/audio/video; English best, CJK weaker | models.md |
| Learning | not fine-tuned per account, same weights for every customer, not trained on customer requests | models.md |
| npm | `@typesafe-ai/sdk@0.6.0`, 2026-09-15, MIT, **zero runtime deps**, Node >= 20, ESM+CJS+`.d.ts` | registry JSON + unpacked tarball |
| Errors | typed classes, retry defaults `maxRetries: 2` on 408/429/5xx, honours `retry-after` | SDK `index.d.mts` |

Unauthenticated probes from this host both reached the service, which confirms
egress works from the dsh network position: `POST /v1/systemone` and
`GET /v1/models` each returned `401` with
`{"detail":{"error_type":"authentication_error",...}}`. Measured, not quoted.

The SDK surface is one method plus three question builders
(`TypeSafeClient.systemOne()`, `noul()`, `choice()`, `score()`), quoted from the
published `dist/index.d.mts`. No streaming, no tool calling, no chat semantics.

## Two constraints that decide the design

**1. The SDK can kill the dsh host process on this Node.** [typesafe-sdk-js#2](https://github.com/typesafe-ai/typesafe-sdk-js/issues/2)
is **open** (filed 2026-09-16). Cancelling a `systemOne` call after response
headers arrive terminates Node with an unhandled native `AbortError` on Node
20.20.2 and 22.23.1; it passes on 24.21.0. Our declared instance runs the pinned
upstream Node 22.23.1 ([modules/dsh.nix](../../modules/dsh.nix#L94-L108)), which
is inside the affected set, and dsh tool calls are cancellable by design. So a
native plugin must either not forward the cancellation signal to the SDK, do the
one POST itself with plain `fetch`, or move the host to upstream Node 24.
**Direct** (the issue), and the consequence is **Inferred**.

**2. Ambient secrets are scrubbed from stdio children.** `dsh-mcp-client` builds
the child environment from `scrubbedParentEnv()`, which drops ambient names
matching `/KEY|PASSWORD|SECRET|TOKEN/i`, then merges the entry's `env` on top
(`/nix/store/54w6kag4km3mgdj11zrviy59rnhw647b-dsh-0.1.7-rc.2/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-mcp-client/README.md`,
"Environment scrubbing (stdio)"). **Direct.**
A `TYPESAFE_API_KEY` sitting in the host environment therefore never reaches
`jev-mcp` unless the patch names it explicitly.

## Options considered

| Option | Shape | What you get | What it costs | Verdict |
|---|---|---|---|---|
| **A. MCP bundle** | config-only bundle: `package.json` + `cordis.patch.yml` inserting `@deepseek-ai/dsh-mcp-client`, `transport: stdio`, `command: npx -y jev-mcp` | 6 typed tools as `mcp__jev__*` (`jev_classify`, `jev_score`, `jev_check`, `jev_ask`, `jev_triage`, `jev_models`), no code owned | extra child process, cold `npx` needs npm registry reachability at boot, tool count grows, third party owns the descriptions | **Ship first.** Crash blast radius is a child, not the host |
| **B. Native plugin** | `@hbohlen/dsh-jev` Host plugin, `ctx.tools.register(defineTool(...))`, one tool over the SDK or plain `fetch` | typed canonical values, native card via `presentResult`, one round trip per judgment, cost/latency policy in one place | we own it, and the Node cancellation bug sits in the call path | **Second step**, after A proves the agent uses it |
| **C. Decision layer** | plugin taps `tools/pre-execute` and turns a high-risk call into `ask` instead of `deny` | runs on every call at sub-cent cost, invisible in the context window | Jev's own docs list "adversarial content" as a known failure mode of `jev-1.13` ([jaggedness](https://docs.typesafe.ai/model-jaggedness/jev-1.13.md)) **Direct** | **Do not use as a security gate.** Advisory at most, later |
| **D. Vendor skill** | drop [typesafe-ai/skills](https://github.com/typesafe-ai/skills) `SKILL.md` in `.agents/skills/` | teaches the agent to write Jev-powered code, live docs first | no runtime capability, it is authoring guidance | **Free, do it now** |

Option A is a plugin in the sense the harness means: the skill's own
`templates/mcp/` is exactly these two files, and `@deepseek-ai/dsh-mcp-client` is
a shipped package, so the bundle declares no dependency on it. I verified the
stdio path end to end here rather than assuming it: a JSON-RPC `initialize` plus
`tools/list` against `npx -y jev-mcp` returned
`SERVER_INFO {"name":"jev","version":"0.5.1"} PROTOCOL 2025-06-18` and
`TOOL_COUNT 6`. The first attempt read 0 bytes because a cold `npx` install took
longer than my 9s window, which is itself the answer to the boot-latency
question: **expect a registry fetch on the first launch**. Measured here
(`.scratch/jev-probe/`, npm cache 47 MiB after warm-up).

Note the harness does not mount any MCP server today: the live profile bundles
are `dsh-base`, `dsh-web-app`, `@hbohlen/remote-settings`, `dsh-opencode-session`
([profile package.json](../../dsh/.dsh/profiles/web/package.json)) and neither
shipped patch inserts `dsh-mcp-client`. Option A adds the first one.

## Recommended next step

Stage 1, one file pair under `dsh/plugins/jev/`, following the in-tree convention
of [dsh/plugins/remote-settings](../../dsh/plugins/remote-settings):

```jsonc
// package.json  — config-only bundle, no entry files
{
  "name": "@hbohlen/jev-mcp",
  "version": "0.1.0",
  "private": true,
  "dsh": { "bundle": { "patch": "./cordis.patch.yml" } }
}
```

```yaml
# cordis.patch.yml — constraint 2 is why `env` is explicit
- insert:
    - id: mcp-jev
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: jev
        transport: stdio
        command: npx
        args: ['-y', 'jev-mcp@0.5.1']
        env:
          TYPESAFE_API_KEY: !!js process.env.TYPESAFE_API_KEY
        failOnStartupError: false
        toolCallTimeoutMs: 30000
```

Two calls to make it live: `plugin_manager` `install_bundle` with that directory
as `target` (it writes the profile `package.json` and patch for you; the skill
forbids hand-writing them), then ask the agent to call `mcp__jev__jev_models`.
That tool exists precisely to confirm the key works. Restart is the safe path for
the stdio spawn even though `app-boot/config-reload` exists, because the MCP
child starts at activation.

Then, in the same repo commit, mirror the pattern the instance already uses for
its other two plugins: pin the package in
[modules/dsh.nix](../../modules/dsh.nix) and add the bundle to `profilePackageJson`
so a fresh host seeds it instead of depending on `npx` reaching the registry at
boot. `dsh-opencode-session` is the worked example, fetched as a tarball and
unpacked by `seedHome`. Pin `jev-mcp@0.5.1`, do not float it: its tool set is
what your session history and permission rules name.

Stage 2, the native plugin, is what turns this into a dsh feature rather than a
mounted binary. It needs one decision first: forward the abort signal and accept
the process-kill risk, or issue the POST with plain `fetch` and skip the SDK.
`@typesafe-ai/sdk` has zero dependencies, so vendoring it into a store path is
cheap either way, and I confirmed Node resolves a `<plugin>/node_modules/<pkg>`
layout from both a real directory and a symlinked one.

## Data and cost limits the operator owns

- **Egress.** Every judgment sends its `state` to `api.typesafe.ai`. TypeSafe
  states Jev is not trained on customer requests or responses, with zero data
  retention available on enterprise plans ([models.md](https://docs.typesafe.ai/models.md)). **Direct.** For this deployment that means agent output and repo content
  leave the tailnet when the agent calls Jev. Deciding what may be sent is a
  product call, not a technical one.
- **Budget.** 40 req/sec and 100k tokens/sec are shared account limits, and the
  vendor says they move without notice. A hot-path use (Option C, every tool
  call) can exhaust them and turn the feature into a 429 source.
- **Model pinning.** Aliases move when a new release ships, so tuned confidence
  thresholds can shift under you. The response's `model` field reports the
  versioned id that answered; pin `jev-1.13.0` if you threshold on it. **Direct.**
- **Where the key lives.** No `TYPESAFE_API_KEY`, `JEV_*` or `~/.config/typesafe/key`
  exists on this machine (checked). The instance reads credentials from the
  environment or `$DSH_HOME/.env` ([dsh/README.md](../../dsh/README.md)), so the
  key goes there, never in `settings.yaml`, which is seeded and committed.

## What we don't know

- **No official TypeSafe MCP server or hosted endpoint.** I grepped the complete
  documentation index at [docs.typesafe.ai/llms.txt](https://docs.typesafe.ai/llms.txt) for
  `mcp`, `gateway`, `integration`: no match, and the index lists an HTTP API, two
  SDKs, patterns, cookbooks, and an agent skill. So the MCP servers are all
  third-party (`jev-mcp` from rashedInt32, `@jkudish/jev-mcp`, `@maximem/jev-mcp`,
  `jev-eval-mcp` from BYK, all published 2026-09-17 through 2026-09-29). A
  missing index entry does not prove none exists behind a signup wall; resolving
  it means asking TypeSafe or checking their console.
- **Gateway equivalence is unverified.** OpenRouter serves `typesafe/jev-1.13`
  through a different route (`POST /api/alpha/decisions`, billed to your
  OpenRouter key, [docs](https://openrouter.ai/docs/guides/community/jev)), and
  `@jkudish/jev-mcp` adds Cloudflare Workers AI and Vercel AI Gateway carriers
  selected by env. I did not test any of them, so "one key, any carrier" is their
  claim. If the operator would rather not open a second vendor account,
  `OPENROUTER_API_KEY` with `JEV_PROVIDER=openrouter` is the candidate answer.
- **Quality on our content is unknown.** The vendor's jaggedness page lists
  literal reading, numeric and date work, indirection, oversized irrelevant
  state, and adversarial content as `jev-1.13` failure modes, and warns English
  accuracy beats other languages. None of that is measured against this repo's
  agent traffic. A stage-1 session that runs a few real judgments is what
  resolves it.

## Sources

Vendor primary: [API reference](https://docs.typesafe.ai/api.md) ·
[models and limits](https://docs.typesafe.ai/models.md) ·
[coding-agent guidance](https://docs.typesafe.ai/introduction/coding-agents.md) ·
[primitives](https://docs.typesafe.ai/primitives.md) ·
[jaggedness](https://docs.typesafe.ai/model-jaggedness/jev-1.13.md) ·
[agent skill](https://docs.typesafe.ai/agent-skill.md) ·
[SDK package](https://docs.typesafe.ai/sdk/javascript.md) ·
[TypeSafe skills repo](https://github.com/typesafe-ai/skills) ·
[typesafe-ai/sdk@0.6.0 tarball and `dist/index.d.mts`](https://registry.npmjs.org/@typesafe-ai/sdk)
Third-party bridges: [rashedInt32/jev-mcp](https://github.com/rashedInt32/jev-mcp) ·
[jkudish/jev-mcp](https://github.com/jkudish/jev-mcp) ·
[SDK cancellation issue](https://github.com/typesafe-ai/typesafe-sdk-js/issues/2) ·
[OpenRouter Jev hub](https://openrouter.ai/docs/guides/community/jev)
Harness side: `@deepseek-ai/dsh-mcp-client` README and `lib/types/index.d.ts`
(transports, scrubbing, `serverName` contract) · `@deepseek-ai/dsh-tools` README
`defineTool` example · `dsh-tools/lib/types/schema.d.ts` `DefineToolOptions` ·
installed `cordis-plugin-development` skill (`references/mcp-bundle.md`,
`references/host-plugin.md`, `templates/mcp/`) ·
[modules/dsh.nix](../../modules/dsh.nix) · [dsh/README.md](../../dsh/README.md)
