import { $ } from "bun";

export function buildSlackPayload(p: {
  slug: string; base: string; prUrl: string; created: boolean; bytes: number;
}): object {
  const verb = p.created ? "opened" : "updated";
  return {
    text: `repomix pack ${verb} for *${p.slug}* → <${p.prUrl}|review PR> (${p.bytes} bytes on ${p.base})`,
  };
}

export interface Adoption {
  slug: string;
  /** `branches` registrations the dropped entry carried. Gone for good. */
  droppedBranches: number;
  /** The old storagePath, now orphaned on disk. We never delete it. */
  orphanedStorage: string;
  /** Size of that orphaned storage, so "delete it" has a price tag. */
  bytes: number;
}

export function humanBytes(bytes: number): string {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let n = bytes;
  let i = 0;
  while (n >= 1024 && i < units.length - 1) {
    n /= 1024;
    i++;
  }
  const rounded = i === 0 ? String(n) : n.toFixed(n >= 100 ? 0 : 1);
  return `${rounded} ${units[i]}`;
}

/**
 * Say, in plain words, what an adoption COST -- because it is lossy, permanent,
 * and invisible otherwise.
 *
 * On its first sweep a repo already registered against its own dev clone gets
 * adopted: the entry is re-pointed at the pipeline's cache, which permanently
 * drops any multi-branch index registrations it carried and leaves its previous
 * on-disk index orphaned (we never delete under ~/projects/**). The user has to
 * be told: it is their disk and their branch indexes.
 */
export function formatAdoption(a: Adoption): string {
  const lost =
    a.droppedBranches === 1
      ? "1 multi-branch index no longer registered; "
      : a.droppedBranches > 1
        ? `${a.droppedBranches} multi-branch indexes no longer registered; `
        : "";
  return (
    `adopted ${a.slug}: ${lost}previous index left at ` +
    `${a.orphanedStorage} (${humanBytes(a.bytes)}) -- delete it to reclaim space` +
    (a.droppedBranches > 0 ? ", or re-index that branch." : ".")
  );
}

export function buildAdoptionPayload(a: Adoption): object {
  return { text: `:warning: gitnexus graph — ${formatAdoption(a)}` };
}

/**
 * One post per sweep for a broken graph stage -- NOT one per repo. The failure
 * mode this exists to catch is systemic (a binary that doesn't resolve under
 * launchd breaks all 11 at once), so per-repo posts would be 11 copies of the
 * same news. Each repo's own error is still listed, because "gitnexus analyze
 * failed on marquee" and "gitnexus not found" want very different responses.
 */
export function buildGraphFailurePayload(g: {
  failed: { slug: string; error: string }[];
  pruneFailed?: string;
}): object {
  const lines = g.failed.map((f) => `• *${f.slug}*: ${f.error}`);
  if (g.pruneFailed) lines.push(`• *prune*: ${g.pruneFailed}`);
  const n = g.failed.length;
  const head =
    n > 0
      ? `:rotating_light: gitnexus graph FAILED for ${n} repo${n === 1 ? "" : "s"} — packs unaffected, graphs are stale`
      : ":rotating_light: gitnexus graph prune FAILED — packs unaffected";
  return { text: [head, ...lines].join("\n") };
}

export async function resolveWebhook(): Promise<string> {
  if (process.env.SLACK_WEBHOOK) return process.env.SLACK_WEBHOOK;
  const op = await $`op read op://Dev/repomix-pipeline/slack_webhook`.text().catch(() => "");
  return op.trim();
}

export async function notifySlack(webhook: string, payload: object): Promise<void> {
  if (!webhook) return;
  await fetch(webhook, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload),
  });
}
