import { createHash } from "node:crypto";

export function contentHash(bytes: Uint8Array | string): string {
  return createHash("sha256").update(bytes).digest("hex");
}
