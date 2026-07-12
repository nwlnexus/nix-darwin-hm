import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

export function resolveGhTokenForGroup(group: string, homeDir?: string): string | undefined {
  const home = homeDir ?? process.env.HOME ?? "";
  if (!home) return undefined;

  const envPath = join(home, "projects", group, ".env");
  if (!existsSync(envPath)) return undefined;

  const content = readFileSync(envPath, "utf-8");
  for (const line of content.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq < 0) continue;
    const key = trimmed.slice(0, eq).trim();
    if (key !== "GITHUB_PERSONAL_ACCESS_TOKEN") continue;
    let value = trimmed.slice(eq + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"'))
      || (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    return value || undefined;
  }
  return undefined;
}

export async function withGhTokenForGroup<T>(
  group: string,
  fn: () => Promise<T>,
  homeDir?: string,
): Promise<T> {
  const prev = process.env.GH_TOKEN;
  const token = resolveGhTokenForGroup(group, homeDir);
  if (token) process.env.GH_TOKEN = token;
  try {
    return await fn();
  } finally {
    if (token) {
      if (prev === undefined) delete process.env.GH_TOKEN;
      else process.env.GH_TOKEN = prev;
    }
  }
}
