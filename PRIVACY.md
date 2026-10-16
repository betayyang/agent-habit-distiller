# Privacy

`agent-habit-distiller` is designed to be **local-first and network-silent**.

## What it reads
- Claude Code: transcripts in `~/.claude/projects/<project>/*.jsonl` and input history in `~/.claude/history.jsonl`
- Codex: rollouts in `~/.codex/sessions/**/*.jsonl` and `~/.codex/archived_sessions/`, and input history in `~/.codex/history.jsonl`
- Your existing ledger, any `read_only_ledgers` you configured, and `CLAUDE.md` / `AGENTS.md`

These are files you already have on your own machine. The tool reads them to find
recurring habits and preferences.

## What it writes
- Per-habit ledger files (default `~/.claude/knowledge/habits/` or `~/.codex/knowledge/habits/`)
- A sentinel-managed "My Habits" block inside your global `CLAUDE.md` / `AGENTS.md`
- Its own `last-run`, `last-audit`, `run.log` and `last-summary.txt` in `<ledger>/.state/<agent>/`

It only rewrites the region between the `<!-- BEGIN habit-distiller -->` and
`<!-- END habit-distiller -->` markers in `CLAUDE.md` / `AGENTS.md`; the rest of that file is
never touched.

## Network
- The distillation itself makes **no network requests** beyond the normal model
  calls that Claude Code or Codex already makes on your behalf.
- The **only** outbound request this project can make is the optional webhook
  notification, and only if you explicitly set `HABIT_DISTILLER_WEBHOOK`. It is
  unset by default.

## Your responsibility
Because the tool reads your **entire** recent conversation history, those logs may
contain secrets, client data, or other sensitive material you discussed with
your agent. Distilled habits are stored in plaintext in your ledger and
`CLAUDE.md` / `AGENTS.md`. Review what lands there, and use `exclude_projects` in the config to
skip sensitive repos. You are responsible for the sensitivity of your own local
logs and for where those files end up (e.g. if you commit it to a repo).
