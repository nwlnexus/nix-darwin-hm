import { $ } from "bun";

export function buildSlackPayload(p: {
  slug: string; base: string; prUrl: string; created: boolean; bytes: number;
}): object {
  const verb = p.created ? "opened" : "updated";
  return {
    text: `repomix pack ${verb} for *${p.slug}* → <${p.prUrl}|review PR> (${p.bytes} bytes on ${p.base})`,
  };
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
