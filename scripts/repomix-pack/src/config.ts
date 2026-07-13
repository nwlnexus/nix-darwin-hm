import { homedir } from "node:os";
import { join } from "node:path";
import { RepoTarget } from "./types";

interface Toml {
  defaults?: { pack_path?: string; branch?: string };
  groups?: Record<string, { base_dir: string; ssh_host: string; owner: string; repos: string[] }>;
  repo?: Record<
    string,
    { pack_path?: string; branch?: string; ci?: boolean; graph?: boolean }
  >;
}

function expandHome(p: string): string {
  return p.startsWith("~") ? join(homedir(), p.slice(1)) : p;
}

/**
 * The gitnexus registry alias is the BARE REPO NAME (`target.name`), not the
 * `owner/name` slug -- gitnexus's own `-r <name>` resolution is name-keyed, and
 * `--allow-duplicate-name` would make it ambiguous.
 *
 * So the name is a primary key across the whole toml, and the pipeline treats it
 * as one: refreshGraph registers under it, and pruneGraphs DELETES registry
 * entries BY NAME. Two repos sharing a name under different owners
 * (`acme/widget` + `globex/widget`) would silently fight over one alias, and a
 * prune could drop the wrong one's entry. No collision exists today (all 11
 * names are unique), and this makes sure one can never be introduced quietly:
 * a duplicate is a config error and stops the sweep at load, before anything
 * has been analyzed, registered or deleted.
 *
 * Checked against the WHOLE toml, never the --group/--only subset: a collision
 * is a property of the config, not of one run's filter.
 */
function assertUniqueAliases(all: RepoTarget[]): void {
  const seen = new Map<string, string>();
  for (const t of all) {
    const prev = seen.get(t.name);
    if (prev) {
      throw new Error(
        `repos.toml: duplicate repo name "${t.name}" (${prev} and ${t.slug}). ` +
          `The gitnexus registry alias is the bare repo name, so names must be ` +
          `unique across ALL groups.`,
      );
    }
    seen.set(t.name, t.slug);
  }
}

export function loadTargets(
  tomlPath: string,
  opts: { group?: string; only?: string[] } = {},
): RepoTarget[] {
  const cfg = require(tomlPath) as Toml;
  const packDefault = cfg.defaults?.pack_path ?? ".llm/repomix.xml";
  const branchDefault = cfg.defaults?.branch ?? "automation/repomix-pack";
  const only = opts.only ? new Set(opts.only) : null;

  const all: RepoTarget[] = [];
  for (const [group, g] of Object.entries(cfg.groups ?? {})) {
    for (const name of g.repos) {
      const slug = `${g.owner}/${name}`;
      const override = cfg.repo?.[slug] ?? {};
      all.push({
        owner: g.owner,
        name,
        slug,
        sshHost: g.ssh_host,
        originUrl: `git@${g.ssh_host}:${g.owner}/${name}.git`,
        defaultBranch: null,
        packPath: override.pack_path ?? packDefault,
        branch: override.branch ?? branchDefault,
        group,
        graph: override.graph ?? true,
        devClonePath: join(expandHome(g.base_dir), name),
      });
    }
  }
  assertUniqueAliases(all);

  return all.filter(
    (t) => (!opts.group || opts.group === t.group) && (!only || only.has(t.slug)),
  );
}
