const path = require("path");

/**
 * Lints just the staged frontend files.
 *
 * `next:lint` is the ESLint CLI (`eslint .`), not `next lint` — that was swapped out because
 * `next lint` only ever scanned its own default directories and silently skipped services/, hooks/
 * and utils/, and because it is removed in Next.js 16. The ESLint CLI takes paths positionally and
 * rejects `--file`, which is a `next lint` flag, so passing paths the old way fails the pre-commit
 * hook with "Invalid option '--file'".
 *
 * Paths are made relative to packages/nextjs because the command runs in that workspace.
 */
const buildNextEslintCommand = filenames =>
  `yarn next:lint --fix --max-warnings=0 ${filenames
    .map(f => path.relative(path.join("packages", "nextjs"), f))
    .join(" ")}`;

const checkTypesNextCommand = () => "yarn next:check-types";

/**
 * There is no Hardhat package in this template — it is Foundry only. Solidity is formatted by
 * `forge fmt` via `yarn foundry:format`, and `yarn foundry:lint` is `forge fmt --check`, so staged
 * .sol files are covered by CI rather than here.
 */
module.exports = {
  "packages/nextjs/**/*.{ts,tsx}": [buildNextEslintCommand, checkTypesNextCommand],
};
