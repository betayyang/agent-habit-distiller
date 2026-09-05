---
name: distill-habits
description: Review recent Claude Code conversations, distill the user's stable habits and preferences, persist them into a long-term habit ledger, and maintain a "My Habits" block in the global CLAUDE.md within a character budget. The more you use Claude Code, the more it knows you. Trigger manually with /distill-habits, or on a schedule via the installed cron/launchd job.
---

# distill-habits — automatic habit distillation

Goal: extract the **stable habits / preferences / feedback** a user shows across sessions and turn them into a long-term asset, so every future conversation starts out knowing them. One-off task details are **not** distilled — only reusable patterns.

## Two layers (keep the responsibilities separate)

| Layer | Location | How it loads | What belongs here |
|---|---|---|---|
| **Execution** | the sentinel block in `~/.claude/CLAUDE.md` | **loaded in full on every single turn** — has a hard character budget | The imperative. The one sentence the AI should just follow. |
| **Ledger** | `memory_dir` (see below) | read on demand, never auto-loaded | The Why, raw evidence, cases, dates, numbers, superseded conclusions, how a belief evolved |

**Core invariant: evidence, cases, dates and specific numbers live in the ledger only.** If they show up in the execution layer, that is the signal to push them down.

> **Why the ledger is not under `projects/<slug>/memory/`:** Claude Code isolates that directory *per project directory*. If a user works in git worktrees or multiple checkouts — most people do — every new working directory gets a fresh, empty memory dir, and everything ever distilled becomes unreadable. The ledger must live at a single fixed path instead.

## Paths and config

Config is read from `~/.config/claude-habit-distiller/config.toml` (or `./config.toml`), falling back to the built-in defaults.

- Conversation transcripts: `~/.claude/projects/<project-dir>/*.jsonl` (one file per session, across all projects)
- User input history: `~/.claude/history.jsonl` (each line has `display` / `timestamp` (ms) / `project` / `sessionId`)
- **Habit ledger**: `memory_dir`. When `"auto"`, use `~/.claude/knowledge/habits/`, with `INDEX.md` as its index. **Do not** resolve `"auto"` to a per-project memory dir — see the note above.
- **Execution layer**: the sentinel-managed region in `~/.claude/CLAUDE.md`
- Last-run timestamp: `<skill-dir>/.last-run` (Unix seconds; if absent, look back `window_days`)
- Audit cursor: `<skill-dir>/.last-audit`

### Migrating an existing install

If `memory_dir` resolves to `auto` and `~/.claude/knowledge/habits/` does not exist yet, but a legacy `~/.claude/projects/<home-project-dir>/memory/` does: move the `.md` files over, rename `MEMORY.md` to `INDEX.md`, and leave a short pointer file behind at the old path. Do this once, report it, and carry on.

## Character budget (hard constraint — it outranks "record one more thing")

```
max_block_chars = 25000   # whole CLAUDE.md habits block
max_entry_chars = 2000    # any single habit line
```

Measure **in characters, not bytes** — `wc -c` overstates CJK text by roughly 2.4x and will make a compliant block look 8x over budget:

```
awk '/^<!-- BEGIN habit-distiller/,/^<!-- END habit-distiller/' ~/.claude/CLAUDE.md | wc -m
```

These are ceilings, not targets. If 15,000 characters says it, don't write 25,000.

> `max_habits` (a line-count cap) is **deprecated**. Capping lines is the wrong axis: the model responds by stuffing new material into existing lines, so the line count looks fine while single entries grow without bound. Cap characters instead.

## Steps

### 1. Determine the window
Read `.last-run` (Unix seconds). If absent, start = `window_days` ago. End = now.

### 2. Collect material from the window
- Find `*.jsonl` transcripts modified after the window start, across **all** project dirs (skip anything in `exclude_projects`).
- Read them for: **user messages**, corrections the user gave, preferences they repeated, and approaches they explicitly endorsed.
- Also scan `history.jsonl` `display` entries in the window for what they ask about most and in what language.
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

### 4.5 Ledger hygiene (the ledger needs an exit too, or you've just moved the bloat)

The ledger has no total size cap — it isn't auto-loaded, so it can grow large without costing anything per turn. But keep it readable on demand:

1. **Split on mixed topics, not on size.** Ask: "after splitting, could I read just one half and be done?" If yes, split; if no, leave it. A single-thread timeline file is fine at any size — splitting it just means opening two files. Real signals to split: a filename containing `and`, or one file holding five-plus unrelated topics (a "junk drawer"). Use size only as a prompt to *look* (say, past 15,000 characters), never as the reason.
2. **Archive finished `project` entries.** When a workstream has shipped or been abandoned and won't come up again, move the file to `<memory_dir>/archive/` and drop it from `INDEX.md`. The test is "will this ever be raised again?" — if unsure, don't archive. It's a move, so it's always reversible.
3. **Store each fact once.** Before writing, grep for the key number or identifier. If another file already has it, link `[[that-file]]` instead of copying. Copies drift: they get updated independently and end up contradicting each other with no way to tell which is right.

When splitting, leave a "topics split out → [[new-file]]" line at the bottom of the original, and verify the character counts still add up.

### 5. Staleness audit (every run — this is the only path to deletion)

New material alone will never trigger a deletion, so run a rotating audit on top of it:

- Take the **3 longest** entries plus the **3 after the last audit position** (stored in `.last-audit`; wrap around at the end).
- For each, ask:
  1. Does it contain a claim that later facts have **superseded**? → remove that claim from the execution layer; the history stays in the ledger.
  2. Does it contain **evidence / cases / dates / numbers**? → push those down to the ledger, keep only the imperative.
  3. Is it over `max_entry_chars`? → it must be split: either push detail down, or break it into two independent habits.
- **Never delete without positive evidence that it's stale.** When in doubt, leave it and re-audit later.
- Write the new cursor back to `.last-audit`.

### 6. Maintain the execution layer (the CLAUDE.md block)

Only if `write_global_claude_md = true`. Write the currently most useful habits between the sentinels. **Only rewrite what's between the two markers**; leave the rest of the file untouched.

```
<!-- BEGIN habit-distiller (auto-managed · do not edit this block by hand) -->
## My Habits (auto-distilled · last updated <YYYY-MM-DD>)

- <habit, imperative, so the AI can just follow it>
- ...
<!-- END habit-distiller -->
```

Keep this pointer as the **first line** of the block:
```
- Habit ledger lives in `~/.claude/knowledge/habits/` (index: INDEX.md). This block holds decision rules only — read the ledger for the Why, the evidence and the cases.
```

Rules:
- Order by impact on day-to-day collaboration, high to low. Use `language` from config.
- Make each line actionable ("Default to Python for scripts" beats "likes Python").
- An entry may end with a short `→<slug>` pointer to its ledger file. **The pointer exists so you can afford to push detail down** — it isn't decoration.
- No cap on the number of entries; **cap characters only**. Forty short imperatives beat fifteen essays.

#### 6.1 Zero net growth (must hold on every run)

**The block must not be larger after the run than it was before.** To fold a new signal into an existing entry, push an equivalent amount of evidence out of that same entry and into the ledger. If you can't, the signal isn't ready for the execution layer — leave it in the ledger.

#### 6.2 Over budget

Measure the block after writing:

| State | Action |
|---|---|
| ≤ `max_block_chars` | Done |
| over by < 20% | **Push detail down now**, until it fits |
| over by ≥ 20% | This is accumulated backlog, not today's delta. **Do not attempt a large rewrite in a scheduled run** — just satisfy 6.1, then warn on the first line of the report and list what should be trimmed (which entries, by how much, into which ledger file). Wait for the user to run compact mode. |

**Hard rule: any text removed from the execution layer must land in a ledger file first.** Nothing may simply disappear. Report each trim as "entry N: X chars → Y chars, original text now in \<file\>".

### 7. Wrap up
- Write current Unix seconds into `.last-run`.
- Report (in `language`):
  - how many sessions were scanned
  - ledger files added / updated / deleted
  - **block characters: before → after / limit**, and whether zero net growth held
  - which entries were audited this run, and what was pushed down or deleted
  - **ledger health**: total size, any mixed-topic files, anything split or archived
  - the strongest signal of the run

## Compact mode (`/distill-habits --compact`, manual only)

For an execution layer that is already far over budget. **Never run this from the scheduled job:**

1. Back up: `cp ~/.claude/CLAUDE.md ~/.claude/.backup-CLAUDE-$(date +%Y%m%d%H%M%S).md`
2. Rewrite entry by entry: keep the decision rule and any negative constraints; push everything else into the matching ledger file (create it if needed).
3. Produce a **preview**: a table of "entry → old chars → new chars → which ledger file took the detail", plus the full rewritten block.
4. **Show the preview to the user and wait for approval before touching CLAUDE.md.**

## Principles
- Prefer fewer, higher-confidence entries: unsure whether it's a stable habit? Skip it; wait for more evidence.
- Layering: the execution layer holds decisions, the ledger holds the reasons. Both need an exit, not just an entrance.
- Idempotent: re-running over the same window must not create duplicates.
- Privacy: only reads the user's own local records; nothing is sent anywhere.
