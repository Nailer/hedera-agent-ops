#!/usr/bin/env node
/**
 * Associates the deployed contracts with the HTS tokens they handle.
 *
 * ```bash
 * ACTION_ROUTER=0x… SAUCERSWAP_ADAPTER=0x… BONZO_ADAPTER=0x… \
 *   yarn foundry:associate --network hedera_testnet --keystore hedera-testnet
 * ```
 *
 * WHY THIS IS NOT A FORGE SCRIPT
 *
 * Association calls the HTS system contract at 0x167. `forge script` always executes a script's
 * body locally to discover which transactions to broadcast, and the local EVM has no 0x167 — so the
 * call dies with InvalidFEOpcode before anything is sent. `--skip-simulation` does not help: it
 * skips the *on-chain* simulation, not the local execution. Confirmed by running the forge script
 * with no broadcast flag at all and getting the identical failure.
 *
 * `cast send` builds, signs and submits a transaction without executing it locally, so the call
 * reaches the real network where 0x167 exists.
 *
 * Address resolution still happens in Solidity, via PrintAssociationPlan.s.sol — reads work fine
 * under forge, and it keeps HelperConfig as the single place a protocol address is written rather
 * than duplicating the address book here.
 */

import { execFileSync } from "child_process";

const RPC_URLS = {
  hedera_testnet: "https://testnet.hashio.io/api",
  hedera_mainnet: "https://mainnet.hashio.io/api",
};

/**
 * Hedera charges per HTS association and estimation through the relay is not dependable for them,
 * so an explicit ceiling is passed. Roughly 900k per token with headroom; unused gas is not charged.
 */
const GAS_PER_ASSOCIATION = 900_000;

function parseArgs(argv) {
  let network = "hedera_testnet";
  let keystore = null;

  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--network" && argv[i + 1]) network = argv[++i];
    else if (argv[i] === "--keystore" && argv[i + 1]) keystore = argv[++i];
  }
  return { network, keystore };
}

function requireEnv(name) {
  const value = process.env[name];
  if (!value || !/^0x[0-9a-fA-F]{40}$/.test(value)) {
    console.error(
      `\n❌ ${name} is missing or not an address. Deploy first; the addresses are printed by`
    );
    console.error(
      "   DeployAgentOps and written to packages/foundry/deployments/<chainId>.json\n"
    );
    process.exit(1);
  }
  return value;
}

/** Runs the read-only forge script and pulls the `PLAN <label> <csv>` lines out of its output. */
function readPlan(rpcUrl) {
  const output = execFileSync(
    "forge",
    [
      "script",
      "script/PrintAssociationPlan.s.sol:PrintAssociationPlan",
      "--rpc-url",
      rpcUrl,
    ],
    { encoding: "utf8" }
  );

  const plan = {};
  for (const line of output.split("\n")) {
    const match = line.trim().match(/^PLAN\s+(\w+)\s+(.+)$/);
    if (match) plan[match[1]] = match[2].split(",").filter(Boolean);
  }

  if (!plan.underlyings || !plan.all) {
    console.error("\n❌ Could not read the association plan. Raw output:\n");
    console.error(output);
    process.exit(1);
  }
  return plan;
}

function associate(label, contract, tokens, { rpcUrl, keystore }) {
  console.log(`\n🔗 ${label} → ${tokens.length} token(s)`);
  tokens.forEach((t) => console.log(`     ${t}`));

  const args = [
    "send",
    contract,
    "associateMany(address[])",
    `[${tokens.join(",")}]`,
    "--rpc-url",
    rpcUrl,
    "--gas-limit",
    String(GAS_PER_ASSOCIATION * tokens.length),
    "--legacy",
  ];
  if (keystore) args.push("--account", keystore);

  try {
    // stdio inherited so cast can prompt for the keystore password on a real TTY.
    execFileSync("cast", args, { stdio: "inherit" });
  } catch {
    // execFileSync throws with a full Node stack trace that buries the actual cause. cast has
    // already printed whatever went wrong to the inherited stderr, so say what failed and stop.
    console.error(
      `\n❌ Associating ${label} failed. cast printed the reason above.`
    );
    console.error("   Common causes:");
    console.error("     • wrong keystore password, or no TTY to prompt on");
    console.error(
      "     • the deployer is not the owner of that contract — associate is onlyOwner"
    );
    console.error("     • gas limit too low for this many associations");
    console.error(
      "\n   Association is idempotent, so re-running after a fix is safe.\n"
    );
    process.exit(1);
  }
  console.log(`   ✔ ${label} associated`);
}

function main() {
  const { network, keystore } = parseArgs(process.argv.slice(2));
  const rpcUrl = RPC_URLS[network];

  if (!rpcUrl) {
    console.error(
      `\n❌ Unknown network '${network}'. Use hedera_testnet or hedera_mainnet.\n`
    );
    process.exit(1);
  }

  const router = requireEnv("ACTION_ROUTER");
  const saucerSwapAdapter = requireEnv("SAUCERSWAP_ADAPTER");
  const bonzoAdapter = requireEnv("BONZO_ADAPTER");

  console.log(
    `\n📋 Reading the association plan from HelperConfig and Bonzo on ${network}…`
  );
  const plan = readPlan(rpcUrl);

  const options = { rpcUrl, keystore };

  // The router custodies both legs of every action, so it needs everything.
  associate("ActionRouter", router, plan.all, options);
  // The swap adapter only ever receives the input; output goes straight to the router.
  associate("SaucerSwapAdapter", saucerSwapAdapter, plan.underlyings, options);
  // Bonzo hands the adapter underlyings on supply and aTokens to burn on withdraw.
  associate("BonzoAdapter", bonzoAdapter, plan.all, options);

  console.log(
    "\n✅ Done. The agent treasury still needs its own associations — that is your account.\n"
  );
}

main();
