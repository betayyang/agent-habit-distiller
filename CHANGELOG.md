# Changelog

## v0.2.0 — 2026-10-19

Renamed from `claude-habit-distiller` to `agent-habit-distiller`. The old GitHub URL
redirects; existing clones keep working.

### Added
- **Codex support.** One skill serves both agents: Codex sessions are read from
  `~/.codex/sessions` and the habits block goes into `~/.codex/AGENTS.md`. The
  scheduled Codex run is sandboxed (`codex exec -s workspace-write -C ~/.codex`).
- `install.sh --agent claude|codex|both` (default: every CLI found). Codex is
  scheduled 30 minutes after Claude.
- `[claude]` / `[codex]` override tables and `read_only_ledgers` in the config.
- Webhook bodies for Feishu/Lark and Discord (previously only `{"text"}`, which
  both reject). `HABIT_DISTILLER_WEBHOOK` can be baked into the scheduled job at
  install time; failed runs are reported as failed.
- A per-ledger lock, so overlapping runs skip instead of writing the ledger at once.

### Changed — check these when upgrading
- Run state and logs moved from the skill directory to `<ledger>/.state/<agent>/`.
  The runner moves an existing `.last-run` / `.last-audit` on its first run.
- Config path is now `~/.config/habit-distiller/config.toml`; the old path is
  still read.
- `write_global_claude_md` is now `write_global_instructions` (old name still honoured).
- `run.log` keeps a few lines per run; the agent's full output goes to
  `last-exec.log`, overwritten each run.

### Fixed
- The block was measured in bytes under launchd/cron (no locale), overstating CJK
  text by ~1.8x. Counting now uses Python.
- A failed Codex run re-sent the previous run's report.
- The model could write run/audit records into the ledger and its own rows into
  `block-size.tsv`; both are now forbidden.
- Privacy docs claimed no data leaves the machine. The distillation run sends what
  it reads to the agent's model provider; the README and `PRIVACY.md` now say so,
  and describe the write access of unattended runs.

## v0.1.0 — 2026-07-17

Initial release for Claude Code: scheduled distillation into a budgeted
`CLAUDE.md` block plus an on-demand ledger.
