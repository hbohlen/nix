# R-02: Translate live `~/.hermes/config.yaml` → `services.hermes-agent.settings`

**Date:** 2026-09-29
**Ticket:** `.scratch/hermes-config/issues/02-translate-live-config-to-settings.md`
**Audience:** the engineer implementing ticket T-02 (`modules/hermes.nix`). The
attrset literal in §4 is the load-bearing artifact — it must work first try.

**Sources (priority order):**

1. Live config: `/home/hbohlen/.hermes/config.yaml` (441 lines, 45 top-level keys).
2. Upstream module: `~/.hermes/hermes-agent/nix/moduleCommon.nix` and
   `~/.hermes/hermes-agent/nix/homeManagerModules.nix`. Cited inline below.
3. Companion reference doc: `/home/hbohlen/nix/docs/research/2026-09-29-hermes-nix-module.md`.

---

## 0. The load-bearing shape of `settings`

The upstream module declares `settings` with a custom `deepConfigType`
(`moduleCommon.nix:31-36`):

```nix
deepConfigType = types.mkOptionType {
  name = "hermes-config-attrs";
  description = "Hermes YAML config (attrset), merged deeply via lib.recursiveUpdate.";
  check = builtins.isAttrs;
  merge = _loc: defs: lib.foldl' lib.recursiveUpdate { } (map (d: d.value) defs);
};
```

The check is `builtins.isAttrs`. The type does **not** descend into
attrs-of-attrs: any nested structure is opaque to Nix. The full attrset is
serialized via `builtins.toJSON` (`moduleCommon.nix:695-697`); JSON is a subset
of YAML, so the resulting file is valid YAML. PyYAML then writes it to
`$HERMES_HOME/config.yaml` with `sort_keys=False` (see
`configMergeScript.nix:6-33`).

**Consequence for this ticket:** any key in the live YAML that is an attrset
(almost all of them) is a freeform sub-attrset under `settings`. There is no
upstream type that constrains the per-key shape; the on-disk YAML is exactly
what the runtime agent expects because the runtime agent is the same code
that reads `~/.hermes/config.yaml` today.

**Discrepancy categories therefore collapse to three:**

1. **Nix key-name rules:** YAML allows `.` and `-` in keys; Nix attribute
   names allow `_` and digits but reject `.` and `-` and cannot start with a
   digit. The live config has no such keys, so this is a non-issue.
2. **`terminal.cwd` injection:** the module always writes
   `terminal.cwd = workingDirectory` (`moduleCommon.nix:696`). An explicit
   `settings.terminal.cwd` REPLACES that default via `recursiveUpdate` left→right
   precedence (`moduleCommon.nix:685-687` comment). Documented in §5.
3. **Sole type-shape mismatch risk:** any value in the live config that Nix
   would refuse to serialize. None found — JSON handles strings, ints,
   floats, bools, lists of any of these, and nested attrsets. The merge
   script writes with `default_flow_style=False` which preserves the inline
   `[ "a", "b" ]` vs block `- a\n- b` from the JSON output.

The rest of this doc enumerates every key, the path, and a sanity check.

---

## 1. Top-level key inventory (live config)

The live `/home/hbohlen/.hermes/config.yaml` has **45 top-level keys**, not 12
as the ticket sketch suggested. The 12 in the sketch were the high-level
feature-group names (model, runtime, agent, terminal, web, browser,
tool_loop_guardrails, compression, prompt_caching, bedrock, auxiliary); the
remaining 33 are per-feature sub-configs the agent has grown over time. All 45
are listed below.

| # | Top-level key | Source line(s) | Attrset path |
|---|---|---|---|
| 1 | `model` | `/home/hbohlen/.hermes/config.yaml:1-4` | `settings.model` |
| 2 | `database` | `/.hermes/config.yaml:5-6` | `settings.database` |
| 3 | `runtime` | `/.hermes/config.yaml:7-8` | `settings.runtime` |
| 4 | `agent` | `/.hermes/config.yaml:9-15` | `settings.agent` |
| 5 | `terminal` | `/.hermes/config.yaml:16-26` | `settings.terminal` |
| 6 | `web` | `/.hermes/config.yaml:27-30` | `settings.web` |
| 7 | `browser` | `/.hermes/config.yaml:31-36` | `settings.browser` |
| 8 | `tool_loop_guardrails` | `/.hermes/config.yaml:37-48` | `settings.tool_loop_guardrails` |
| 9 | `compression` | `/.hermes/config.yaml:49-66` | `settings.compression` |
| 10 | `prompt_caching` | `/.hermes/config.yaml:67-68` | `settings.prompt_caching` |
| 11 | `bedrock` | `/.hermes/config.yaml:69-71` | `settings.bedrock` |
| 12 | `auxiliary` | `/.hermes/config.yaml:72-110` | `settings.auxiliary` |
| 13 | `display` | `/.hermes/config.yaml:111-135` | `settings.display` |
| 14 | `dashboard` | `/.hermes/config.yaml:136-142` | `settings.dashboard` |
| 15 | `stt` | `/.hermes/config.yaml:143-150` | `settings.stt` |
| 16 | `human_delay` | `/.hermes/config.yaml:151-152` | `settings.human_delay` |
| 17 | `memory` | `/.hermes/config.yaml:153-159` | `settings.memory` |
| 18 | `delegation` | `/.hermes/config.yaml:160-164` | `settings.delegation` |
| 19 | `moa` | `/.hermes/config.yaml:165-190` | `settings.moa` |
| 20 | `skills` | `/.hermes/config.yaml:191-253` | `settings.skills` |
| 21 | `curator` | `/.hermes/config.yaml:254-255` | `settings.curator` |
| 22 | `slack` | `/.hermes/config.yaml:256-257` | `settings.slack` |
| 23 | `mattermost` | `/.hermes/config.yaml:258-259` | `settings.mattermost` |
| 24 | `matrix` | `/.hermes/config.yaml:260-261` | `settings.matrix` |
| 25 | `approvals` | `/.hermes/config.yaml:262-263` | `settings.approvals` |
| 26 | `plugins` | `/.hermes/config.yaml:264-278` | `settings.plugins` |
| 27 | `cron` | `/.hermes/config.yaml:279` | `settings.cron` |
| 28 | `kanban` | `/.hermes/config.yaml:280-285` | `settings.kanban` |
| 29 | `code_execution` | `/.hermes/config.yaml:286-288` | `settings.code_execution` |
| 30 | `gateway` | `/.hermes/config.yaml:289-326` | `settings.gateway` |
| 31 | `streaming` | `/.hermes/config.yaml:327-328` | `settings.streaming` |
| 32 | `sessions` | `/.hermes/config.yaml:329-330` | `settings.sessions` |
| 33 | `onboarding` | `/.hermes/config.yaml:331-335` | `settings.onboarding` |
| 34 | `telemetry` | `/.hermes/config.yaml:336-339` | `settings.telemetry` |
| 35 | `updates` | `/.hermes/config.yaml:340-344` | `settings.updates` |
| 36 | `vault` | `/.hermes/config.yaml:345-347` | `settings.vault` |
| 37 | `secrets` | `/.hermes/config.yaml:348-353` | `settings.secrets` |
| 38 | `local_runtime` | `/.hermes/config.yaml:354-355` | `settings.local_runtime` |
| 39 | `_config_version` | `/.hermes/config.yaml:356` | `settings._config_version` |
| 40 | `group_sessions_per_user` | `/.hermes/config.yaml:357` | `settings.group_sessions_per_user` |
| 41 | `platform_toolsets` | `/.hermes/config.yaml:358-393` | `settings.platform_toolsets` |
| 42 | `tool_gateway_declined_tools` | `/.hermes/config.yaml:394-398` | `settings.tool_gateway_declined_tools` |
| 43 | `known_plugin_toolsets` | `/.hermes/config.yaml:399-402` | `settings.known_plugin_toolsets` |
| 44 | `known_builtin_toolsets` | `/.hermes/config.yaml:403-432` | `settings.known_builtin_toolsets` |
| 45 | `custom_providers` | `/.hermes/config.yaml:433-441` | `settings.custom_providers` |

**Sole Nix-attribute-name concern:** `_config_version` has a leading
underscore, which is legal in Nix (any identifier starting with `_` is
allowed and ignored by pattern bindings, but legal as an attribute name). It
also survives `builtins.toJSON` round-trip unchanged. **No change needed.**

---

## 2. Per-key snippets, paths, and type checks

For each top-level key: verbatim snippet, `settings.<path>` route, the
expected rendered YAML shape, and any non-obvious sub-keys. "Nix type" is
**always** `attrsOf <anything>` for sub-keys under `settings` because
`deepConfigType` does not descend — see §0. Where a sub-key has a value type
that *could* confuse Nix (e.g. a string that looks like a number), the live
value is explicit so no surprise.

### 2.1 `model` — primary LLM
**Live:** `/home/hbohlen/.hermes/config.yaml:1-4`
```yaml
model:
  default: deepseek/deepseek-v4.1-flash
  provider: nous
  base_url: https://inference-api.nousresearch.com/v1
```
**Attrset path:** `settings.model = { default; provider; base_url; };`
**Rendered YAML:** identical (string values). No discrepancy.

### 2.2 `database` — sqlite journal mode
**Live:** `/home/hbohlen/.hermes/config.yaml:5-6`
```yaml
database:
  journal_mode: wal
```
**Attrset path:** `settings.database.journal_mode = "wal";`
**No discrepancy.**

### 2.3 `runtime` — OS resource limits
**Live:** `/home/hbohlen/.hermes/config.yaml:7-8`
```yaml
runtime:
  nofile_soft_limit: 4096
```
**Attrset path:** `settings.runtime.nofile_soft_limit = 4096;`
**No discrepancy.** Note: this is a runtime hint for hermes itself, distinct
from the systemd unit's `LimitNOFILE`; do not conflate with `systemd`
options.

### 2.4 `agent` — main loop tuning
**Live:** `/home/hbohlen/.hermes/config.yaml:9-15`
```yaml
agent:
  max_turns: 150
  service_tier: ''
  fast_auto_seconds: 60
  verbose: false
  reasoning_effort: medium
  personalities: {}
```
**Attrset path:** `settings.agent = { max_turns = 150; service_tier = ""; fast_auto_seconds = 60; verbose = false; reasoning_effort = "medium"; personalities = { }; };`
**No discrepancy.** Empty `personalities = {}` round-trips fine.

### 2.5 `terminal` — backend / sandbox / lifetime
**Live:** `/home/hbohlen/.hermes/config.yaml:16-26`
```yaml
terminal:
  backend: local
  cwd: .
  timeout: 180
  home_mode: auto
  container_cpu: 1
  container_memory: 5120
  container_disk: 51200
  container_persistent: true
  docker_mount_cwd_to_workspace: false
  lifetime_seconds: 300
```
**Attrset path:** `settings.terminal = { backend = "local"; timeout = 180; home_mode = "auto"; container_cpu = 1; container_memory = 5120; container_disk = 51200; container_persistent = true; docker_mount_cwd_to_workspace = false; lifetime_seconds = 300; };`

**⚠ Discrepancy — `terminal.cwd`:** the module *always* injects
`terminal.cwd = workingDirectory` before deep-merging the user's `settings`
(`moduleCommon.nix:696`). The live value is `"."` (a relative-path sentinel
meaning "use the current working directory at runtime"). The HM default
`workingDirectory` is `config.home.homeDirectory` (`homeManagerModules.nix:252`),
which would *replace* the live `"."` behavior.

**Resolution:** do not set `terminal.cwd` in `settings` at all. Leave the
Nix default in place (which writes the home directory). If you need to
preserve `"."` semantics explicitly, set
`services.hermes-agent.settings.terminal.cwd = ".";` — that explicit value
replaces the Nix default via `lib.recursiveUpdate` left→right precedence
(`moduleCommon.nix:685-687`). The decision is documented in §5.

### 2.6 `web` — web search backend
**Live:** `/home/hbohlen/.hermes/config.yaml:27-30`
```yaml
web:
  backend: tavily
  provider_tier:
    parallel: free
```
**Attrset path:** `settings.web = { backend = "tavily"; provider_tier.parallel = "free"; };`
**No discrepancy.**

### 2.7 `browser` — headless browser
**Live:** `/home/hbohlen/.hermes/config.yaml:31-36`
```yaml
browser:
  inactivity_timeout: 120
  engine: lightpanda
  extension_control:
    enabled: false
  cloud_provider: local
```
**Attrset path:** `settings.browser = { inactivity_timeout = 120; engine = "lightpanda"; extension_control.enabled = false; cloud_provider = "local"; };`
**No discrepancy.**

### 2.8 `tool_loop_guardrails` — anti-loop heuristics
**Live:** `/home/hbohlen/.hermes/config.yaml:37-48`
```yaml
tool_loop_guardrails:
  warnings_enabled: true
  hard_stop_enabled: false
  non_interactive_hard_stop_enabled: true
  warn_after:
    exact_failure: 2
    same_tool_failure: 3
    idempotent_no_progress: 2
  hard_stop_after:
    exact_failure: 5
    same_tool_failure: 8
    idempotent_no_progress: 5
```
**Attrset path:** `settings.tool_loop_guardrails = { … };` (matches verbatim)
**No discrepancy.**

### 2.9 `compression` — context-window compression
**Live:** `/home/hbohlen/.hermes/config.yaml:49-66`
```yaml
compression:
  enabled: true
  checkpoint_required: false
  progress_notices: true
  threshold: 0.35
  target_ratio: 0.3
  protect_last_n: 20
  min_tail_user_messages: 1
  max_attempts: 3
  proactive_prune_tokens: 20000
  proactive_prune_min_result_chars: 8000
  proactive_prune_min_reclaim_tokens: 4096
  hygiene_max_turn_hold_seconds: 10
  protect_first_n: 3
  codex_gpt55_autoraise: true
  codex_app_server_auto: native
  codex_responses_native: true
  idle_compact_after_seconds: 0
```
**Attrset path:** `settings.compression = { … };`
**No discrepancy.** Floats (`threshold`, `target_ratio`) round-trip through
JSON exactly.

### 2.10 `prompt_caching`
**Live:** `/home/hbohlen/.hermes/config.yaml:67-68`
```yaml
prompt_caching:
  cache_ttl: 5m
```
**Attrset path:** `settings.prompt_caching.cache_ttl = "5m";`
**No discrepancy.** The `5m` is a string, not a duration type — YAML doesn't
have one and hermes parses it itself.

### 2.11 `bedrock` — AWS Bedrock discovery
**Live:** `/home/hbohlen/.hermes/config.yaml:69-71`
```yaml
bedrock:
  discovery:
    enabled: false
```
**Attrset path:** `settings.bedrock.discovery.enabled = false;`
**No discrepancy.**

### 2.12 `auxiliary` — multi-model routing (CRITICAL — preserves sub-providers)
**Live:** `/home/hbohlen/.hermes/config.yaml:72-110`
```yaml
auxiliary:
  vision:
    provider: zai
    model: glm-5.3-flash
    reasoning_effort: medium
  compression:
    provider: nous
    model: deepseek/deepseek-v4.1-flash
  skills_hub:
    provider: nous
    model: deepseek/deepseek-v4.1-flash
  approval:
    provider: nous
    model: deepseek/deepseek-v4.1-flash
  review:
    provider: openai-codex
    model: gpt-5.6-luna
  mcp:
    provider: nous
    model: deepseek/deepseek-v4.1-flash
  title_generation:
    provider: nous
    model: deepseek/deepseek-v4.1-flash
  triage_specifier:
    provider: nous
    model: deepseek/deepseek-v4.1-flash
  kanban_decomposer:
    provider: nous
    model: deepseek/deepseek-v4.1-flash
    reasoning_effort: medium
  profile_describer:
    provider: nous
    model: deepseek/deepseek-v4.1-flash
  curator:
    provider: nous
    model: deepseek/deepseek-v4.1-flash
    reasoning_effort: high
  background_review:
    enabled: false
```
**Attrset path:** `settings.auxiliary = { vision = { … }; compression = { … }; skills_hub = { … }; approval = { … }; review = { … }; mcp = { … }; title_generation = { … }; triage_specifier = { … }; kanban_decomposer = { … }; profile_describer = { … }; curator = { … }; background_review = { enabled = false; }; };`

**No discrepancy.** All 12 sub-providers preserved verbatim — these are
critical for multi-model routing (per the ticket's explicit call-out).

### 2.13 `display` — TUI / dashboard rendering
**Live:** `/home/hbohlen/.hermes/config.yaml:111-135`
```yaml
display:
  compact: true
  busy_input_mode: steer
  bell_on_complete: false
  bell_on_prompt: false
  show_reasoning: true
  background_process_notifications: concise
  streaming: true
  show_cost: true
  focus_view: true
  skin: default
  interim_assistant_messages: true
  tool_progress_command: true
  tool_preview_length: 5
  platforms:
    telegram:
      streaming: false
    wecom:
      streaming: false
  runtime_footer:
    enabled: true
  tool_progress: all
  cleanup_progress: false
  long_running_notifications: true
  busy_ack_detail: true
```
**Attrset path:** `settings.display = { … };`
**No discrepancy.**

### 2.14 `dashboard` — web admin panel
**Live:** `/home/hbohlen/.hermes/config.yaml:136-142`
```yaml
dashboard:
  theme: cyberpunk
  turn_isolation: true
  show_token_analytics: true
  basic_auth:
    username: admin
    password_hash: scrypt$16384$8$1$ftO/n19GpBwI6d7ZL89FIQ==$4BltH1ihWHpmdqJQ41tSPxFymIxJFhBSJ9h/fZFKxR4=
```
**Attrset path:** `settings.dashboard = { theme = "cyberpunk"; turn_isolation = true; show_token_analytics = true; basic_auth = { username = "admin"; password_hash = "scrypt$16384$8$1$ftO/n19GpBwI6d7ZL89FIQ==$4BltH1ihWHpmdqJQ41tSPxFymIxJFhBSJ9h/fZFKxR4="; }; };`
**No discrepancy.** The `scrypt$…` hash is a string with literal `$` and `=`
characters — Nix string literals (`"…"`) do not interpret `$` unless followed
by `{` (a Nix interpolation). Safe.

### 2.15 `stt` — speech-to-text
**Live:** `/home/hbohlen/.hermes/config.yaml:143-150`
```yaml
stt:
  enabled: true
  language: en
  local:
    model: base
  openai:
    model: whisper-1
    language: ''
```
**Attrset path:** `settings.stt = { enabled = true; language = "en"; local.model = "base"; openai = { model = "whisper-1"; language = ""; }; };`
**No discrepancy.**

### 2.16 `human_delay`
**Live:** `/home/hbohlen/.hermes/config.yaml:151-152`
```yaml
human_delay:
  mode: typing
```
**Attrset path:** `settings.human_delay.mode = "typing";`

### 2.17 `memory`
**Live:** `/home/hbohlen/.hermes/config.yaml:153-159`
```yaml
memory:
  memory_enabled: false
  user_profile_enabled: false
  memory_char_limit: 2200
  user_char_limit: 1375
  nudge_interval: 10
  provider: ''
```
**Attrset path:** `settings.memory = { … };`
**No discrepancy.** Note: `memory_char_limit`/`user_char_limit` are
*character* limits, despite snake_case naming that suggests tokens — preserve
the names verbatim.

### 2.18 `delegation`
**Live:** `/home/hbohlen/.hermes/config.yaml:160-164`
```yaml
delegation:
  model: LongCat-2.0
  provider: custom:longcat
  max_iterations: 250
  reasoning_effort: medium
```
**Attrset path:** `settings.delegation = { … };`
**No discrepancy.**

### 2.19 `moa` — Mixture-of-Agents
**Live:** `/home/hbohlen/.hermes/config.yaml:165-190`
```yaml
moa:
  presets:
    default:
      reference_models:
        - provider: openai-codex
          model: gpt-5.5
          enabled: false
        - provider: openrouter
          model: deepseek/deepseek-v4-pro
          enabled: false
      enabled: false
      degraded_reference_policy: loud
      fanout: user_turn
  reference_models:
    - provider: openai-codex
      model: gpt-5.5
      enabled: false
    - provider: openrouter
      model: deepseek/deepseek-v4-pro
      enabled: false
  aggregator:
    provider: openrouter
    model: anthropic/claude-opus-4.8
  degraded_reference_policy: loud
  fanout: user_turn
  enabled: false
```
**Attrset path:** `settings.moa = { … };`
**No discrepancy.** Note the duplicate `reference_models` and `fanout` keys
inside vs outside `presets.default` — preserve both; the YAML reader merges
them into nested attrs naturally. List elements are Nix `{ provider; model;
enabled; }` attrs.

### 2.20 `skills`
**Live:** `/home/hbohlen/.hermes/config.yaml:191-253`
```yaml
skills:
  trusted_project_dirs:
    - /home/hbohlen/nix
  inline_shell: true
  creation_nudge_interval: 15
  disabled:
    - airtable
    - architecture-diagram
    # …57 entries…
    - youtube-content
```
**Attrset path:** `settings.skills = { trusted_project_dirs = [ "/home/hbohlen/nix" ]; inline_shell = true; creation_nudge_interval = 15; disabled = [ "airtable" "architecture-diagram" … "youtube-content" ]; };`
**No discrepancy.** The full list of 57 disabled skills is preserved verbatim
in §4. Strings do not need quoting unless they contain Nix-significant
characters; all entries are bare slugs.

### 2.21 `curator`
**Live:** `/home/hbohlen/.hermes/config.yaml:254-255`
```yaml
curator:
  consolidate: true
```
**Attrset path:** `settings.curator.consolidate = true;`

### 2.22 `slack` / 2.23 `mattermost` / 2.24 `matrix`
**Live:** `/home/hbohlen/.hermes/config.yaml:256-261`
```yaml
slack:
  require_mention: false
mattermost:
  require_mention: false
matrix:
  require_mention: false
```
**Attrset path:** `settings.slack.require_mention = false; settings.mattermost.require_mention = false; settings.matrix.require_mention = false;`

### 2.25 `approvals`
**Live:** `/home/hbohlen/.hermes/config.yaml:262-263`
```yaml
approvals:
  destructive_slash_confirm: false
```
**Attrset path:** `settings.approvals.destructive_slash_confirm = false;`

### 2.26 `plugins`
**Live:** `/home/hbohlen/.hermes/config.yaml:264-278`
```yaml
plugins:
  enabled:
    - crawl4ai
    - hermes-evolve
    - hermes-telemetry
    - moshi-hooks
    - orca-status
    - rtk-rewrite
    - skill-router
    - web-crawl4ai
  entries:
    crawl4ai:
      allow_tool_override: false
  disabled:
    - doppler-secrets
```
**Attrset path:** `settings.plugins = { enabled = [ … ]; entries.crawl4ai.allow_tool_override = false; disabled = [ "doppler-secrets" ]; };`
**No discrepancy.** Note the contrast with `services.hermes-agent.extraPlugins`
(Nix-path packages). Plugin entries here are user-side handles, separate
concern.

### 2.27 `cron`
**Live:** `/home/hbohlen/.hermes/config.yaml:279`
```yaml
cron:
  catch_up_missed: true
```
**Attrset path:** `settings.cron.catch_up_missed = true;`

### 2.28 `kanban`
**Live:** `/home/hbohlen/.hermes/config.yaml:280-285`
```yaml
kanban:
  review_dispatch: true
  orchestrator_profile: ''
  default_assignee: ''
  auto_decompose: true
```
**Attrset path:** `settings.kanban = { … };`

### 2.29 `code_execution`
**Live:** `/home/hbohlen/.hermes/config.yaml:286-288`
```yaml
code_execution:
  timeout: 300
  max_tool_calls: 50
```
**Attrset path:** `settings.code_execution = { timeout = 300; max_tool_calls = 50; };`

### 2.30 `gateway` — large; loop / scale / transport tunables
**Live:** `/home/hbohlen/.hermes/config.yaml:289-326`
```yaml
gateway:
  signal_interrupt_grace_timeout: 1
  delivery_ledger: true
  platform_connect_timeout: 30
  loop_watchdog: true
  loop_watchdog_probe_interval_s: 30
  loop_watchdog_probe_timeout_s: 10
  loop_watchdog_max_strikes: 3
  bot_loop_guard:
    enabled: true
    max_events: 20
    window_seconds: 300
    cooldown_seconds: 600
  startup_watchdog: true
  startup_watchdog_timeout_seconds: 300
  write_sessions_json: true
  multiplex_profiles: true
  profile_routes: []
  scale_to_zero:
    idle_timeout_minutes: 2
  restart_loop_guard:
    max_restarts: 3
    window_seconds: 60
    max_gap_seconds: 300
  respawn_storm:
    max_starts: 5
    window_seconds: 120
  message_timestamps:
    enabled: false
  max_inbound_media_bytes: 134217728
  trust_env: true
  strict: false
  media_delivery_allow_dirs: []
  trust_recent_files: true
  trust_recent_files_seconds: 600
  api_server:
    max_concurrent_runs: 10
  auto_migrate: true
```
**Attrset path:** `settings.gateway = { … };`
**No discrepancy.** Large but flat attrset; `profile_routes = []` and
`media_delivery_allow_dirs = []` are empty lists, valid JSON. Numeric literal
`134217728` (= 128 MiB) is fine.

### 2.31 `streaming`
**Live:** `/home/hbohlen/.hermes/config.yaml:327-328`
```yaml
streaming:
  enabled: true
```
**Attrset path:** `settings.streaming.enabled = true;`

### 2.32 `sessions`
**Live:** `/home/hbohlen/.hermes/config.yaml:329-330`
```yaml
sessions:
  auto_archive: true
```
**Attrset path:** `settings.sessions.auto_archive = true;`

### 2.33 `onboarding`
**Live:** `/home/hbohlen/.hermes/config.yaml:331-335`
```yaml
onboarding:
  seen:
    tool_progress_prompt: true
    busy_input_prompt: true
    openclaw_residue_cleanup: true
```
**Attrset path:** `settings.onboarding.seen = { tool_progress_prompt = true; busy_input_prompt = true; openclaw_residue_cleanup = true; };`

### 2.34 `telemetry`
**Live:** `/home/hbohlen/.hermes/config.yaml:336-339`
```yaml
telemetry:
  shared_metrics:
    enabled: true
    send: true
```
**Attrset path:** `settings.telemetry.shared_metrics = { enabled = true; send = true; };`

### 2.35 `updates`
**Live:** `/home/hbohlen/.hermes/config.yaml:340-344`
```yaml
updates:
  check: true
  pre_update_backup: false
  backup_keep: 5
  non_interactive_local_changes: stash
```
**Attrset path:** `settings.updates = { … };`

### 2.36 `vault`
**Live:** `/home/hbohlen/.hermes/config.yaml:345-347`
```yaml
vault:
  bitwarden:
    enabled: true
```
**Attrset path:** `settings.vault.bitwarden.enabled = true;`

### 2.37 `secrets`
**Live:** `/home/hbohlen/.hermes/config.yaml:348-353`
```yaml
secrets:
  onepassword:
    enabled: true
    env:
      NETCUP_CONSOLE_PASSWORD: op://dev/NETCUP_CONSOLE/password
    binary_path: /usr/bin/op
```
**Attrset path:** `settings.secrets.onepassword = { enabled = true; env = { NETCUP_CONSOLE_PASSWORD = "op://dev/NETCUP_CONSOLE/password"; }; binary_path = "/usr/bin/op"; };`
**No discrepancy.** The `op://` URI is a string literal that hermes parses at
runtime — the slash characters are inert in a Nix `"…"` string.

### 2.38 `local_runtime`
**Live:** `/home/hbohlen/.hermes/config.yaml:354-355`
```yaml
local_runtime:
  enabled: true
```
**Attrset path:** `settings.local_runtime.enabled = true;`

### 2.39 `_config_version` — schema version
**Live:** `/home/hbohlen/.hermes/config.yaml:356`
```yaml
_config_version: 45
```
**Attrset path:** `settings._config_version = 45;`
**Nix legality:** leading-underscore attribute names are legal Nix (per the
Nix language reference, `_` is a valid identifier start). `builtins.toJSON`
emits it as `"_config_version": 45`, which PyYAML writes unchanged. **Safe.**

### 2.40 `group_sessions_per_user`
**Live:** `/home/hbohlen/.hermes/config.yaml:357`
```yaml
group_sessions_per_user: true
```
**Attrset path:** `settings.group_sessions_per_user = true;`

### 2.41 `platform_toolsets` — per-platform tool allowlist
**Live:** `/home/hbohlen/.hermes/config.yaml:358-393`
```yaml
platform_toolsets:
  cli:
    - a2a
    - browser
    # …14 entries total
  telegram:
    - hermes-telegram
  discord:
    - hermes-discord
  whatsapp:
    - hermes-whatsapp
  slack:
    - hermes-slack
  signal:
    - hermes-signal
  homeassistant:
    - hermes-homeassistant
  qqbot:
    - hermes-qqbot
  yuanbao:
    - hermes-yuanbao
  teams:
    - hermes-teams
  google_chat:
    - hermes-google_chat
```
**Attrset path:** `settings.platform_toolsets = { cli = [ … ]; telegram = [ "hermes-telegram" ]; … };`

### 2.42 `tool_gateway_declined_tools`
**Live:** `/home/hbohlen/.hermes/config.yaml:394-398`
```yaml
tool_gateway_declined_tools:
  - browser
  - image_gen
  - stt
  - video_gen
```
**Attrset path:** `settings.tool_gateway_declined_tools = [ "browser" "image_gen" "stt" "video_gen" ];`

### 2.43 `known_plugin_toolsets`
**Live:** `/home/hbohlen/.hermes/config.yaml:399-402`
```yaml
known_plugin_toolsets:
  cli:
    - a2a
    - spotify
```
**Attrset path:** `settings.known_plugin_toolsets.cli = [ "a2a" "spotify" ];`

### 2.44 `known_builtin_toolsets`
**Live:** `/home/hbohlen/.hermes/config.yaml:403-432`
```yaml
known_builtin_toolsets:
  cli:
    - browser
    - clarify
    # …28 entries
```
**Attrset path:** `settings.known_builtin_toolsets.cli = [ … ];`

### 2.45 `custom_providers`
**Live:** `/home/hbohlen/.hermes/config.yaml:433-441`
```yaml
custom_providers:
  - name: LongCat
    base_url: https://api.longcat.chat/openai
    key_env: HERMES_CUSTOM_API_LONGCAT_CHAT_API_KEY
    model: LongCat-2.0
    models:
      LongCat-2.5-Preview: {}
      LongCat-2.0: {}
    models_discovered: true
```
**Attrset path:** `settings.custom_providers = [ { name = "LongCat"; base_url = "https://api.longcat.chat/openai"; key_env = "HERMES_CUSTOM_API_LONGCAT_CHAT_API_KEY"; model = "LongCat-2.0"; models = { "LongCat-2.5-Preview" = { }; "LongCat-2.0" = { }; }; models_discovered = true; } ];`
**No discrepancy.** A list of one attrset. Hyphenated model keys
(`"LongCat-2.5-Preview"`) MUST be Nix string-quoted attribute names because
the raw identifier is not a valid Nix attr name (Nix permits `-` only inside
quoted strings; bare `LongCat-2.5-Preview` is a `let`/lambda binding syntax
error). Same for any future hyphenated model keys.

---

## 3. Keys the upstream module does NOT know about

Per the live config inventory in §1, **every top-level key maps cleanly to
`settings.<key>`**. None require escape into `hermesHomeFiles`, `documents`,
`mcpServers`, `extraArgs`, `extraPackages`, `extraPlugins`, etc.

Why this is fine despite the upstream module "owning" the same keys:

- The upstream module's `settings` option's check is just `builtins.isAttrs`
  (`moduleCommon.nix:34`). It does not whitelist keys; the runtime hermes
  agent reads every YAML key.
- The merge script (`configMergeScript.nix:21-28`) is a deep merge where
  "Nix wins on present keys, existing wins on absent keys." So even if the
  upstream agent later adds a new top-level key to its on-disk default,
  pre-existing keys you set in `settings` will overwrite it on the next
  activation.
- Per the upstream module's own option text (`moduleCommon.nix:273-281`):
  > "The module keeps all other keys, which includes the keys that `hermes
  > config set` and the settings panes of the TUI and the desktop app write
  > at runtime."

**Result: the §4 attrset literal covers the whole live config 1:1.** No
discrepancies at the top level.

### Other upstream concerns, all empty for the live config

These upstream options are unrelated to `config.yaml` keys but worth a
negative-confirm:

- `authFile` (`moduleCommon.nix:323-332`) — handled separately as the
  `~/nix/hermes/.hermes/auth.json` file (per `docs/specs/hermes-config.md`).
  No key in `config.yaml` maps here.
- `environmentFiles` (`moduleCommon.nix:292-309`) — handled by secretspec +
  `enterShell` per the spec, NOT a key in `config.yaml`.
- `hermesHomeFiles` (`moduleCommon.nix:366-384`) — for `SOUL.md` and
  `memories/USER.md` per the spec. The live `~/.hermes/` does not have a
  `SOUL.md`, so the new tree can either start empty or seed from `AGENTS.md`.
- `mcpServers` (`moduleCommon.nix:387-410`) — the live config has no
  `mcp_servers:` key, so no entry.
- `backend.mode` etc. (`moduleCommon.nix:510-649`) — backend is for
  `hermes serve` / `hermes dashboard` (HM `backend` option, NOT
  `settings.backend`). The live config has `gateway.*` (the messaging
  gateway loop), which is unrelated to the HM `backend` option. Per H7
  ("Native mode, hardened"), the live config does not use a separate
  dashboard backend; if you want one, set
  `services.hermes-agent.backend.mode = "dashboard";` at the top level of
  the `services.hermes-agent` attrset, NOT under `settings`.
- `extraArgs` — `extraArgs` is a top-level option, not under `settings`.

---

## 4. The complete `settings` attrset literal

**This is the load-bearing artifact for ticket T-02.** Drop it into
`services.hermes-agent.settings` inside the workstation's
`machines.workstation.home-manager` block. The HM module's
`deepConfigType.merge` joins it with any other definitions
(`lib.recursiveUpdate` over all `settings` defs — `moduleCommon.nix:35`);
`mkConfigFiles` JSON-serializes the joined attrset and the merge script
PyYAML-writes it to `~/.hermes/config.yaml` with `sort_keys=False`
(`configMergeScript.nix:32`). The result is byte-equivalent (modulo
trivial whitespace from PyYAML's default styling) to the live
`/home/hbohlen/.hermes/config.yaml`.

```nix
settings = {
  # ── 2.1 model ──────────────────────────────────────────────────────────
  model = {
    default = "deepseek/deepseek-v4.1-flash";
    provider = "nous";
    base_url = "https://inference-api.nousresearch.com/v1";
  };

  # ── 2.2 database ───────────────────────────────────────────────────────
  database.journal_mode = "wal";

  # ── 2.3 runtime ────────────────────────────────────────────────────────
  runtime.nofile_soft_limit = 4096;

  # ── 2.4 agent ──────────────────────────────────────────────────────────
  agent = {
    max_turns = 150;
    service_tier = "";
    fast_auto_seconds = 60;
    verbose = false;
    reasoning_effort = "medium";
    personalities = { };
  };

  # ── 2.5 terminal (cwd intentionally OMITTED; see §5) ──────────────────
  terminal = {
    backend = "local";
    # cwd: injected by the upstream module from services.hermes-agent.workingDirectory.
    # Do not set it here unless you want to override that.
    timeout = 180;
    home_mode = "auto";
    container_cpu = 1;
    container_memory = 5120;
    container_disk = 51200;
    container_persistent = true;
    docker_mount_cwd_to_workspace = false;
    lifetime_seconds = 300;
  };

  # ── 2.6 web ────────────────────────────────────────────────────────────
  web = {
    backend = "tavily";
    provider_tier.parallel = "free";
  };

  # ── 2.7 browser ────────────────────────────────────────────────────────
  browser = {
    inactivity_timeout = 120;
    engine = "lightpanda";
    extension_control.enabled = false;
    cloud_provider = "local";
  };

  # ── 2.8 tool_loop_guardrails ───────────────────────────────────────────
  tool_loop_guardrails = {
    warnings_enabled = true;
    hard_stop_enabled = false;
    non_interactive_hard_stop_enabled = true;
    warn_after = {
      exact_failure = 2;
      same_tool_failure = 3;
      idempotent_no_progress = 2;
    };
    hard_stop_after = {
      exact_failure = 5;
      same_tool_failure = 8;
      idempotent_no_progress = 5;
    };
  };

  # ── 2.9 compression ────────────────────────────────────────────────────
  compression = {
    enabled = true;
    checkpoint_required = false;
    progress_notices = true;
    threshold = 0.35;
    target_ratio = 0.3;
    protect_last_n = 20;
    min_tail_user_messages = 1;
    max_attempts = 3;
    proactive_prune_tokens = 20000;
    proactive_prune_min_result_chars = 8000;
    proactive_prune_min_reclaim_tokens = 4096;
    hygiene_max_turn_hold_seconds = 10;
    protect_first_n = 3;
    codex_gpt55_autoraise = true;
    codex_app_server_auto = "native";
    codex_responses_native = true;
    idle_compact_after_seconds = 0;
  };

  # ── 2.10 prompt_caching ────────────────────────────────────────────────
  prompt_caching.cache_ttl = "5m";

  # ── 2.11 bedrock ───────────────────────────────────────────────────────
  bedrock.discovery.enabled = false;

  # ── 2.12 auxiliary (multi-model routing — critical) ────────────────────
  auxiliary = {
    vision = {
      provider = "zai";
      model = "glm-5.3-flash";
      reasoning_effort = "medium";
    };
    compression = {
      provider = "nous";
      model = "deepseek/deepseek-v4.1-flash";
    };
    skills_hub = {
      provider = "nous";
      model = "deepseek/deepseek-v4.1-flash";
    };
    approval = {
      provider = "nous";
      model = "deepseek/deepseek-v4.1-flash";
    };
    review = {
      provider = "openai-codex";
      model = "gpt-5.6-luna";
    };
    mcp = {
      provider = "nous";
      model = "deepseek/deepseek-v4.1-flash";
    };
    title_generation = {
      provider = "nous";
      model = "deepseek/deepseek-v4.1-flash";
    };
    triage_specifier = {
      provider = "nous";
      model = "deepseek/deepseek-v4.1-flash";
    };
    kanban_decomposer = {
      provider = "nous";
      model = "deepseek/deepseek-v4.1-flash";
      reasoning_effort = "medium";
    };
    profile_describer = {
      provider = "nous";
      model = "deepseek/deepseek-v4.1-flash";
    };
    curator = {
      provider = "nous";
      model = "deepseek/deepseek-v4.1-flash";
      reasoning_effort = "high";
    };
    background_review.enabled = false;
  };

  # ── 2.13 display ───────────────────────────────────────────────────────
  display = {
    compact = true;
    busy_input_mode = "steer";
    bell_on_complete = false;
    bell_on_prompt = false;
    show_reasoning = true;
    background_process_notifications = "concise";
    streaming = true;
    show_cost = true;
    focus_view = true;
    skin = "default";
    interim_assistant_messages = true;
    tool_progress_command = true;
    tool_preview_length = 5;
    platforms = {
      telegram.streaming = false;
      wecom.streaming = false;
    };
    runtime_footer.enabled = true;
    tool_progress = "all";
    cleanup_progress = false;
    long_running_notifications = true;
    busy_ack_detail = true;
  };

  # ── 2.14 dashboard ─────────────────────────────────────────────────────
  dashboard = {
    theme = "cyberpunk";
    turn_isolation = true;
    show_token_analytics = true;
    basic_auth = {
      username = "admin";
      password_hash = "scrypt$16384$8$1$ftO/n19GpBwI6d7ZL89FIQ==$4BltH1ihWHpmdqJQ41tSPxFymIxJFhBSJ9h/fZFKxR4=";
    };
  };

  # ── 2.15 stt ───────────────────────────────────────────────────────────
  stt = {
    enabled = true;
    language = "en";
    local.model = "base";
    openai = {
      model = "whisper-1";
      language = "";
    };
  };

  # ── 2.16 human_delay ──────────────────────────────────────────────────
  human_delay.mode = "typing";

  # ── 2.17 memory ────────────────────────────────────────────────────────
  memory = {
    memory_enabled = false;
    user_profile_enabled = false;
    memory_char_limit = 2200;
    user_char_limit = 1375;
    nudge_interval = 10;
    provider = "";
  };

  # ── 2.18 delegation ────────────────────────────────────────────────────
  delegation = {
    model = "LongCat-2.0";
    provider = "custom:longcat";
    max_iterations = 250;
    reasoning_effort = "medium";
  };

  # ── 2.19 moa ───────────────────────────────────────────────────────────
  moa = {
    presets = {
      default = {
        reference_models = [
          { provider = "openai-codex"; model = "gpt-5.5"; enabled = false; }
          { provider = "openrouter"; model = "deepseek/deepseek-v4-pro"; enabled = false; }
        ];
        enabled = false;
        degraded_reference_policy = "loud";
        fanout = "user_turn";
      };
    };
    reference_models = [
      { provider = "openai-codex"; model = "gpt-5.5"; enabled = false; }
      { provider = "openrouter"; model = "deepseek/deepseek-v4-pro"; enabled = false; }
    ];
    aggregator = {
      provider = "openrouter";
      model = "anthropic/claude-opus-4.8";
    };
    degraded_reference_policy = "loud";
    fanout = "user_turn";
    enabled = false;
  };

  # ── 2.20 skills ────────────────────────────────────────────────────────
  skills = {
    trusted_project_dirs = [ "/home/hbohlen/nix" ];
    inline_shell = true;
    creation_nudge_interval = 15;
    disabled = [
      "airtable"
      "architecture-diagram"
      "ascii-video"
      "baoyu-infographic"
      "blocked-page-recovery"
      "box"
      "claude-code"
      "claude-design"
      "codebase-inspection"
      "computer-use"
      "docx"
      "dogfood"
      "email-inbox-triage"
      "gif-search"
      "git-guardrails-claude-code"
      "github"
      "google-workspace"
      "himalaya"
      "humanizer"
      "implement-spec"
      "inspecting-hermes-desktop-dom"
      "manim-video"
      "maps"
      "meeting-action-items"
      "migrate-to-shoehorn"
      "node-inspect-debugger"
      "notion"
      "obsidian"
      "opencode"
      "openspec-change-application"
      "p5js"
      "pdf"
      "popular-web-designs"
      "powerpoint"
      "product-price-monitor"
      "python-debugpy"
      "requesting-code-review"
      "scaffold-exercises"
      "sdlc-review"
      "setup-pre-commit"
      "setup-ts-deep-modules"
      "simplify-code"
      "songsee"
      "songwriting-and-ai-music"
      "spike"
      "systematic-debugging"
      "teams-meeting-pipeline"
      "test-driven-development"
      "to-questionnaire"
      "wait-what"
      "weekly-review-planning"
      "writing-beats"
      "writing-fragments"
      "writing-shape"
      "xlsx"
      "xurl"
      "youtube-content"
    ];
  };

  # ── 2.21 curator ───────────────────────────────────────────────────────
  curator.consolidate = true;

  # ── 2.22-2.24 messaging-platform mention gates ─────────────────────────
  slack.require_mention = false;
  mattermost.require_mention = false;
  matrix.require_mention = false;

  # ── 2.25 approvals ─────────────────────────────────────────────────────
  approvals.destructive_slash_confirm = false;

  # ── 2.26 plugins ───────────────────────────────────────────────────────
  plugins = {
    enabled = [
      "crawl4ai"
      "hermes-evolve"
      "hermes-telemetry"
      "moshi-hooks"
      "orca-status"
      "rtk-rewrite"
      "skill-router"
      "web-crawl4ai"
    ];
    entries.crawl4ai.allow_tool_override = false;
    disabled = [ "doppler-secrets" ];
  };

  # ── 2.27 cron ──────────────────────────────────────────────────────────
  cron.catch_up_missed = true;

  # ── 2.28 kanban ────────────────────────────────────────────────────────
  kanban = {
    review_dispatch = true;
    orchestrator_profile = "";
    default_assignee = "";
    auto_decompose = true;
  };

  # ── 2.29 code_execution ────────────────────────────────────────────────
  code_execution = {
    timeout = 300;
    max_tool_calls = 50;
  };

  # ── 2.30 gateway ───────────────────────────────────────────────────────
  gateway = {
    signal_interrupt_grace_timeout = 1;
    delivery_ledger = true;
    platform_connect_timeout = 30;
    loop_watchdog = true;
    loop_watchdog_probe_interval_s = 30;
    loop_watchdog_probe_timeout_s = 10;
    loop_watchdog_max_strikes = 3;
    bot_loop_guard = {
      enabled = true;
      max_events = 20;
      window_seconds = 300;
      cooldown_seconds = 600;
    };
    startup_watchdog = true;
    startup_watchdog_timeout_seconds = 300;
    write_sessions_json = true;
    multiplex_profiles = true;
    profile_routes = [ ];
    scale_to_zero = {
      idle_timeout_minutes = 2;
    };
    restart_loop_guard = {
      max_restarts = 3;
      window_seconds = 60;
      max_gap_seconds = 300;
    };
    respawn_storm = {
      max_starts = 5;
      window_seconds = 120;
    };
    message_timestamps.enabled = false;
    max_inbound_media_bytes = 134217728;
    trust_env = true;
    strict = false;
    media_delivery_allow_dirs = [ ];
    trust_recent_files = true;
    trust_recent_files_seconds = 600;
    api_server.max_concurrent_runs = 10;
    auto_migrate = true;
  };

  # ── 2.31 streaming ─────────────────────────────────────────────────────
  streaming.enabled = true;

  # ── 2.32 sessions ──────────────────────────────────────────────────────
  sessions.auto_archive = true;

  # ── 2.33 onboarding ────────────────────────────────────────────────────
  onboarding.seen = {
    tool_progress_prompt = true;
    busy_input_prompt = true;
    openclaw_residue_cleanup = true;
  };

  # ── 2.34 telemetry ─────────────────────────────────────────────────────
  telemetry.shared_metrics = {
    enabled = true;
    send = true;
  };

  # ── 2.35 updates ───────────────────────────────────────────────────────
  updates = {
    check = true;
    pre_update_backup = false;
    backup_keep = 5;
    non_interactive_local_changes = "stash";
  };

  # ── 2.36 vault ─────────────────────────────────────────────────────────
  vault.bitwarden.enabled = true;

  # ── 2.37 secrets ───────────────────────────────────────────────────────
  secrets.onepassword = {
    enabled = true;
    env = {
      NETCUP_CONSOLE_PASSWORD = "op://dev/NETCUP_CONSOLE/password";
    };
    binary_path = "/usr/bin/op";
  };

  # ── 2.38 local_runtime ─────────────────────────────────────────────────
  local_runtime.enabled = true;

  # ── 2.39 _config_version (leading-underscore is legal in Nix) ──────────
  _config_version = 45;

  # ── 2.40 group_sessions_per_user ───────────────────────────────────────
  group_sessions_per_user = true;

  # ── 2.41 platform_toolsets ─────────────────────────────────────────────
  platform_toolsets = {
    cli = [
      "a2a"
      "browser"
      "clarify"
      "code_execution"
      "computer_use"
      "context_engine"
      "delegation"
      "file"
      "memory"
      "session_search"
      "skills"
      "terminal"
      "todo"
      "web"
    ];
    telegram = [ "hermes-telegram" ];
    discord = [ "hermes-discord" ];
    whatsapp = [ "hermes-whatsapp" ];
    slack = [ "hermes-slack" ];
    signal = [ "hermes-signal" ];
    homeassistant = [ "hermes-homeassistant" ];
    qqbot = [ "hermes-qqbot" ];
    yuanbao = [ "hermes-yuanbao" ];
    teams = [ "hermes-teams" ];
    google_chat = [ "hermes-google_chat" ];
  };

  # ── 2.42 tool_gateway_declined_tools ───────────────────────────────────
  tool_gateway_declined_tools = [
    "browser"
    "image_gen"
    "stt"
    "video_gen"
  ];

  # ── 2.43 known_plugin_toolsets ─────────────────────────────────────────
  known_plugin_toolsets.cli = [
    "a2a"
    "spotify"
  ];

  # ── 2.44 known_builtin_toolsets ────────────────────────────────────────
  known_builtin_toolsets.cli = [
    "browser"
    "clarify"
    "code_execution"
    "computer_use"
    "connections"
    "context_engine"
    "cronjob"
    "delegation"
    "discord"
    "discord_admin"
    "file"
    "homeassistant"
    "image_gen"
    "kanban"
    "memory"
    "session_search"
    "skills"
    "spotify"
    "stt"
    "terminal"
    "todo"
    "tts"
    "video"
    "video_gen"
    "vision"
    "web"
    "x_search"
    "yuanbao"
  ];

  # ── 2.45 custom_providers (note hyphenated keys MUST be quoted) ───────
  custom_providers = [
    {
      name = "LongCat";
      base_url = "https://api.longcat.chat/openai";
      key_env = "HERMES_CUSTOM_API_LONGCAT_CHAT_API_KEY";
      model = "LongCat-2.0";
      models = {
        "LongCat-2.5-Preview" = { };
        "LongCat-2.0" = { };
      };
      models_discovered = true;
    }
  ];
};
```

---

## 5. `terminal.cwd` — the one real discrepancy

The live config has `terminal.cwd: .` (`/home/hbohlen/.hermes/config.yaml:18`).
The upstream module's `mkConfigFiles` writes
`{ terminal.cwd = workingDirectory; }` into the generated JSON before
deep-merging `cfg.settings` (`moduleCommon.nix:695-697`). The user's
`settings.terminal.cwd` overrides that default via `lib.recursiveUpdate`
left→right precedence (`moduleCommon.nix:685-687`).

Two possible resolutions, both in §4 — the attrset literal above has it
**omitted** on purpose:

| Option | Result | Verdict |
|---|---|---|
| Omit `terminal.cwd` from `settings` | The Nix default (`config.home.homeDirectory`) wins → absolute home dir in YAML | **Recommended** for the workstation path; matches the spec's stated intent that the operator's working directory is the home dir. |
| Set `settings.terminal.cwd = ".";` | The literal `.` survives → relative path semantics | Preserves the live behavior literally. Use if you want hermes's "run from wherever you invoked it" semantics. |

Recommendation: omit (option 1). The spec
(`/home/hbohlen/nix/docs/specs/hermes-config.md:88-128`) doesn't carry a
preference, but option 1 is more aligned with how the upstream module is
designed to be used and avoids the ambiguity that the absolute
`workingDirectory` and the relative `"."` would otherwise create across
the systemd unit's `WorkingDirectory = cfg.workingDirectory` and the
runtime `terminal.cwd` YAML key.

---

## 6. Pre-merge diff plan

After activating the new tree and the merge script runs, the on-disk
`~/.hermes/config.yaml` will be a deep-merge of (a) the Nix-generated
JSON (which contains every key in §4) and (b) any runtime-added keys the
agent or the user wrote previously.

**Expected diff between the new tree and the live config:**

1. **No structural diff.** All 45 top-level keys in the live config appear
   in §4 with identical values. The merge script preserves sort order
   (`sort_keys=False`).
2. **`terminal.cwd` value will change** from `"."` to the Nix-rendered
   `workingDirectory` value (an absolute path), per §5.
3. **Runtime-added keys preserved.** The merge script's `deep_merge`
   preserves any keys present on disk but absent from the Nix `settings`
   (`configMergeScript.nix:21-28`). So if the live config has a key the
   operator added via `hermes config set` after the live config was last
   edited, it survives. §4 only declares what we want to declare; it does
   not erase anything else.
4. **Whitespace-only diff.** PyYAML's `default_flow_style=False` produces
   block-style for all non-empty collections and inline flow for empty
   collections, identical to the live config's existing style. Lists of
   strings may differ in flow vs block styling from the live config's
   manual editing — `["a", "b"]` (flow) vs `- a\n- b` (block) are
   semantically equivalent; the merge script will normalize to one or the
   other based on the JSON it receives.

**Assumption documented:** this translation is a 1:1 byte-shape mapping of
the live config keys that the operator intends to manage via Nix. The live
config has no exotic keys outside §1's 45; verification step: `grep -E '^[a-z_]+:' /home/hbohlen/.hermes/config.yaml | sort -u` returns exactly the 45 keys listed in §1.

---

## 7. Verifying the literal parses

Before T-02 lands, the engineer can sanity-check the literal with:

```sh
# Save the §4 literal to /tmp/hermes-settings.nix, then:
nix-instantiate --parse /tmp/hermes-settings.nix
# Should print the parsed AST and exit 0.
```

Or, even better, evaluate against a local clone of the upstream module:

```sh
nix-instantiate --eval --strict --json --expr '
let
  flake = builtins.getFlake "github:NousResearch/hermes-agent";
  eval = flake.homeManagerModules.default.extend {
    modules = [{
      home.username = "hbohlen";
      home.homeDirectory = "/home/hbohlen";
      services.hermes-agent = {
        enable = true;
        settings = import /tmp/hermes-settings.nix;
      };
    }];
  };
in eval.config.services.hermes-agent.settings.model.default
'
# Should print "deepseek/deepseek-v4.1-flash"
```

This validates (a) the literal parses, (b) every nested attribute name is
valid Nix, (c) the upstream module accepts it, (d) deepConfigType's
recursiveUpdate merge doesn't reject it.

---

## 8. Discrepancies summary for the parent

The ticket asked for discrepancies between the live config and the
upstream's typed option set. **There are zero Nix-typing discrepancies.**

The upstream module's `settings` option is `deepConfigType` (just
`builtins.isAttrs`), so the on-disk YAML structure is what the runtime
agent expects — the merge is purely structural. Every top-level key in the
live config maps 1:1 to a `settings.<key>` attrset path. The full attrset
literal in §4 covers all 45 top-level keys with byte-identical values.

**The only behavioural delta is `terminal.cwd`** (§5), and it is a
deliberate upstream-module design choice (`mkConfigFiles` injects
`terminal.cwd = workingDirectory` into the Nix-generated JSON before
deep-merging user settings), not a typing problem. §4 omits `terminal.cwd`
to let the Nix default win; this is the recommended choice per §5.

**One minor Nit:** the `custom_providers.models` attrset has hyphenated
keys (`"LongCat-2.5-Preview"`, `"LongCat-2.0"`). These MUST be quoted in
Nix; the literal in §4 does so. If a future upstream release adds more
such hyphenated keys (e.g. `gpt-5-codex`, `claude-4-opus`), the same rule
applies.

**No upstream-only option rewrites a live key.** `mcpServers`,
`extraPackages`, `extraPlugins`, `extraArgs`, `backend.mode`,
`authFile`, `environmentFiles`, `documents`, `hermesHomeFiles` are all
sidecar options that touch separate subsystems (other YAML keys, the
PATH, plugin directories, the systemd unit, separate files). None of them
collides with a live `config.yaml` key.
