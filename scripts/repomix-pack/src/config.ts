import { RepoTarget } from "./types";

interface Toml {
  defaults?: { pack_path?: string; branch?: string };
  groups?: Record<string, { ssh_host: string; owner: string; repos: string[] }>;
  repo?: Record<string, { pack_path?: string; branch?: string; ci?: boolean }>;
}

export function loadTargets(
  tomlPath: string,
  opts: { group?: string; only?: string[] } = {},
): RepoTarget[] {
  const cfg = require(tomlPath) as Toml;
  const packDefault = cfg.defaults?.pack_path ?? ".llm/repomix.xml";
  const branchDefault = cfg.defaults?.branch ?? "automation/repomix-pack";
  const only = opts.only ? new Set(opts.only) : null;

  const out: RepoTarget[] = [];
  for (const [group, g] of Object.entries(cfg.groups ?? {})) {
    if (opts.group && opts.group !== group) continue;
    for (const name of g.repos) {
      const slug = `${g.owner}/${name}`;
      if (only && !only.has(slug)) continue;
      const override = cfg.repo?.[slug] ?? {};
      out.push({
        owner: g.owner,
        name,
        slug,
        sshHost: g.ssh_host,
        originUrl: `git@${g.ssh_host}:${g.owner}/${name}.git`,
        defaultBranch: null,
        packPath: override.pack_path ?? packDefault,
        branch: override.branch ?? branchDefault,
        group,
      });
    }
  }
  return out;
}
