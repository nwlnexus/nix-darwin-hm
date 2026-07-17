# Scorecard — olympus-sdk

**SHA:** b915f545a99d06f9d38dc1c70068aef7a328dfb6
**LLM (final):** Anthropic `claude-sonnet-4-5`

| Dimension | Path O (openwiki OKF) | Path C (custom) | Notes |
| --- | --- | --- | --- |
| Coverage | Strong — 22 pages | Thin overview + huge syft table | Path O much better for navigation |
| Monorepo shape | **Excellent** — `services/{hermes,iris,heimdall,atlas}.md`, packages called out in plan/index | Flat single overview; packages buried | Path O wins monorepo test |
| Determinism | Narrative; service pages cite package paths | Inventory from syft (2091 components) | Hybrid: openwiki narrative + syft inventory |
| Frontmatter / OKF fit | Good OKF; `type: Service` per package | Extended frontmatter present | Astro can consume both with adapter |
| Moneta fit | 144 nuggets | 3 nuggets | Path O dominates recall surface |
| Cost/ops | ~18 min wall-clock on Anthropic for full init | ~1 min | Fleet: expect 10–20 min/large monorepo |
| Diff friendliness | Full init expensive; rely on `--update` + digest gate | Cheap full regen | Prod must not full-init every push |

**Artifact pointers:** openwiki-okf/ (22 md), custom-mdx/, moneta-dry-run.openwiki.json (144), moneta-dry-run.custom.json (3)
