# hermes/modules/settings.nix — the full `services.hermes-agent.settings` attrset.
#
# Translated 1:1 from the live ~/.hermes/config.yaml (all 45 top-level keys).
# Source of truth: docs/research/2026-09-29-hermes-config-translation.md §4 (R-02),
# verified against the upstream module with nix-instantiate --parse and --eval.
#
# Deliberate omissions:
#   * terminal.cwd — omitted per R-02 §5. The upstream module auto-injects
#     terminal.cwd = workingDirectory into the generated config before the
#     user settings are deep-merged, so declaring it here would lose anyway.
#   * secrets — nothing here may be secret. API keys reach hermes through
#     environmentFiles -> $HERMES_HOME/.env (see modules/hermes.nix), never
#     config.yaml, which is world-readable in the Nix store.
#   * secrets.onepassword.binary_path, a machine path rather than a setting.
#     Its reason is at section 2.37.
#
# Hyphenated model names under custom_providers MUST stay quoted (R-02 §8).
{
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
  # `binary_path` is the one live key this file omits on purpose. Read in the
  # pinned source (agent/secret_sources/onepassword.py, `find_op`): a pinned
  # binary_path is used verbatim, and pinned-but-missing returns None rather
  # than falling back to PATH. The live value `/usr/bin/op` is the
  # workstation's, it does not exist on netcup, and the service PATH is
  # `unitPath` only (nix/homeManagerModules.nix:138) with no /usr/bin. Unset,
  # `find_op` takes `shutil.which("op")`, which finds the `op` that
  # `services.hermes-agent.extraPackages` puts on that PATH (modules/hermes.nix).
  secrets.onepassword = {
    enabled = true;
    env = {
      NETCUP_CONSOLE_PASSWORD = "op://dev/NETCUP_CONSOLE/password";
    };
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
}
