import path from "node:path";
import { defineConfig } from "vitest/config";

/**
 * Vitest does not read the `paths` mapping from tsconfig.json, so the `~~` alias has to be repeated
 * here. Without it a module importing `~~/…` resolves under Next but not under test, and the suite
 * fails to load rather than failing an assertion — which looks like a broken test rather than a
 * missing alias.
 *
 * Kept in step with `tsconfig.json` (`"~~/*": ["./*"]`).
 */
export default defineConfig({
  resolve: {
    alias: {
      "~~": path.resolve(__dirname, "."),
    },
  },
  test: {
    // Node environment: everything under test here is pure logic and network access. Components are
    // kept thin enough that there is no rendering worth asserting, which avoids pulling in a DOM.
    environment: "node",
    include: ["**/*.test.ts"],
    exclude: ["node_modules/**", ".next/**"],
  },
});
