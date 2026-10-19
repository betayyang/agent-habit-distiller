---
name: distill-habits
description: Review recent coding-agent conversations (Claude Code or Codex), distill the user's stable habits and preferences, persist them into a long-term habit ledger, and maintain a "My Habits" block in the agent's global instructions file (CLAUDE.md or AGENTS.md) within a character budget. The more you use the agent, the more it knows you. Trigger manually with /distill-habits (Claude Code) or $distill-habits (Codex), or on a schedule via the installed cron/launchd job.
---

# distill-habits — automatic habit distillation

Goal: extract the **stable habits / preferences / feedback** a user shows across sessions and turn them into a long-term asset, so every future conversation starts out knowing them. One-off task details are **not** distilled — only reusable patterns.

## 0. Which agent am I running for?

This one skill serves two agents. Everything below is written against the placeholders in this table — resolve them first and use only your column.

- The headless runner states the agent explicitly in its prompt (`agent=claude` / `agent=codex`). That wins.
- Otherwise: if you are Codex (invoked as `$distill-habits`, skill loaded from `~/.codex/skills/`), use **codex**; if you are Claude Code, use **claude**.

| Placeholder | claude | codex |
|---|---|---|
| `<HOME>` | `$CLAUDE_CONFIG_DIR` or `~/.claude` | `$CODEX_HOME` or `~/.codex` |
| `<INSTRUCTIONS>` (execution layer) | `<HOME>/CLAUDE.md` | `<HOME>/AGENTS.md` |
| Transcripts | `<HOME>/projects/<project-dir>/*.jsonl`, one file per session | `<HOME>/sessions/YYYY/MM/DD/rollout-*.jsonl`, plus `<HOME>/archived_sessions/*.jsonl` |
| Input history | `<HOME>/history.jsonl` — `display`, `timestamp` (ms), `project`, `sessionId` | `<HOME>/history.jsonl` — `text`, `ts` (s), `session_id` |
| Project of a session | the `<project-dir>` folder name | `session_meta.payload.cwd` (first line of the file) |
| Default ledger (`memory_dir = "auto"`) | `<HOME>/knowledge/habits/` | `<HOME>/knowledge/habits/` |
| State dir | `<ledger>/.state/claude/` | `<ledger>/.state/codex/` |

### Reading Codex transcripts correctly

Codex rollout files are JSONL with a top-level `type` and a `payload`:

- **The user's words**, per session:
  - If the session has any `type=event_msg` with `payload.type=user_message`, use those (`payload.message`) and ignore `role=user` response items — they repeat the same text, so **don't count it twice**.
  - Otherwise (older CLI versions only log the turn input), use `type=response_item`, `payload.role=user`, the `input_text` parts of `payload.content`. Drop parts that are context injected by the harness, not typed by the user: anything starting with `<` (`<environment_context>`, `<user_instructions>`, `<recommended_plugins>`, `<image …>`, `</image>`), `# AGENTS.md instructions for …`. IDE messages that start with `# Files mentioned by the user:` keep only the text after `## My request for Codex:`.
  - `role=developer` items, `turn_context`, tool calls and tool output are never user preference.
- The assistant's replies (`event_msg` / `agent_message`) are context only — use them to understand what the user was correcting or endorsing.
- **Skip sub-agent sessions entirely**: if `session_meta.payload.source` is an object with a `subagent` key (e.g. `guardian` approval reviews, `thread_spawn` children), the "user" messages in it were written by an agent, not the user.
- Sessions with `originator = codex_exec` are **kept** — wrappers and bots often relay real user messages through `codex exec`. The distiller's own runs are started with `--ephemeral` and leave no rollout file; if you ever see a session whose first user message starts with `[habit-distiller run]`, skip it.
- Window by the per-line `timestamp` (ISO-8601 UTC); file mtime is only a coarse prefilter.

## Two layers (keep the responsibilities separate)

| Layer | Location | How it loads | What belongs here |
|---|---|---|---|
| **Execution** | the sentinel block in `<INSTRUCTIONS>` | **loaded in full on every single turn** — has a hard character budget | The imperative. The one sentence the AI should just follow. |
| **Ledger** | `memory_dir` (see below) | read on demand, never auto-loaded | The Why, raw evidence, cases, dates, numbers, superseded conclusions, how a belief evolved |

**Core invariant: evidence, cases, dates and specific numbers live in the ledger only.** If they show up in the execution layer, that is the signal to push them down.

> **Why the ledger is not under Claude's `projects/<slug>/memory/`:** Claude Code isolates that directory *per project directory*. If a user works in git worktrees or multiple checkouts — most people do — every new working directory gets a fresh, empty memory dir, and everything ever distilled becomes unreadable. The ledger must live at a single fixed path instead.

## Paths and config

Config is read from the first file that exists: `~/.config/habit-distiller/config.toml`, `~/.config/claude-habit-distiller/config.toml` (legacy), `./config.toml`. Missing keys fall back to the built-in defaults. Top-level keys apply to both agents; a `[claude]` or `[codex]` table overrides them for that agent only.

- **Habit ledger**: `memory_dir`. When `"auto"`, use the default ledger from the table above, with `INDEX.md` as its index. **Do not** resolve `"auto"` to a per-project memory dir.
- **Read-only ledgers**: `read_only_ledgers` (list of paths, default empty). Other ledgers — typically the other agent's — that you may consult when deciding whether a signal is already known or stable. Never write to them. If you carry a conclusion over, write it into your own ledger with a `source:` line naming the file it came from.
- **Execution layer**: the sentinel-managed region in `<INSTRUCTIONS>`.
- Last-run timestamp: `<state>/last-run` (Unix seconds; if absent, look back `window_days`).
- Audit cursor: `<state>/last-audit`.
- Also in `<state>/`, owned by the headless runner — **never write these yourself**: `run.log`, `last-exec.log`, `last-summary.txt`, `block-size.tsv`.

State lives next to the ledger, not in the skill directory, because the skill directory is shared by both agents (and may be read-only to a sandboxed run).

### Migrating an existing install (claude only)

Do each of these once, report it, and carry on:

- If `memory_dir` resolves to `auto` and `<HOME>/knowledge/habits/` does not exist yet, but a legacy `<HOME>/projects/<home-project-dir>/memory/` does: move the `.md` files over, rename `MEMORY.md` to `INDEX.md`, and leave a short pointer file behind at the old path.
- Legacy run state (`.last-run` / `.last-audit` in the skill directory) is moved into `<state>/` by the headless runner before you start; you don't need to do it.

## Character budget (hard constraint — it outranks "record one more thing")

```
max_block_chars = 25000   # whole habits block
max_entry_chars = 2000    # any single habit line
```

Measure **in characters, not bytes** — `wc -c` overstates CJK text by roughly 2.4x and will make a compliant block look 8x over budget. Don't rely on `wc -m` either: in a shell with no locale (launchd, cron, many sandboxes) it silently counts bytes too. Count with Python:

```
awk '/^<!-- BEGIN habit-distiller/,/^<!-- END habit-distiller/' <INSTRUCTIONS> \
  | python3 -c 'import sys; print(len(sys.stdin.buffer.read().decode("utf-8")))'
```

These are ceilings, not targets. If 15,000 characters says it, don't write 25,000.

> `max_habits` (a line-count cap) is **deprecated**. Capping lines is the wrong axis: the model responds by stuffing new material into existing lines, so the line count looks fine while single entries grow without bound. Cap characters instead.

## Steps

### 1. Determine the window
Read `<state>/last-run` (Unix seconds). If absent, start = `window_days` ago. End = now.

### 2. Collect material from the window
- Find transcripts with activity after the window start, across **all** projects (skip anything in `exclude_projects` — matched against the claude project-dir name, or against the codex session `cwd`).
- Read them for: **user messages**, corrections the user gave, preferences they repeated, and approaches they explicitly endorsed.
- Also scan in-window input-history entries for what they ask about most and in what language.
- With a lot of material, prioritize the most recent and highest-signal; you do not have to read every file end to end.

### 3. Distill (this is the core judgment)
Only distill things that are **stable and reusable**, in four categories matching the ledger `type`:
- `user`: who they are — language, stack preferences, role, communication style.
- `feedback`: how they want the AI to work — corrections and endorsements. **Must include Why + How to apply.**
- `project`: cross-session goals or constraints. Convert relative dates to absolute.
- `reference`: pointers to external resources (URLs, dashboards, docs).

**Threshold**: a signal must appear at least `min_occurrences` times, or the user must have said "always do this" / "remember this". Skip one-offs, pure task details, and anything git or the code already records.

### 4. Write to the ledger (with provenance, no length limit)
In `memory_dir`:
- **Check for duplicates first** — if a file already covers it, **update** that file (add evidence, raise confidence) instead of creating a near-duplicate.
- When a conclusion is **superseded**, keep the history in the ledger ("X was replaced by Y on <date>, because Z") but leave only the current conclusion in the execution layer.
- File format:
  ```markdown
  ---
  name: <kebab-case-slug>
  description: <one line, used to judge relevance on recall>
  metadata:
    type: user | feedback | project | reference
  ---

  <the fact itself. For feedback/project, append **Why:** and **How to apply:** lines. Link related entries with [[other-name]].>
  ```
- Add/update a pointer line in `INDEX.md`: `- [Title](file.md) — hook`.
- **The ledger holds habits only.** Never create run logs, audit records or "nothing changed today" notes in it — not in `archive/` either. What happened in a run belongs in the report (step 7), which the runner stores in `<state>/`.
- If two agents share one ledger (`memory_dir` set to the same path for both), re-read `INDEX.md` right before writing it and merge rather than overwrite.

### 4.5 Ledger hygiene (the ledger needs an exit too, or you've just moved the bloat)

The ledger has no total size cap — it isn't auto-loaded, so it can grow large without costing anything per turn. But keep it readable on demand:

1. **Split on mixed topics, not on size.** Ask: "after splitting, could I read just one half and be done?" If yes, split; if no, leave it. A single-thread timeline file is fine at any size — splitting it just means opening two files. Real signals to split: a filename containing `and`, or one file holding five-plus unrelated topics (a "junk drawer"). Use size only as a prompt to *look* (say, past 15,000 characters), never as the reason.
2. **Archive finished `project` entries.** When a workstream has shipped or been abandoned and won't come up again, move the file to `<memory_dir>/archive/` and drop it from `INDEX.md`. The test is "will this ever be raised again?" — if unsure, don't archive. It's a move, so it's always reversible.
3. **Store each fact once.** Before writing, grep for the key number or identifier. If another file already has it, link `[[that-file]]` instead of copying. Copies drift: they get updated independently and end up contradicting each other with no way to tell which is right.

When splitting, leave a "topics split out → [[new-file]]" line at the bottom of the original, and verify the character counts still add up.

### 5. Staleness audit (every run — this is the only path to deletion)

New material alone will never trigger a deletion, so run a rotating audit on top of it:

- Take the **3 longest** entries plus the **3 after the last audit position** (stored in `<state>/last-audit`; wrap around at the end).
- For each, ask:
  1. Does it contain a claim that later facts have **superseded**? → remove that claim from the execution layer; the history stays in the ledger.
  2. Does it contain **evidence / cases / dates / numbers**? → push those down to the ledger, keep only the imperative.
  3. Is it over `max_entry_chars`? → it must be split: either push detail down, or break it into two independent habits.
- **Never delete without positive evidence that it's stale.** When in doubt, leave it and re-audit later.
- Write the new cursor back to `<state>/last-audit`.

### 6. Maintain the execution layer (the habits block)

Only if `write_global_instructions = true` (legacy name: `write_global_claude_md`). Write the currently most useful habits between the sentinels in `<INSTRUCTIONS>`. **Only rewrite what's between the two markers**; leave the rest of the file untouched. If the file or the block does not exist yet, create it.

```
<!-- BEGIN habit-distiller (auto-managed · do not edit this block by hand) -->
## My Habits (auto-distilled · last updated <YYYY-MM-DD>)

- <habit, imperative, so the AI can just follow it>
- ...
<!-- END habit-distiller -->
```

Keep this pointer as the **first line** of the block (with your actual ledger path):
```
- Habit ledger lives in `<ledger>` (index: INDEX.md). This block holds decision rules only — read the ledger for the Why, the evidence and the cases.
```

Rules:
- Order by impact on day-to-day collaboration, high to low. Use `language` from config.
- Make each line actionable ("Default to Python for scripts" beats "likes Python").
- An entry may end with a short `→<slug>` pointer to its ledger file. **The pointer exists so you can afford to push detail down** — it isn't decoration.
- No cap on the number of entries; **cap characters only**. Forty short imperatives beat fifteen essays.

#### 6.1 Zero net growth (must hold on every run)

On the very first run there is no block yet: create a lean one well within budget. After that, **the block must not be larger after the run than it was before.** To fold a new signal into an existing entry, push an equivalent amount of evidence out of that same entry and into the ledger. If you can't, the signal isn't ready for the execution layer — leave it in the ledger.

#### 6.2 Over budget

Measure the block after writing:

| State | Action |
|---|---|
| ≤ `max_block_chars` | Done |
| over by < 20% | **Push detail down now**, until it fits |
| over by ≥ 20% | This is accumulated backlog, not today's delta. **Do not attempt a large rewrite in a scheduled run** — just satisfy 6.1, then warn on the first line of the report and list what should be trimmed (which entries, by how much, into which ledger file). Wait for the user to run compact mode. |

**Hard rule: any text removed from the execution layer must land in a ledger file first.** Nothing may simply disappear. Report each trim as "entry N: X chars → Y chars, original text now in \<file\>".

### 7. Wrap up
- Write current Unix seconds into `<state>/last-run`.
- Report (in `language`):
  - which agent, and how many sessions were scanned
  - ledger files added / updated / deleted
  - **block characters: before → after / limit**, and whether zero net growth held
  - which entries were audited this run, and what was pushed down or deleted
  - **ledger health**: total size, any mixed-topic files, anything split or archived
  - the strongest signal of the run

## Compact mode (`--compact`, manual only)

For an execution layer that is already far over budget. **Never run this from the scheduled job:**

1. Back up: `cp <INSTRUCTIONS> <HOME>/.backup-$(basename <INSTRUCTIONS> .md)-$(date +%Y%m%d%H%M%S).md`
2. Rewrite entry by entry: keep the decision rule and any negative constraints; push everything else into the matching ledger file (create it if needed).
3. Produce a **preview**: a table of "entry → old chars → new chars → which ledger file took the detail", plus the full rewritten block.
4. **Show the preview to the user and wait for approval before touching `<INSTRUCTIONS>`.**

## Principles
- Prefer fewer, higher-confidence entries: unsure whether it's a stable habit? Skip it; wait for more evidence.
- Layering: the execution layer holds decisions, the ledger holds the reasons. Both need an exit, not just an entrance.
- Idempotent: re-running over the same window must not create duplicates.
- Privacy: only reads the user's own local records. Everything you read goes to your model provider, so never copy secrets you come across (tokens, webhook URLs, passwords) into the ledger or the block.
