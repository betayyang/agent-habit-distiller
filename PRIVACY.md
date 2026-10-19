# Privacy

`agent-habit-distiller` is **local-first**: it has no server and keeps everything in
plain files on your machine. It is not network-silent — the distillation is a model
call made by your agent, as described under [Network](#network).

## What it reads
- Claude Code: transcripts in `~/.claude/projects/<project>/*.jsonl` and input history in `~/.claude/history.jsonl`
- Codex: rollouts in `~/.codex/sessions/**/*.jsonl` and `~/.codex/archived_sessions/`, and input history in `~/.codex/history.jsonl`
- Your existing ledger, any `read_only_ledgers` you configured, and `CLAUDE.md` / `AGENTS.md`

These are files you already have on your own machine. The tool reads them to find
recurring habits and preferences.

## What it writes
- Per-habit ledger files (default `~/.claude/knowledge/habits/` or `~/.codex/knowledge/habits/`)
- A sentinel-managed "My Habits" block inside your global `CLAUDE.md` / `AGENTS.md`
- Its own `last-run`, `last-audit`, `run.log`, `last-summary.txt`, `last-exec.log` and
  `block-size.tsv` in `<ledger>/.state/<agent>/`. `last-exec.log` holds the agent's full
  output for the latest run, which can quote your transcripts; it is overwritten on
  every run.

It only rewrites the region between the `<!-- BEGIN habit-distiller -->` and
`<!-- END habit-distiller -->` markers in `CLAUDE.md` / `AGENTS.md`; the rest of that file is
never touched.

## Network
- The distillation is a model call. Whatever the run reads — transcripts, input
  history, your ledger and any `read_only_ledgers` — is sent to the provider of the
  agent doing the run: Anthropic for Claude Code, OpenAI for Codex. Configuring
  `read_only_ledgers` across agents therefore sends one provider's material to the
  other. Ledgers can end up holding things you pasted into a session, such as URLs
  with tokens in them; check before sharing one.
- Beyond that, the only outbound request this project makes is the optional webhook
  notification, and only if you set `HABIT_DISTILLER_WEBHOOK` (unset by default). It
  posts the run report, which summarises the habits found in that run, to the
  service behind the URL. Treat the URL itself as a secret: the installer stores it
  in a mode-600 plist on macOS, or in your crontab on Linux.

## Unattended runs

The scheduled Claude run uses `--dangerously-skip-permissions`; the Codex run is
sandboxed with write access to `~/.codex` (plus the ledger, if you moved it). Your
transcripts can contain text from web pages and tool output, and a prompt injection
in there would act with those permissions. Use `./install/install.sh --no-schedule`
and run the skill interactively if that isn't acceptable for you.

## Your responsibility
Because the tool reads your **entire** recent conversation history, those logs may
contain secrets, client data, or other sensitive material you discussed with
your agent. Distilled habits are stored in plaintext in your ledger and
`CLAUDE.md` / `AGENTS.md`. Review what lands there, and use `exclude_projects` in the config to
skip sensitive repos. You are responsible for the sensitivity of your own local
logs and for where those files end up (e.g. if you commit it to a repo).
