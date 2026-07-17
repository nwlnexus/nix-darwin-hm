export const SIDE_EFFECT_PATTERNS = [
  /^AGENTS\.md$/i,
  /^CLAUDE\.md$/i,
  /^\.github\/workflows\/openwiki-.*\.yml$/i,
];

export function isPublishableWikiRel(rel: string): boolean {
  const norm = rel.replace(/\\/g, "/");
  if (SIDE_EFFECT_PATTERNS.some((re) => re.test(norm))) return false;
  if (!norm.endsWith(".md")) return false;
  if (norm.includes("/.git/")) return false;
  return true;
}
