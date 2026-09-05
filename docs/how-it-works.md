# How it works

`claude-habit-distiller` is a **reflection job**, not a memory store. It runs on a
schedule, reads your own Claude Code logs, and produces a curated, human-editable
profile of how you like to work.

## The pipeline

```
last run ──► scan transcripts + history ──► distill (≥ N occurrences)
                                                   │
                        ┌──────────────────────────┴───────────────────────┐
                        ▼                                                    ▼
              ledger (on demand)          ◄── push detail down ───   "My Habits" in CLAUDE.md
      ~/.claude/knowledge/habits/*.md      ─── →slug pointers ──►     (every turn, budgeted)
        Why · evidence · history                                     decision rules only
                        ▲                                                    │
                        └──────────  staleness audit (rotating)  ◄───────────┘
```

### 1. Window
The skill reads `.last-run` (Unix seconds). On first run it looks back
`window_days` (default 7). Everything modified since then is in scope. This makes
runs **incremental and idempotent** — re-running the same window won't duplicate.

### 2. Collect
It finds every `*.jsonl` transcript across **all** project directories modified in
the window, plus in-window entries from `history.jsonl`. It weights **user
messages, corrections, repeated preferences, and praised approaches** most heavily.

### 3. Distill — the core judgment
A signal only becomes a habit if it appears at least `min_occurrences` times, or
you explicitly said "always do this / remember this". One-off task details and
anything already captured in code/git are dropped. Each survivor is filed under
one of four types:

| type | captures | extra fields |
|---|---|---|
| `user` | who you are — language, stack, role, style | — |
| `feedback` | how you want the AI to work | **Why** + **How to apply** |
| `project` | cross-session goals / constraints | absolute dates |
| `reference` | external resources (URLs, dashboards) | — |

### 4. The ledger
Each habit is one markdown file in `~/.claude/knowledge/habits/`, with frontmatter
(`name`, `description`, `type`) and a body. The skill **dedups against existing
files** — updating and raising confidence rather than duplicating. When a
conclusion is overturned, the ledger keeps the history ("X was replaced by Y on
\<date\>, because Z"); only the execution layer drops the old claim. `INDEX.md`
carries one pointer line per habit.

The ledger is deliberately **not** under `projects/<slug>/memory/`: that path is
isolated per project directory, so a session started from a git worktree or a
second checkout sees an empty one. Everything distilled would be unreadable from
exactly the sessions that need it most.

The ledger has no size cap — it isn't auto-loaded. It does get hygiene rules:
split files whose topics have become mixed (ask "could I read just half of this
and be done?"), archive finished `project` entries, and store each fact once with
`[[links]]` rather than copies that drift apart.

### 5. Staleness audit
A scheduled job only ever sees *today's* material, so nothing would ever prompt it
to re-examine what's already stored — deletion never happens on its own. Each run
therefore audits a rotating slice: the 3 longest entries plus the 3 after the last
cursor position. For each it asks whether some claim has been superseded, whether
evidence should be pushed down to the ledger, and whether the entry is over
`max_entry_chars`. Nothing is deleted without positive evidence that it's stale.

### 6. CLAUDE.md habits block (the execution layer)
The most useful habits are rendered as concise imperatives between:

```
<!-- BEGIN habit-distiller (auto-managed · do not edit this block by hand) -->
...
<!-- END habit-distiller -->
```

Only this region is rewritten; the rest of your `CLAUDE.md` is preserved. Because
it's plaintext, you can hand-edit or delete it anytime.

This block is loaded **in full on every turn**, so it is governed by a character
budget (`max_block_chars`, `max_entry_chars`) and a **zero-net-growth** rule: to
fold in a new signal, an equivalent amount of evidence must be pushed out of that
same entry and into the ledger. Anything removed from the block must land in a
ledger file first — nothing may simply disappear.

Measure the block in **characters, not bytes**: `wc -c` overstates CJK text by
roughly 2.4x, which is enough to make a compliant block look 8x over budget.

Why the budget exists: capping the *number of entries* (the old `max_habits`) is
the wrong axis. In one real 98-day run the block went from 13 entries to 51 while
growing to ~105,000 characters, with zero deletions across 98 scheduled runs —
the line cap simply pushed new material into existing lines. A single entry had
reached 30,000 characters, a quarter of the whole block.

## Design principles
- **Prefer fewer, higher-confidence entries.** Unsure it's stable? Skip it; wait for more evidence.
- **Two layers.** `CLAUDE.md` is the budgeted view Claude loads every turn; the ledger is the detailed record with the *why*.
- **Both layers need an exit, not just an entrance.** An append-only memory is just a slower leak.
- **Idempotent.** Re-running over the same window produces no duplicates.
- **Private.** Reads only local records; sends nothing over the network.

## Why not just use native auto-memory?
Claude Code's built-in auto-memory records useful facts *opportunistically during a
session*, scoped to *the project* ("the build command that works here"). This tool
is complementary: it runs *between* sessions, looks *across all projects*, and
builds a profile of *you* — communication style, recurring corrections, standing
preferences — that no single session would surface.
