import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

// Vitest runs with cwd at the package root; import.meta.url is not a file:
// URL under the jsdom environment, so resolve from cwd instead.
export const fixturesDir = join(process.cwd(), "fixtures");

export function fixtureNames(prefix: "valid" | "invalid"): string[] {
  return readdirSync(fixturesDir)
    .filter((f) => f.startsWith(`${prefix}-`) && f.endsWith(".json"))
    .sort();
}

export function loadFixture(name: string): unknown {
  return JSON.parse(readFileSync(join(fixturesDir, name), "utf-8"));
}
