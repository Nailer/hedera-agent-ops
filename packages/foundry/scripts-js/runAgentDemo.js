#!/usr/bin/env node
/**
 * Drives one agent action end to end on testnet, then reads the receipt back.
 *
 * ```bash
 * AGENT_REGISTRY=0x… ACTION_ROUTER=0x… SAUCERSWAP_ADAPTER=0x… \
 *   yarn foundry:demo --network hedera_testnet --keystore hedera-testnet
 * ```
 *
 * The treasury, operator and controller are all the deployer account, which keeps the demo to one
 * key. In anything real they are three different keys — that separation is the point of the
 * registry, and `AgentRegistry` enforces it regardless of who holds what here.
 *
 * WHY cast AND NOT forge script
 *
 * Every step below touches HTS: association, wrapping HBAR into WHBAR, approving an HTS token,
 * swapping one. `forge script` executes its body locally to discover transactions, and the local EVM
 * has no `0x167`, so it dies before sending. Address resolution stays in Solidity via
 * PrintDemoPlan.s.sol, which is read-only and therefore fine.
 *
 * EVERY STEP IS SKIPPED IF ALREADY DONE
 *
 * Each stage checks chain state first. A re-run after a failure costs only the prompts for what is
 * genuinely outstanding, and the whole thing is safe to run twice.
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

/**
 * HBAR has 8 decimals, but `msg.value` on Hedera's EVM is denominated in weibars — 10^18 to the
 * HBAR, not 10^8. Sending `5e8` to `deposit()` would wrap 0.00000005 HBAR rather than 5, so the
 * amount is scaled by this on the way in.
 */
const WEIBAR_PER_TINYBAR = 10n ** 10n;

/** 8 decimals, matching WHBAR. */
const WRAP_AMOUNT = 300_000_000n; // 3 WHBAR
const SWAP_AMOUNT = 100_000_000n; // 1 WHBAR
const MAX_PER_ACTION = 500_000_000n; // 5 WHBAR
const MAX_PER_EPOCH = 2_000_000_000n; // 20 WHBAR
const EPOCH_SECONDS = 86_400;

const GAS = {
  associate: 1_200_000,
  wrap: 1_500_000,
  approve: 1_000_000,
  registry: 1_000_000,
  swap: 6_000_000,
};

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
      `\n❌ ${name} is missing or not an address. See packages/foundry/deployments/<chainId>.json\n`
    );
    process.exit(1);
  }
  return value;
}

const run = (bin, args, opts = {}) =>
  execFileSync(bin, args, { encoding: "utf8", ...opts }).trim();

function readPlan(rpcUrl) {
  const output = run("forge", [
    "script",
    "script/PrintDemoPlan.s.sol:PrintDemoPlan",
    "--rpc-url",
    rpcUrl,
  ]);
  const plan = {};
  for (const line of output.split("\n")) {
    const match = line.trim().match(/^DEMO\s+(\w+)\s+(\S+)$/);
    if (match) plan[match[1]] = match[2];
  }
  if (!plan.whbarToken || !plan.feeTier) {
    console.error("\n❌ Could not read the demo plan:\n" + output);
    process.exit(1);
  }
  return plan;
}

function castCall(rpcUrl, target, sig, ...args) {
  return run("cast", ["call", target, sig, ...args, "--rpc-url", rpcUrl]);
}

function castSend(
  label,
  rpcUrl,
  keystore,
  target,
  sig,
  args,
  { gas, value } = {}
) {
  console.log(`\n▶ ${label}`);
  const cmd = ["send", target, sig, ...args, "--rpc-url", rpcUrl, "--legacy"];
  if (gas) cmd.push("--gas-limit", String(gas));
  if (value) cmd.push("--value", String(value));
  if (keystore) cmd.push("--account", keystore);

  try {
    execFileSync("cast", cmd, { stdio: "inherit" });
  } catch {
    console.error(`\n❌ ${label} failed. cast printed the reason above.`);
    console.error(
      "   Every step here is idempotent, so re-running after a fix is safe.\n"
    );
    process.exit(1);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function isAssociated(mirrorNode, account, tokenEvm) {
  const meta = await fetch(`${mirrorNode}/api/v1/tokens/${tokenEvm}`);
  if (!meta.ok) return { associated: false, tokenId: null };
  const { token_id: tokenId } = await meta.json();

  const held = await fetch(
    `${mirrorNode}/api/v1/accounts/${account}/tokens?limit=100`
  );
  if (!held.ok) return { associated: false, tokenId };
  const body = await held.json();
  return {
    associated: (body.tokens ?? []).some((t) => t.token_id === tokenId),
    tokenId,
  };
}

/** `[token(20) | fee(3) | token(20)]`, SaucerSwap's V2 path encoding. */
function encodePath(tokenIn, fee, tokenOut) {
  const feeHex = Number(fee).toString(16).padStart(6, "0");
  return `0x${tokenIn.slice(2)}${feeHex}${tokenOut.slice(2)}`.toLowerCase();
}

async function main() {
  const { network, keystore } = parseArgs(process.argv.slice(2));
  const config = NETWORKS[network];
  if (!config) {
    console.error(`\n❌ Unknown network '${network}'.\n`);
    process.exit(1);
  }
  const { rpcUrl, mirrorNode } = config;

  const registry = requireEnv("AGENT_REGISTRY");
  const router = requireEnv("ACTION_ROUTER");
  const adapter = requireEnv("SAUCERSWAP_ADAPTER");

  console.log(`\n📋 Reading the demo plan on ${network}…`);
  const plan = readPlan(rpcUrl);
  console.log(
    `   WHBAR ${plan.whbarToken}  →  SAUCE ${plan.sauceToken}  via pool ${plan.pool} (fee ${plan.feeTier})`
  );

  // `cast wallet address` prompts for the keystore password. TREASURY short-circuits that, which
  // keeps the read-only stages runnable without unlocking a key.
  const treasury =
    process.env.TREASURY ??
    run("cast", ["wallet", "address", "--account", keystore])
      .split(/\s+/)
      .pop();
  console.log(`   treasury / operator / controller: ${treasury}`);

  // 1. Associate the treasury with both tokens. An ordinary account associates through HRC-719 by
  //    calling associate() on the token address itself, which the HTS proxy forwards to 0x167.
  for (const [name, token] of [
    ["WHBAR", plan.whbarToken],
    ["SAUCE", plan.sauceToken],
  ]) {
    const { associated } = await isAssociated(mirrorNode, treasury, token);
    if (associated) {
      console.log(`\n✓ treasury already associated with ${name}`);
    } else {
      castSend(
        `associate treasury with ${name}`,
        rpcUrl,
        keystore,
        token,
        "associate()",
        [],
        {
          gas: GAS.associate,
        }
      );
    }
  }

  // 2. Wrap HBAR into WHBAR if the treasury is short.
  const whbarBalance = BigInt(
    castCall(
      rpcUrl,
      plan.whbarToken,
      "balanceOf(address)(uint256)",
      treasury
    ).split(/\s+/)[0]
  );
  console.log(`\n   treasury WHBAR balance: ${whbarBalance}`);
  if (whbarBalance < SWAP_AMOUNT) {
    castSend(
      "wrap HBAR into WHBAR",
      rpcUrl,
      keystore,
      plan.whbarContract,
      "deposit()",
      [],
      {
        gas: GAS.wrap,
        value: (WRAP_AMOUNT * WEIBAR_PER_TINYBAR).toString(),
      }
    );
  } else {
    console.log("✓ treasury already holds enough WHBAR");
  }

  // 3. Approve the router to pull WHBAR. Custody stays with the treasury; the router only ever
  //    moves funds inside a single call.
  const allowance = BigInt(
    castCall(
      rpcUrl,
      plan.whbarToken,
      "allowance(address,address)(uint256)",
      treasury,
      router
    ).split(/\s+/)[0]
  );
  if (allowance < SWAP_AMOUNT) {
    castSend(
      "approve the router for WHBAR",
      rpcUrl,
      keystore,
      plan.whbarToken,
      "approve(address,uint256)",
      [router, String(MAX_PER_EPOCH)],
      { gas: GAS.approve }
    );
  } else {
    console.log("\n✓ router already approved for WHBAR");
  }

  // 4. Register an agent, unless one is already registered to this controller.
  let agentId = BigInt(
    castCall(rpcUrl, registry, "agentCount()(uint256)").split(/\s+/)[0]
  );
  if (agentId === 0n) {
    castSend(
      "register the agent",
      rpcUrl,
      keystore,
      registry,
      "registerAgent(address,address,string)",
      [treasury, treasury, "ipfs://hedera-agent-ops-demo"],
      { gas: GAS.registry }
    );
    agentId = BigInt(
      castCall(rpcUrl, registry, "agentCount()(uint256)").split(/\s+/)[0]
    );
  } else {
    console.log(`\n✓ agent ${agentId} already registered`);
  }
  console.log(`   agent id: ${agentId}`);

  // 5. Set the spend policy. Registration grants nothing until this exists — default deny.
  const policy = castCall(
    rpcUrl,
    registry,
    "policyOf(uint256,address)((uint256,uint256,uint64))",
    String(agentId),
    plan.whbarToken
  );
  if (/^\(0,/.test(policy.replace(/\s/g, ""))) {
    castSend(
      "set the WHBAR spend policy",
      rpcUrl,
      keystore,
      registry,
      "setSpendPolicy(uint256,address,uint256,uint256,uint64)",
      [
        String(agentId),
        plan.whbarToken,
        String(MAX_PER_ACTION),
        String(MAX_PER_EPOCH),
        String(EPOCH_SECONDS),
      ],
      { gas: GAS.registry }
    );
  } else {
    console.log(`\n✓ spend policy already set: ${policy}`);
  }

  // 6. The action itself.
  const path = encodePath(plan.whbarToken, plan.feeTier, plan.sauceToken);
  const deadline = Math.floor(Date.now() / 1000) + 900;
  const protocolData = run("cast", [
    "abi-encode",
    "f(bytes,uint256)",
    path,
    String(deadline),
  ]);

  console.log(`\n   swap path: ${path}`);
  castSend(
    `execute the swap — 1 WHBAR → SAUCE, agent ${agentId}`,
    rpcUrl,
    keystore,
    router,
    "executeAction(uint256,address,(uint8,address,uint256,address,uint256,bytes))",
    [
      String(agentId),
      adapter,
      `(0,${plan.whbarToken},${SWAP_AMOUNT},${plan.sauceToken},0,${protocolData})`,
    ],
    { gas: GAS.swap }
  );

  // 7. Read the receipt back the way the audit feed does.
  console.log("\n🔍 Reading the receipt back from the mirror node…");
  const topic0 =
    "0x0e3aff325d7c5fd044174daccd6f080b89ea3e7d6247ce7e0b55ac69f1c9029d";
  const to = Math.floor(Date.now() / 1000);
  const from = to - 604_799;

  for (let attempt = 1; attempt <= 12; attempt++) {
    const url =
      `${mirrorNode}/api/v1/contracts/${router}/results/logs` +
      `?topic0=${topic0}&order=desc&limit=5&timestamp=gte:${from}&timestamp=lte:${to}`;
    const response = await fetch(url);
    const body = response.ok ? await response.json() : { logs: [] };

    if ((body.logs ?? []).length > 0) {
      const log = body.logs[0];
      console.log(
        `\n✅ Receipt found — the agent acted and it is on the record.`
      );
      console.log(`   consensus timestamp : ${log.timestamp}`);
      console.log(`   transaction         : ${log.transaction_hash}`);
      console.log(`   agent id            : ${BigInt(log.topics[1])}`);
      console.log(
        `\n   HashScan: https://hashscan.io/testnet/transaction/${log.transaction_hash}`
      );
      console.log(`   Audit feed: http://localhost:3000/agents/${agentId}\n`);
      return;
    }
    await sleep(5_000);
  }

  console.error(
    "\n⚠️  The swap was sent but no receipt is visible yet. The mirror node is eventually"
  );
  console.error(
    "   consistent — check the audit feed in a moment, or HashScan for the transaction.\n"
  );
  process.exit(1);
}

main().catch((error) => {
  console.error(`\n❌ ${error.message}\n`);
  process.exit(1);
});
