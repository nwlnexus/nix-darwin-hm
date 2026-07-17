# OpenWiki Spike — Summary

**Decision (accepted 2026-07-17):** **Path O wins** — adopt openwiki code + OKF as Layer 1
narrative producer on Anthropic; keep Path C-style **syft inventory** only; keep gitnexus +
repomix; shared GitNexus MCP remains canonical (parent contract C). Do **not** use Studio Ollama
for openwiki wiki generation. OpenWiki personal mode stays rejected.

**Recommendation (from scorecards):** **Hybrid in the inventory sense** — Path O for narrative;
syft for deterministic inventory. Parent plan updated accordingly.

## Evidence
- **moneta:** Path O produced coherent OKF wiki (9 pages, 72 Moneta dry-run nuggets). Path C overview is fine but thin; syft inventory is the deterministic win.
- **olympus-sdk (monorepo):** Path O produced 22 pages in ~18 min on Anthropic, with **per-service pages** (`hermes`, `iris`, `heimdall`, `atlas`) — exactly the monorepo discoverability we wanted. Path C cannot match that shape.

## OpenWiki surprises / failures
- Studio Ollama (`qwen3.6:27b-mlx` via openai-compatible): **unstable / effectively unusable** for openwiki init (hangs, empty logs, competing processes, AGENTS.md mutated with no wiki).
- Anthropic works; still **multi-minute** (not seconds) for init — fine for push-to-main Jobs with coalescing, bad for interactive laptop sweeps.
- OpenWiki mutates `AGENTS.md` / `CLAUDE.md` and may add a GitHub Action — brain Job must strip or ignore those when publishing to the central brain repo.
- Concurrent openwiki processes corrupt a shared working tree — Job must serialize per repo (already planned).

## OKF / frontmatter fit
- OKF base (`type`, `title`, `description`, `tags`, `resource`) is Astro-ready.
- Stamp nwl extensions post-generation: `repo`, `owner`, `sha`, digests, `docType`, `brainPath`, `status`.
- Syft inventory stays a separate deterministic page (not LLM).

## Moneta dry-run fit
- Heading split works; Path O yields rich nugget sets (72 / 144).
- Provenance fields populate; no production `/capture` in spike.
- Inventory pages should contribute at most a short summary nugget (parent spec already says this).

## Proposed parent-spec edits (`2026-07-15-codebase-brain-pipeline-design.md`)
- §2 / §4.3: **Reopen #40 as adopt-as-doc-producer** (code mode only); reject personal mode still.
- §4.3 LLM: **Primary Anthropic (or cloud)** for openwiki; Studio Ollama optional only for tiny custom slots — not for openwiki init.
- §4.4 Content: replace custom overview/cluster templates with **openwiki OKF wiki**; keep **syft inventory**; optional gitnexus cluster supplements later.
- §5.1 Frontmatter: **OKF base + nwl extensions**.
- §9 Phased delivery: Job MVP still pack+graph+SBOM; MDX phase becomes openwiki+adapter+syft inventory+brain PR.

## Fleet reality check (~9 personal repos)
- Deterministic producers: tens of minutes fleet-wide (already proven).
- Openwiki narrative on Anthropic: order-of-magnitude **~1–3 hours** serial, **~30–90 min** at concurrency 2–3 — with digest skip + `--update` much cheaper on steady state.
- Studio Ollama for openwiki: **out**.
