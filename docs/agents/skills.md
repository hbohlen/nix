# Skills

The single skill store is `~/.agents/skills/` (user-level), kept fresh by the
external `skills` CLI; per-agent dirs (`~/.qoder/skills`, `~/.claude/skills`)
are symlink farms into it. This repo deliberately ships only its unique skills
under `.agents/skills/` (`openspec-*`, `typesafe-ai`).

Never run the skills installer *inside this repo*: it recreates repo-level
copies of skills that already exist user-level, and Qoder then warns about
name conflicts per skill (`Detected N skill name conflicts across sources` —
the 70-conflict regression of 2026-09-30). Install at `~` instead.

`.pi/skills/` links point at `~/.agents/skills/`, not the repo copies.
