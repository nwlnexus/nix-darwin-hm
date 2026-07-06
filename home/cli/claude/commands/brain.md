---
description: Consult or maintain the second-brain LLM wiki
argument-hint: "[ingest [path]] | <question>"
---

You are maintaining the second-brain wiki at `$SECOND_BRAIN_PATH`
(default `~/Documents/Obsidian Vault/brain`). ALWAYS read `SCHEMA.md` first.

Arguments: `$ARGUMENTS`

## Routing
- `ingest` (no path) → process every file with frontmatter `status: new` under `raw/_inbox/` (candidates written by the mnemosyne capture pipeline).
- `ingest <path>` → ingest just that file/URL (may be outside `_inbox`).
- anything else → treat `$ARGUMENTS` as a QUERY; answer from `wiki/`; if the wiki is thin, say so and suggest a source to ingest rather than inventing an answer.

## INGEST loop (per source)
1. `git -C "$SECOND_BRAIN_PATH" pull` first. Per SCHEMA DISCIPLINE, disable Obsidian Remotely Save Sync-On-Save (or confirm Obsidian is closed) before editing.
2. Read the source. Summarize key takeaways; confirm with the human before writing wiki pages.
3. Set the source frontmatter `status: ingested` (+ `ingested:` date).
4. Create/refresh entity/concept/synthesis pages under `wiki/<domain>/`; add `[[links]]` from the domain MOC so nothing is orphaned.
5. Append a dated entry to `log.md` (source, pages touched, decisions).
6. Run `node scripts/lint-brain.mjs`; fix every issue it reports.
7. Show the human the diff. On approval: check `git status` for UNEXPECTED deletions, restore any with `git checkout --`, stage only intended changes, commit, push. Keep restore→lint→commit→push tight so a background sync has no window.
