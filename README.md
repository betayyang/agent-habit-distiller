# agent-habit-distiller

**The more you use your coding agent, the more it knows you. Works with Claude Code and Codex. 100% local — no server, no API, no data leaves your machine.**

`agent-habit-distiller` (formerly `claude-habit-distiller`) is a scheduled
*reflection job* for [Claude Code](https://claude.com/claude-code) and
[Codex](https://github.com/openai/codex). Once a day it reads your own local
conversation logs, distills the **stable habits and preferences** you've shown
across sessions, and writes them back into:

- a **"My Habits" block** in the agent's global instructions file —
  `~/.claude/CLAUDE.md` or `~/.codex/AGENTS.md`, loaded into every future session — and
- a **ledger** of per-habit files with the *why* behind each one.

You don't teach it your preferences. It notices them.

![before and after: a plain CLAUDE.md gains an auto-distilled "My Habits" block](assets/before-after.png)

## What makes it different

Most "AI memory" projects are **memory infrastructure** — SDKs + vector DBs you
wire into an agent *you* build. This is the opposite: zero infrastructure, pure
files, aimed at the coding agent you already use.

| | This tool | Mem0 / Zep / Letta | Built-in agent memory |
|---|---|---|---|
| What it is | Offline **reflection / profiler** | Runtime memory **store** | In-session note-taking |
| Runs | On a schedule, batch | On every agent turn | Opportunistically mid-session |
| Scope | **Cross-project, about *you*** | Per-app, about anything | Mostly per-project, about the repo |
| Infra | None (local files) | Vector DB / server / SDK | Built-in |
| Output | Human-editable `CLAUDE.md` / `AGENTS.md` + ledger | API-queried embeddings | Agent-managed notes |

It's a *reflector*, not a *store*. It answers "who is this person and how do they
like to work" — then hands the agent a concise, hand-editable habits list.

## Supported agents

One skill, one algorithm; only the adapters differ.

| | Claude Code | Codex |
|---|---|---|
| Reads | `~/.claude/projects/*/*.jsonl`, `~/.claude/history.jsonl` | `~/.codex/sessions/**/*.jsonl`, `~/.codex/archived_sessions/`, `~/.codex/history.jsonl` (sub-agent sessions skipped) |
| Writes the block into | `~/.claude/CLAUDE.md` | `~/.codex/AGENTS.md` |
| Ledger (default) | `~/.claude/knowledge/habits/` | `~/.codex/knowledge/habits/` |
| Skill linked into | `~/.claude/skills/distill-habits` | `~/.codex/skills/distill-habits` |
| Manual trigger | `/distill-habits` | `$distill-habits` |
| Scheduled run | `claude -p --dangerously-skip-permissions` | `codex exec --ephemeral -s workspace-write -C ~/.codex` (sandboxed; nothing outside `~/.codex` is writable) |

Each agent keeps its own ledger by default. To share one, point `memory_dir` at
the same path for both; to let one learn from the other without sharing, use
`read_only_ledgers` (see [Configuration](#configuration)).

## How it works

1. Determine the window since the last run (`last-run` state, or `window_days` on first run).
2. Scan every project's transcripts and input history in that window.
3. Distill only **stable, reusable** signals (default: seen ≥ 2 times) into four
   categories — `user`, `feedback`, `project`, `reference`.
4. Write per-habit files into the **ledger** (dedup, keep superseded history).
5. Run a rotating **staleness audit** — the only path by which anything is ever removed.
6. Rewrite the sentinel-managed **habits block** within a character budget, under
   a zero-net-growth rule (leaving the rest of the file untouched).
7. Update the run state and print a short summary.

### Two layers, on purpose

The habits block is loaded **in full, on every single turn** — so it is budgeted
and holds decision rules only. The ledger is read on demand and holds the Why:
evidence, cases, dates, numbers, and how a belief was overturned. Every line in
the block can carry a `→slug` pointer to its ledger file, which is what makes it
safe to keep the block short.

Without that split, the block only ever grows. In one real 98-day run it went from
13 entries to 51 and from a few KB to ~105,000 characters, with zero deletions —
because a scheduled job only ever sees *today's* new material, and nothing ever
tells it to re-examine what's already there. Hence the staleness audit and the
character budget.

See [`docs/how-it-works.md`](docs/how-it-works.md) for the full design and
[`examples/`](examples/) for a before/after instructions file.

## Install (30 seconds)

```bash
git clone https://github.com/betayyang/agent-habit-distiller.git
cd agent-habit-distiller
./install/install.sh                 # links the skill + schedules a daily run per agent
```

- Installs for every agent whose CLI it finds. Pick one: `--agent claude`, `--agent codex`, or `--agent both`.
- **macOS**: schedules via `launchd`. **Linux**: via `cron`.
- Default time is 21:17 for Claude and 30 minutes later for Codex. Pick a time:
  `./install/install.sh --hour 21 --minute 30` (both agents then run at that time).
- Skip scheduling (skill only): `./install/install.sh --no-schedule`
- Codex CLI not on `PATH` (e.g. bundled inside a desktop app)? The installer also
  looks inside `Codex.app` / `ChatGPT.app`, or set `CODEX_BIN=/path/to/codex`.

Run it manually anytime:

```bash
~/.claude/skills/distill-habits/run.sh --agent claude   # headless, updates everything
~/.codex/skills/distill-habits/run.sh --agent codex
# or, inside an interactive session:
/distill-habits        # Claude Code
$distill-habits        # Codex
```

Uninstall (leaves your ledger + habits blocks in place):

```bash
./install/uninstall.sh               # both agents; or --agent claude|codex
```

### Upgrading from claude-habit-distiller

- `git pull` and re-run `./install/install.sh`. The Claude launchd label, sentinel
  markers and ledger path are unchanged, so nothing is lost.
- Run state (`last-run`, `last-audit`) and logs moved from the skill directory to
  `<ledger>/.state/<agent>/`, because the skill directory is now shared by both
  agents. The skill moves your old `.last-run` / `.last-audit` on its next run.
- The config path is now `~/.config/habit-distiller/config.toml`; the old
  `~/.config/claude-habit-distiller/config.toml` is still read.
- `write_global_claude_md` is now `write_global_instructions` (old name still honoured).

## Configuration

All knobs live in `~/.config/habit-distiller/config.toml` (see
[`config.example.toml`](config.example.toml)): language, look-back window,
stability threshold, character budget, whether to write the global block, project
exclusions, ledger location, and read-only ledgers. Top-level keys apply to both
agents; a `[claude]` or `[codex]` table overrides them for one agent.

Two notes if you installed an earlier version:

- **`max_habits` is deprecated**, replaced by `max_block_chars` / `max_entry_chars`.
  Capping the *line count* is the wrong axis — the model just grows the existing
  lines instead, so the count stays compliant while single entries balloon.
- **The Claude ledger moved** from `~/.claude/projects/<home-project>/memory/` to
  `~/.claude/knowledge/habits/`. The old location is isolated per project directory,
  so any session started from a git worktree or a second checkout got an empty one
  and could never read back what had been distilled. The skill migrates an existing
  install automatically on its next run and leaves a pointer file behind.

## Optional: notify on each run

Set `HABIT_DISTILLER_WEBHOOK` to a URL and the runner will POST a
`{"text": "..."}` summary after each run (Slack/Discord/Feishu-compatible).
Unset by default — nothing is sent anywhere.

## Privacy

This tool reads **only your local files** under `~/.claude` / `~/.codex` and makes
**no network requests** of its own (unless you opt into the webhook above). It
never uploads your conversations beyond the model calls your agent already makes.
Because it reads your entire conversation history, review [`PRIVACY.md`](PRIVACY.md)
and decide how sensitive your local logs are before use.

## License

MIT — see [LICENSE](LICENSE).
