import { mkdirSync } from "node:fs";
import { join, dirname } from "node:path";

export interface RepoMeta {
  slug: string; owner: string; name: string;
  commit: string; hash: string; bytes: number; ts: string;
}

export interface PackSink {
  write(packBytes: Uint8Array, meta: RepoMeta): Promise<void>;
}

export class StagingSink implements PackSink {
  constructor(private root: string) {}
  async write(packBytes: Uint8Array, meta: RepoMeta): Promise<void> {
    const xml = join(this.root, `${meta.owner}/${meta.name}.xml`);
    const json = join(this.root, `${meta.owner}/${meta.name}.json`);
    mkdirSync(dirname(xml), { recursive: true });
    await Bun.write(xml, packBytes);
    await Bun.write(json, JSON.stringify(meta, null, 2));
  }
}
