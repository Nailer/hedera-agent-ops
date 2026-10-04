# Hedera Agent Ops

An on-chain agent registry where registered agents execute real DeFi actions through SaucerSwap and
Bonzo, under spend limits enforced by contract, with every action recorded as a receipt.

```bash
npm create scaffold-hbar@latest -- --template Nailer/hedera-agent-ops
```

The `--` is required. Without it npm consumes `--template` itself and you get the default scaffold
instead of this template, with no error to tell you so. Yarn needs no separator:
`yarn create scaffold-hbar --template Nailer/hedera-agent-ops`.

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
- **A frontend that writes, not just reads** — register an agent, set its spend policy, approve the
  router and execute a real swap from the browser, then watch the receipt arrive in the audit feed
- Deploy and association scripts, with the deploy asserting its own wiring before it finishes
- 140 tests: 127 hermetic unit tests, plus 13 fork tests that self-skip unless you point them
  at live Hedera testnet

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
yarn foundry:account                 # confirm the balance (the deploy below cost 8.35 HBAR)

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

## Live on Hedera testnet

This template is deployed, wired and source-verified on testnet (chain 296). The contracts below are
the ones the tests and the frontend talk to, and the wiring was verified by reading it back off chain
rather than trusting the deploy output.

| Contract | Address |
| --- | --- |
| `AgentRegistry` | [`0x2bcD5637Fc34eCC488EBA4bA209DACad05Cf0D76`](https://hashscan.io/testnet/contract/0x2bcD5637Fc34eCC488EBA4bA209DACad05Cf0D76) |
| `ActionRouter` | [`0x50F1aE91073ADD5dc4f833C95ce8230872cE4F88`](https://hashscan.io/testnet/contract/0x50F1aE91073ADD5dc4f833C95ce8230872cE4F88) |
| `SaucerSwapAdapter` | [`0x34DC78d33a76e5Ac6c5546c6241f903c66FCa506`](https://hashscan.io/testnet/contract/0x34DC78d33a76e5Ac6c5546c6241f903c66FCa506) |
| `BonzoAdapter` | [`0x5b89b6BA0bb905f97Bb0Da0F827E20D930f5abC0`](https://hashscan.io/testnet/contract/0x5b89b6BA0bb905f97Bb0Da0F827E20D930f5abC0) |

Deployed in 7 transactions for 8.35 HBAR. All four are verified on Sourcify, so HashScan shows their
source. The router and both adapters are associated with the HTS tokens they handle — WHBAR
`0.0.15058`, SAUCE `0.0.1183558`, USDC `0.0.5449` — which is required before a Hedera contract can
hold a token at all.

To check the wiring yourself:

```bash
cast call 0x50F1aE91073ADD5dc4f833C95ce8230872cE4F88 "registry()(address)" \
  --rpc-url https://testnet.hashio.io/api
```

## Using the app

`yarn next:dev`, connect a wallet on Hedera testnet, and go to `/agents`.

**1 — Register an agent.** You become its `controller`. The form asks separately for the `operator`
(the key that submits actions) and the `treasury` (where the funds live), defaulting both to your
wallet so a first agent is one click. It warns when all three are the same account, because in
production they should not be.

**2 — Set a spend policy.** A freshly registered agent can spend nothing. The controller authorises
one token at a time, with a per-action cap and a per-epoch cap; the console uses a 24-hour epoch,
though `setSpendPolicy` takes any epoch length. This is a separate step on purpose: authority is
granted explicitly, per asset, and the registry enforces it.

**3 — Approve the router.** The treasury keeps custody and grants an allowance. The router holds
funds only between two statements inside one transaction — never at rest.

**4 — Execute.** The operator submits a swap. The router authorises against the policy, pulls the
input, calls the adapter, measures what actually came back, enforces the slippage floor, and emits
the receipt.

**5 — Read it back.** `/agents/[agentId]` replays that agent's receipts from the mirror node. Mirror
node reads are eventually consistent, so a receipt takes a few seconds to appear.

The console greys out what the connected wallet may not do, but that is a courtesy — every one of
these checks is enforced in the contract. Calling `setSpendPolicy` as the operator reverts with
`AgentRegistry__NotController` whether or not a button was disabled.

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

Every variable is optional — the frontend runs against testnet with no `.env.local` at all. Copy
`packages/nextjs/.env.example` to `.env.local` to override a default.

| Variable | Purpose |
| --- | --- |
| `NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID` | From [cloud.walletconnect.com](https://cloud.walletconnect.com). The bundled fallback is shared and rate-limited. |
| `NEXT_PUBLIC_HEDERA_TESTNET_RPC_URL` | Defaults to `https://testnet.hashio.io/api` |
| `NEXT_PUBLIC_HEDERA_MAINNET_RPC_URL` | Defaults to `https://mainnet.hashio.io/api` |
| `NEXT_PUBLIC_MIRROR_NODE_URL` | Defaults to `https://testnet.mirrornode.hedera.com`. Point it at mainnet, or at your own mirror node — the trail is only independently verifiable if you can choose the endpoint. |

There is no private key here. The deployer key lives in an encrypted Foundry keystore
(`yarn foundry:account:import`), and the frontend signs through the user's wallet. Nothing in this
template needs a key in a file.

## Deploy and verify

```bash
yarn foundry:deploy --file DeployAgentOps.s.sol --network hedera_testnet --keystore hedera-testnet
```

The deploy asserts its own wiring before finishing: the router is bound to the registry, the
registry accepts that router, both adapters are allowlisted, and all four contracts are owned by the
deployer. A half-wired deploy is worse than a failed one — the contracts exist, the frontend finds
them, and the first action reverts somewhere unhelpful.

Verification goes through Sourcify, which supports Hedera on its main instance. `forge
verify-contract` takes one contract at a time, so pass the address and the qualified name:

```bash
yarn foundry:verify:testnet 0xYourAgentRegistry contracts/AgentRegistry.sol:AgentRegistry
yarn foundry:verify:testnet 0xYourActionRouter  contracts/ActionRouter.sol:ActionRouter
```

HashScan reads Sourcify, so a verified contract shows its source there a few minutes later. The four
deployed contracts above are verified — each returned `exact_match` on its runtime bytecode.

## Useful commands

```bash
yarn foundry:associate            # associate deployed contracts with HTS tokens
yarn foundry:test                 # hermetic unit tests; fork tests self-skip
yarn foundry:test:testnet         # fork against Hedera testnet (296)
yarn foundry:test:mainnet         # fork against Hedera mainnet (295)
yarn foundry:compile
yarn foundry:format               # run before committing
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
`yarn foundry:associate` after deploying, and associate the agent treasury yourself — that is your
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
    PrintAssociationPlan.s.sol   read-only: which tokens each contract needs
  scripts-js/
    associateTokens.js           sends the associations via `cast send`
  test/
    *.t.sol                      hermetic unit tests
    integration/                 fork tests against live testnet
packages/nextjs/
  app/agents/                    registry browser and per-agent detail page
  components/agent/              RegisterAgentForm, ActionConsole, AuditFeed
  hooks/useAgentAuditTrail.ts    walks the mirror node a week at a time
  services/audit/                receipt reading, decoding, formatting
  services/tokens/               HTS token metadata from the mirror node
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
- [Sourcify](https://sourcify.dev) — contract verification; HashScan reads from it
- [Hedera mirror node REST API](https://docs.hedera.com/hedera/sdks-and-apis/rest-api) — how the
  audit trail is read back

## Licence

MIT. See [LICENCE](./LICENCE). Derived from Scaffold-ETH / Scaffold-HBAR; the upstream copyright
notices are retained alongside ours.
