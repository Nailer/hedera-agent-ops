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
 *
 * ONLY HTS TOKENS CAN BE ASSOCIATED
 *
 * Bonzo's aTokens are ERC20 contracts deployed through the EVM, not HTS tokens. Including one fails
 * the whole transaction with HTS response code 167, INVALID_TOKEN_ID — and it is unnecessary, since
 * ERC20 balances need no association. The plan therefore only offers the underlyings.
 *
 * WHY THE OUTCOME IS VERIFIED RATHER THAN THE EXIT CODE
 *
 * `cast send` returns zero for a transaction that was accepted and then reverted on chain. An
 * earlier version of this script printed a tick for exactly that: two of three calls reverted with
 * INVALID_TOKEN_ID while the run reported success. Association state is therefore read back from the
 * mirror node at the end, which is the only claim worth making.
 */

import { execFileSync } from "child_process";

const NETWORKS = {
  hedera_testnet: {
    rpcUrl: "https://testnet.hashio.io/api",
    mirrorNode: "https://testnet.mirrornode.hedera.com",
  },
  hedera_mainnet: {
    rpcUrl: "https://mainnet.hashio.io/api",
    mirrorNode: "https://mainnet.mirrornode.hedera.com",
  },
};

/** Roughly measured at ~950k per association on testnet; unused gas is not charged. */
const GAS_PER_ASSOCIATION = 1_200_000;

/** Mirror node ingestion lags consensus by a second or two. */
const VERIFY_ATTEMPTS = 10;
const VERIFY_DELAY_MS = 3_000;

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

  if (!plan.associable?.length) {
    console.error("\n❌ Could not read the association plan. Raw output:\n");
    console.error(output);
    process.exit(1);
  }
  return plan;
}

function send(label, contract, tokens, { rpcUrl, keystore }) {
  console.log(`\n🔗 ${label} → ${tokens.length} token(s)`);

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
    // cast has already printed the cause to the inherited stderr; a Node stack trace would bury it.
    console.error(
      `\n⚠️  Sending for ${label} failed. Continuing so the rest are attempted;`
    );
    console.error("   the verification step below reports the real state.");
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Maps each token's EVM address to its Hedera id, which is what association state is keyed by. */
async function resolveTokenIds(mirrorNode, tokens) {
  const ids = new Map();
  for (const token of tokens) {
    const response = await fetch(`${mirrorNode}/api/v1/tokens/${token}`);
    if (!response.ok) {
      console.error(
        `\n❌ ${token} is not an HTS token — it cannot be associated.`
      );
      console.error(
        "   Bonzo aTokens are ERC20 contracts and must not appear in the plan.\n"
      );
      process.exit(1);
    }
    const body = await response.json();
    ids.set(token.toLowerCase(), body.token_id);
  }
  return ids;
}

async function verify(mirrorNode, targets, tokenIds) {
  const expected = [...tokenIds.values()];
  console.log(
    `\n🔍 Verifying association state on the mirror node (expecting ${expected.join(
      ", "
    )})`
  );

  for (let attempt = 1; attempt <= VERIFY_ATTEMPTS; attempt++) {
    const results = [];

    for (const { label, address } of targets) {
      const response = await fetch(
        `${mirrorNode}/api/v1/accounts/${address}/tokens?limit=50`
      );
      const body = response.ok ? await response.json() : { tokens: [] };
      const held = new Set((body.tokens ?? []).map((t) => t.token_id));
      results.push({ label, missing: expected.filter((id) => !held.has(id)) });
    }

    if (results.every((r) => r.missing.length === 0)) {
      results.forEach((r) =>
        console.log(`   ✔ ${r.label} — all ${expected.length} associated`)
      );
      console.log(
        "\n✅ Done. The agent treasury still needs its own associations — that is your account.\n"
      );
      return;
    }

    if (attempt < VERIFY_ATTEMPTS) {
      await sleep(VERIFY_DELAY_MS);
      continue;
    }

    console.error("\n❌ Association did not complete:");
    for (const { label, missing } of results) {
      console.error(
        missing.length === 0
          ? `   ✔ ${label}`
          : `   ✘ ${label} — missing ${missing.join(", ")}`
      );
    }
    console.error(
      "\n   Association is idempotent, so re-running is safe. Check that the deployer owns"
    );
    console.error(
      "   each contract — associate is onlyOwner — and that the gas limit was sufficient.\n"
    );
    process.exit(1);
  }
}

async function main() {
  const { network, keystore } = parseArgs(process.argv.slice(2));
  const config = NETWORKS[network];

  if (!config) {
    console.error(
      `\n❌ Unknown network '${network}'. Use hedera_testnet or hedera_mainnet.\n`
    );
    process.exit(1);
  }

  const targets = [
    { label: "ActionRouter", address: requireEnv("ACTION_ROUTER") },
    { label: "SaucerSwapAdapter", address: requireEnv("SAUCERSWAP_ADAPTER") },
    { label: "BonzoAdapter", address: requireEnv("BONZO_ADAPTER") },
  ];

  console.log(`\n📋 Reading the association plan on ${network}…`);
  const plan = readPlan(config.rpcUrl);
  console.log(`   associable (HTS): ${plan.associable.join(", ")}`);
  if (plan.erc20_atokens_not_associable) {
    console.log(
      `   skipped (ERC20 aTokens, not HTS): ${plan.erc20_atokens_not_associable.join(
        ", "
      )}`
    );
  }

  const tokenIds = await resolveTokenIds(config.mirrorNode, plan.associable);

  // Every contract handles the same underlyings: the router custodies both legs, the swap adapter
  // receives the input, and the Bonzo adapter receives underlyings on supply and repay. aTokens are
  // ERC20 and need nothing.
  for (const { label, address } of targets) {
    send(label, address, plan.associable, { rpcUrl: config.rpcUrl, keystore });
  }

  await verify(config.mirrorNode, targets, tokenIds);
}

main().catch((error) => {
  console.error(`\n❌ ${error.message}\n`);
  process.exit(1);
});
