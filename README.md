# Hedera Agent Ops

An on-chain agent registry where registered agents execute real DeFi actions through SaucerSwap and
Bonzo, under spend limits enforced by contract, with every action recorded as a receipt.

```bash
npm create scaffold-hbar@latest --template Nailer/hedera-agent-ops
```

The general Scaffold-HBAR guide — CLI flags, npm vs Yarn, deploy and verify — lives in the
[Scaffold HBAR docs](https://docs.hedera.com/solutions/tools/scaffold-hbar/index). This README
covers what is specific to **this** template.

## Disclaimer

This is example code for building on Hedera. It has not been audited. The contracts move tokens on
behalf of third parties, which is exactly the category of code that deserves an audit before it
holds anything of value. Use it on testnet, read it, take the patterns — do not put it in front of
real funds as-is.

## What's in this template

- **`AgentRegistry`** — agent identity with three separated roles and per-token, per-epoch spend
  limits enforced on-chain
- **`ActionRouter`** — the execution boundary: authorises, moves funds for exactly one call,
  measures what came back, and emits the receipt
- **`IAgentAction` + adapters** — `SaucerSwapAdapter` (swaps via V2 `exactInput`) and `BonzoAdapter`
  (supply / withdraw / repay against Bonzo's Aave-v2-style pool)
- **`HelperConfig`** — every external protocol address for testnet and mainnet, in one place
- **`HtsAssociatable`** — HTS token association for the router and both adapters
- Deploy and association scripts, with the deploy asserting its own wiring before it finishes
- 127 unit tests and 12 fork tests that run against live Hedera testnet

Foundry only. There is no Hardhat package and no `hardhat:*` script.

## Prerequisites

- Node.js `>=20.18.3`
- Foundry `>=1.4.0` — `foundryup` to update; the scaffold CLI refuses to run below this
- A funded Hedera testnet account with an **ECDSA** key, from
  [portal.hedera.com](https://portal.hedera.com). ED25519 keys cannot sign EVM transactions.
- `git config --global user.name` and `user.email` set — the scaffold CLI checks both

## Quick start

```bash
# install and run the tests — no account or network needed
yarn install
yarn foundry:test

# import the deployer key into an encrypted keystore
yarn foundry:account:import          # name it `hedera-testnet`
yarn foundry:account                 # confirm the balance (deploy costs ~23 HBAR)

# deploy and wire the system
yarn foundry:deploy --file DeployAgentOps.s.sol --network hedera_testnet --keystore hedera-testnet

# associate the deployed contracts with the tokens they will handle.
# Not a forge script -- association calls the HTS system contract, which forge cannot
# execute locally. See Caveats.
ACTION_ROUTER=0x... SAUCERSWAP_ADAPTER=0x... BONZO_ADAPTER=0x... \
  yarn foundry:associate --network hedera_testnet --keystore hedera-testnet

yarn next:dev                        # http://localhost:3000
```

Addresses for the association step are printed by the deploy and written to
`packages/foundry/deployments/296.json`.

## How it works

```text
Agent operator
  │  executeAction(agentId, adapter, request)
  ▼
ActionRouter ──── authorizeSpend ────► AgentRegistry   (is this caller allowed, is it in budget)
  │                                          │
  │  pull amountIn from treasury             └─ reverts before any token moves
  ▼
Adapter (IAgentAction) ─┬─ SaucerSwapAdapter ─► SaucerSwap V2 SwapRouter
                        └─ BonzoAdapter      ─► Bonzo LendingPool
  │
  ▼  measured balance delta, not the adapter's claim
ActionRouter ──► treasury + ActionExecuted receipt
```

Four properties are worth knowing before you change anything:

**Authorisation runs before any token moves.** A budget checked after the swap is not a budget —
the money is already gone.

**Delivery is measured, never reported.** The adapter returns an `amountOut`, and the router ignores
it for accounting in favour of the observed balance delta. An adapter may be buggy or hostile;
measuring means it cannot corrupt the receipt.

**Custody lasts one call.** The treasury approves the router and keeps custody at rest. The router
holds funds only between two statements in a single transaction. It is never a place where money
sits.

**Three roles, deliberately separated.** The `controller` sets policy, the `operator` submits
actions, the `treasury` holds funds. An autonomous agent's hot key will eventually leak; keeping
policy changes off it means a compromised operator can spend up to a limit a human already approved
and cannot raise that limit, redirect the treasury, or restart a stopped agent.

## Environment variables

Copy `packages/nextjs/.env.example` to `.env.local` and fill in:

| Variable | Purpose |
| --- | --- |
| `HEDERA_ACCOUNT_ID` | Operator account that submits HCS audit receipts, e.g. `0.0.12345` |
| `HEDERA_PRIVATE_KEY` | ECDSA key for that account. Never commit a funded mainnet key. |
| `NEXT_PUBLIC_HEDERA_TESTNET_RPC_URL` | Defaults to `https://testnet.hashio.io/api` |
| `NEXT_PUBLIC_MIRROR_NODE_URL` | Defaults to `https://testnet.mirrornode.hedera.com` |
| `NEXT_PUBLIC_HCS_AUDIT_TOPIC_ID` | HCS topic the receipts are written to |
| `NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID` | From [cloud.walletconnect.com](https://cloud.walletconnect.com) |

The deployer key is **not** an environment variable. It lives in an encrypted Foundry keystore —
`yarn foundry:account:import`.

## Deploy and verify

```bash
yarn foundry:deploy --file DeployAgentOps.s.sol --network hedera_testnet --keystore hedera-testnet
yarn foundry:verify:testnet
```

The deploy asserts its own wiring before finishing: the router is bound to the registry, the
registry accepts that router, both adapters are allowlisted, and all four contracts are owned by the
deployer. A half-wired deploy is worse than a failed one — the contracts exist, the frontend finds
them, and the first action reverts somewhere unhelpful.

Verification goes through Sourcify, which supports Hedera on the main instance.

## Useful commands

```bash
yarn foundry:associate            # associate deployed contracts with HTS tokens
yarn foundry:test                 # hermetic unit tests; fork tests self-skip
yarn foundry:test:testnet         # fork against Hedera testnet (296)
yarn foundry:test:mainnet         # fork against Hedera mainnet (295)
yarn foundry:compile
yarn foundry:format               # run before committing; foundry:lint is `forge fmt --check`
yarn foundry:lint
yarn next:dev
yarn next:lint --max-warnings=0
yarn next:check-types
yarn next:build
```

## Caveats

Things that will cost you time on Hedera specifically. Each was found the hard way in this repo.

**HTS tokens are not ERC20 contracts.** Every SaucerSwap pair token and every Bonzo reserve is an
HTS token. Calling `symbol()` or `balanceOf()` routes through the HTS system contract at `0x167`,
which does not exist in a plain `forge test --fork-url` run. The call lands on empty code and dies
with `InvalidFEOpcode`, which looks like a compiler bug and is not. Use `htsSetup()` from
`hedera-forking` — and note the import is `hedera-forking/htsSetup.sol`, not the path in that
library's own README, because `remappings.txt` already points at `contracts/`.

**`forge script` cannot call `0x167` at all.** forge always executes a script's body locally to
discover which transactions to broadcast, so a script calling `associateToken` dies with
`InvalidFEOpcode` before anything is sent. `--skip-simulation` does not help — it skips the on-chain
simulation, not the local execution; the failure is identical with no broadcast flag at all. Use
`cast send`, which signs and submits without executing locally: `yarn foundry:associate` does this,
resolving addresses through a read-only forge script so `HelperConfig` stays the only address book.
Applies to any script touching HTS; `DeployAgentOps` is unaffected because it never reaches the
system contract.

**`cast call` succeeding tells you nothing about a fork.** The live network has `0x167`; a fork does
not. A read that works from the command line can consume the whole gas limit under `forge test`. A
gas figure around `1024178429` is the tell.

**`vm.skip()` writes state,** so a test using a skip modifier cannot be `view`.

**Association is required before holding a token.** Contracts included. A transfer to an
unassociated account fails at the moment of delivery, after the work is done. Run
`AssociateTokens.s.sol` after deploying, and associate the agent treasury yourself — that is your
account, not the template's.

**Mirror node topic queries need a bounded window, and it may not exceed 7 days.** Filtering
contract logs by `topic0` without a timestamp range returns HTTP 400 — *"Cannot search topics
without a valid timestamp range"*. Both a lower and an upper bound are required, and a range wider
than 7 days is refused. Neither is in the mirror node docs; the query looks well-formed and simply
comes back 400. Reading a long-lived agent's full history therefore means walking backwards a week
at a time — `previousWindow` in `services/audit/mirrorNode.ts` does that, with non-overlapping
windows so boundary receipts are not counted twice.

**Two address shapes, both valid.** SaucerSwap was created through HAPI and resolves to the
long-zero form (`0.0.1414040` → `0x…159398`); Bonzo was EVM-deployed and has ordinary keccak
addresses. Never hand-derive a long-zero address — resolve it from the mirror node
(`/api/v1/contracts/{id}` → `evm_address`), because an account later given an EVM alias will not
match.

**WHBAR is two entities.** The wrapper contract (`0.0.15057`) and the HTS token (`0.0.15058`) sit on
adjacent entity numbers and are trivially transposed. Swap paths take the token; wrapping goes
through the contract.

**Fork tests hit rate limits.** The HTS emulator issues an ffi fetch per piece of token state. Keep
the number of live quote calls small — enough of them in one run start failing with a bare
"Unexpected error". This is why fork tests stay out of CI.

**Borrow is not supported.** The router pulls an input from the treasury before calling an adapter,
and borrowing has no input. Supporting it needs a second router entry point with debt-based rather
than spend-based authorisation. `supportsAction` returns false, so the router refuses it up front.

## Project layout

```text
packages/foundry/
  contracts/
    AgentRegistry.sol            identity, roles, spend policy
    ActionRouter.sol             execution boundary and receipts
    HtsAssociatable.sol          shared HTS association
    adapters/                    SaucerSwapAdapter, BonzoAdapter
    interfaces/                  IAgentAction and the protocol interfaces
  script/
    HelperConfig.s.sol           every external address, per chain
    DeployAgentOps.s.sol         deploy and wire
    AssociateTokens.s.sol        associate deployed contracts with HTS tokens
  test/
    *.t.sol                      hermetic unit tests
    integration/                 fork tests against live testnet
packages/nextjs/                 App Router frontend
AGENTS.md                        briefing for coding agents; invariants live here
template.json                    scaffold manifest
```

## Links

- [Scaffold HBAR docs](https://docs.hedera.com/solutions/tools/scaffold-hbar/index)
- [SaucerSwap developer docs](https://docs.saucerswap.finance/developers/overview)
- [Bonzo Finance developer docs](https://docs.bonzo.finance/hub/developer/bonzo-lend/lend-contracts)
- [hedera-forking](https://github.com/hashgraph/hedera-forking) — HTS emulation for fork testing
- [Hedera portal](https://portal.hedera.com) — testnet accounts and faucet
- [HashScan](https://hashscan.io/testnet) — explorer

## Licence

MIT. See [LICENCE](./LICENCE). Derived from Scaffold-ETH / Scaffold-HBAR; the upstream copyright
notices are retained alongside ours.
