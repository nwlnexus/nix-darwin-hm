import { describe, expect, test } from "bun:test";
import { renderInventory } from "./inventory";

describe("renderInventory", () => {
  test("sorts components and builds table", () => {
    const md = renderInventory({
      components: [
        { name: "zod", version: "3.0.0", type: "library" },
        { name: "bun", version: "1.2.0", type: "library" },
      ],
    });
    expect(md).toContain("| bun | 1.2.0 | library |");
    expect(md).toContain("| zod | 3.0.0 | library |");
    expect(md.indexOf("bun")).toBeLessThan(md.indexOf("zod"));
  });
});
