# Scorecard — moneta

**SHA:** 9b1ca2ff2af0fdd9576e281bdcc0451df161915a
**LLM (final):** Anthropic `claude-sonnet-4-5` (Studio Ollama abandoned after hang/zero pages)

| Dimension | Path O (openwiki OKF) | Path C (custom) | Notes |
| --- | --- | --- | --- |
| Coverage | Strong — 9 pages (quickstart, architecture, memory/*, auth, deploy, MCP) | Thin but useful — TL;DR/Architecture/Gotchas + syft inventory | Path O wins for human/agent browsing |
| Monorepo shape | N/A (single service) | N/A | — |
| Determinism | Narrative only; no SBOM table | Inventory matches syft (731 components) | Keep syft for inventory always |
| Frontmatter / OKF fit | Excellent OKF (`type`, `title`, `description`, `tags`, `resource`) | OKF-like + nwl extensions (`repo`, `sha`, `docType`, `brainPath`) | Adapter = stamp nwl fields onto OKF |
| Moneta fit | 72 heading nuggets; recall-worthy | 3 nuggets from overview slots | Path O richer for memory |
| Cost/ops | Studio: hang/zero pages. Anthropic: ~12m for usable wiki (interrupted once; still good) | ~30–60s overview + instant inventory | **Cloud LLM required for Path O** |
| Diff friendliness | Multi-page wiki; `--update` designed for diffs | Tiny surface area | Path C cheaper to regen |

**Artifact pointers:** openwiki-okf/ (9 md), custom-mdx/, moneta-dry-run.openwiki.json (72), moneta-dry-run.custom.json (3)
