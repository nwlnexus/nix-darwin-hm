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
