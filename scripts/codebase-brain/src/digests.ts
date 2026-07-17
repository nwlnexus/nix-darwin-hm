import { createHash } from "node:crypto";
import type { Digests } from "./types";

export const TEMPLATE_VERSION = "openwiki-0.2";

export function sha256Hex(input: string | Uint8Array): string {
  const h = createHash("sha256");
  h.update(typeof input === "string" ? Buffer.from(input) : input);
  return `sha256:${h.digest("hex")}`;
}

export async function fileDigest(path: string): Promise<string> {
  const bytes = new Uint8Array(await Bun.file(path).arrayBuffer());
  return sha256Hex(bytes);
}

export function shouldSkipLlm(current: Digests, previous: Digests | null): boolean {
  if (!previous) return false;
  return (
    current.packHash === previous.packHash &&
    current.graphDigest === previous.graphDigest &&
    current.sbomDigest === previous.sbomDigest &&
    current.templateVersion === previous.templateVersion
  );
}

export async function parseDigestsMarker(raw: unknown): Promise<Digests | null> {
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  const candidate = (obj.digests ?? obj) as Record<string, unknown>;
  if (
    typeof candidate.packHash === "string" &&
    typeof candidate.graphDigest === "string" &&
    typeof candidate.sbomDigest === "string" &&
    typeof candidate.templateVersion === "string"
  ) {
    return {
      packHash: candidate.packHash,
      graphDigest: candidate.graphDigest,
      sbomDigest: candidate.sbomDigest,
      templateVersion: candidate.templateVersion,
    };
  }
  return null;
}
