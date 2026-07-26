import { describe, expect, it } from "vitest";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const product = join(root, "..");

describe("package artifacts", () => {
  it("ships schema, prompts, SPEC; product has src-tauri", () => {
    expect(existsSync(join(root, "schema/schema.sql"))).toBe(true);
    for (const name of ["checkin", "analyze", "monitor", "brief"]) {
      expect(existsSync(join(root, `prompts/${name}.md`))).toBe(true);
    }
    expect(existsSync(join(root, "SPEC_STATE_MACHINE.md"))).toBe(true);
    expect(existsSync(join(product, "src-tauri"))).toBe(true);
    const readme = readFileSync(join(product, "README.md"), "utf8");
    expect(readme).toMatch(/v2\.3|M0/);
  });
});
