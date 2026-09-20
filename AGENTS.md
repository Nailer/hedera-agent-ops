# Hedera Agent Ops — Agent Guide

Briefing for coding agents working in the **hedera-agent-ops** Scaffold-HBAR template.
Claude Code loads it through `CLAUDE.md`.

## Overview

An on-chain agent registry where registered agents execute real DeFi actions through Hedera
protocols, and every action is written to an HCS topic and replayed from the mirror node as a
tamper-evident audit trail.

The registry answers *"does this agent exist?"*. The audit trail answers *"what has it actually
done?"* — which is the question that matters once a registry has more entries than anyone can
check by hand.

Integrations are **load-bearing**: an agent cannot act without SaucerSwap or Bonzo. They are not
decoration on top of a self-contained demo.

## Solidity Framework

**Foundry-only** monorepo. There is no `packages/hardhat`, and no `hardhat:*` script exists.
Do not write Hardhat deploy scripts or suggest `yarn hardhat:…` commands — they will fail.

- **`packages/foundry`** — contracts, Forge scripts, tests, ABI generation
- **`packages/nextjs`** — registry browser, action console, audit feed

Init submodules after clone: `git submodule update --init --recursive`.

## Architecture

```text
Agent (registered)
  → ActionRouter
      → IAgentAction adapter ─┬─ SaucerSwapAdapter → SaucerSwap V2 SwapRouter
                              └─ BonzoAdapter      → Bonzo LendingPool
  → receipt → HCS topic → mirror node → audit feed in the UI
```

### Critical invariants

These are the rules the contracts must obey. Breaking one is a bug even if tests pass.

- **Consumers depend only on `IAgentAction`, never on a protocol SDK directly.** Adding a protocol
  means adding an adapter, not editing the router.
- **`HelperConfig` is the only place a protocol address is written.** No address literals in
  contracts, scripts, tests, or frontend code. One book, one edit site.
- **Every address in `HelperConfig` is resolved from the mirror node, never hand-derived.** See
  *Addresses* below — hand-deriving a long-zero address is a real and silent failure mode here.
- **An agent's spend policy is enforced on-chain, not in the UI.** The frontend is a convenience;
  the router is the boundary. A policy that only exists in React is not a policy.
- **Every state-changing agent action emits a receipt event, unconditionally.** The audit trail is
  only tamper-evident if it cannot be selectively skipped. No early return may bypass the emit.
- **The HCS topic is append-only and never the source of truth for balances.** It records what was
  attempted and what the chain returned. Read balances from chain state, not from the log.
- **Mirror node reads are eventually consistent.** Never assert a just-submitted transaction is
  visible on the mirror node without polling. A read-after-write that passes locally will flake.

## Hedera-specific facts that will cost you hours

These were each discovered the hard way in this repo. They are not in the scaffold docs.

### HTS tokens are not ERC20 contracts

Every token on Bonzo's reserve list and every SaucerSwap pair token is an **HTS token**. Calling
`symbol()`, `balanceOf()`, or `transfer()` on one routes through the HTS system contract at
`0x167`.

In a plain `forge test --fork-url` run, `0x167` does not exist. The call lands on empty code and
dies with `InvalidFEOpcode` — an error that looks like a compiler bug and is not.

The fix is `htsSetup()` from `hedera-forking`, which etches a Solidity HTS emulator at `0x167` that
services those calls by querying the mirror node over `ffi`:

```solidity
import { htsSetup } from "hedera-forking/htsSetup.sol";

function setUp() public {
    if (block.chainid == 296 || block.chainid == 295) {
        htsSetup();
    }
}
```

Note the import path is `hedera-forking/htsSetup.sol`, **not** the
`hedera-forking/contracts/htsSetup.sol` shown in that library's README — this repo's
`remappings.txt` already points `hedera-forking/` at the `contracts/` directory.

`ffi = true` is already set in `foundry.toml` and is required for this. Expect fork tests that
touch HTS tokens to take minutes, not seconds: each token's state is fetched over HTTP.

Two corollaries that have each cost time in this repo:

- **`vm.skip()` writes state, so a test using a skip modifier cannot be `view`.** The compiler
  rejects it with "Function cannot be declared as view because this expression (potentially)
  modifies the state", and points at the modifier rather than at `vm.skip`.
- **`cast call` succeeding is not evidence a fork test will pass.** The live network has `0x167`;
  a fork does not. A read that works perfectly from the command line can consume all gas and fail
  with a bare "Unexpected error" under `forge test --fork-url`. The giveaway is a gas figure around
  `1024178429` — that is the entire gas limit, not a real cost. Reach for `htsSetup()` before
  debugging anything else.

This bites well beyond direct token calls. Quoting a SaucerSwap swap reads the pool's HTS balances,
so even a read-only price query needs the emulator under fork.

### Two address shapes, both valid

- **HAPI-created contracts** (SaucerSwap) have no EVM-native address. The mirror node reports the
  **long-zero** form: `0x` + 38 zeros + the entity number in hex.
  `0.0.1414040` → `0x0000000000000000000000000000000000159398`.
- **EVM-deployed contracts** (Bonzo) carry ordinary keccak-derived addresses like
  `0xf67DBe9bD1B331cA379c44b5562EAa1CE831EbC2`.

Never hand-derive a long-zero address from an entity number. An account that has since been given
an EVM alias will not match, and the derived address will be a well-formed pointer to nothing.
Resolve it: `GET /api/v1/contracts/{id}` → `evm_address`.

Solidity enforces EIP-55 checksums on address literals. If you change the case of a hex digit while
editing, the compiler will reject it and tell you the correct form. Trust the compiler's suggestion.

### WHBAR is two different things

`whbarContract` (the wrapper, `0.0.15057`) and `whbarToken` (the HTS token, `0.0.15058`) are
adjacent entity numbers and trivially transposed. Swap paths take the **token**. Wrapping and
unwrapping go through the **contract**. Transposing them produces reverts with no useful message.

WHBAR is also the seam between the two protocols: SaucerSwap's WHBAR token is the same token Bonzo
lists as its WHBAR reserve, which is what lets one agent swap on SaucerSwap and supply the proceeds
to Bonzo without a bridge.

### Token association

A Hedera account must be associated with an HTS token before it can hold it. This applies to
contracts too. An agent that swaps into a token it has never held will fail on delivery unless the
receiving account is associated first.

## Commands

```bash
yarn foundry:compile              # forge compile
yarn foundry:test                 # hermetic unit tests; fork tests self-skip
yarn foundry:test:testnet         # fork against Hedera testnet (296)
yarn foundry:test:mainnet         # fork against Hedera mainnet (295)
yarn foundry:deploy               # Forge deploy scripts
yarn foundry:verify:testnet       # verify via Sourcify
yarn foundry:lint                 # NOTE: this is `make lint`, not eslint
yarn next:dev                     # frontend on :3000
yarn next:lint --max-warnings=0   # eslint; the flag belongs here and nowhere else
yarn next:check-types
yarn next:build
```

**`yarn foundry:lint` is `make lint`.** Passing `--max-warnings=0` to it makes GNU make dump its
usage text and exit non-zero. That flag is eslint-only and belongs on `next:lint`.

## Key paths

| Path | Purpose | Status |
| ---- | ------- | ------ |
| `packages/foundry/script/HelperConfig.s.sol` | Every external protocol address, per chain | built |
| `packages/foundry/test/HelperConfig.t.sol` | Address-book unit tests (hermetic) | built |
| `packages/foundry/test/integration/HelperConfigFork.t.sol` | Proves addresses are live on-chain | built |
| `packages/foundry/contracts/interfaces/IAgentAction.sol` | The adapter interface | built |
| `packages/foundry/contracts/AgentRegistry.sol` | Identity, operator binding, spend policy | built |
| `packages/foundry/contracts/ActionRouter.sol` | Executes via adapter, emits the receipt | built |
| `packages/foundry/contracts/adapters/SaucerSwapAdapter.sol` | Swap leg | built |
| `packages/foundry/contracts/adapters/BonzoAdapter.sol` | Supply / withdraw / repay leg | built |
| `packages/nextjs/services/hcs/` | Receipt writer + mirror node reader | planned |
| `packages/nextjs/components/agent/` | Registry browser, agent detail, audit feed | planned |
| `template.json` | Scaffold manifest — **required by the bounty gate** | built |

Keep the Status column honest. An agent that trusts a "built" row and finds nothing wastes a cycle.

## Addresses and config

**Chain IDs:** mainnet `295`, testnet `296`. Source of truth: `HelperConfig.s.sol`.

Verified against the mirror node on 2026-09-18. Bonzo's reserve lists were read on-chain from
`AaveProtocolDataProvider.getAllReservesTokens()` rather than copied from documentation.

### SaucerSwap (HAPI-created — long-zero addresses)

| Contract | Testnet | Mainnet |
| -------- | ------- | ------- |
| V2 SwapRouter | `0.0.1414040` | `0.0.3949434` |
| V2 QuoterV2 | `0.0.1390002` | `0.0.3949424` |
| V2 Factory | `0.0.1197038` | `0.0.3946833` |
| WHBAR contract | `0.0.15057` | `0.0.1456985` |
| WHBAR token | `0.0.15058` | `0.0.1456986` |

`QuoterV2.quoteExactInput` is `nonpayable`, not `view`. It must be simulated, not called as a read.

### Bonzo (EVM-deployed — keccak addresses)

Aave v2 fork. `LendingPool`, `AaveOracle`, `AaveProtocolDataProvider`, `WETHGateway` behave as in
Aave v2; the Aave v2 docs apply.

| Contract | Testnet | Mainnet |
| -------- | ------- | ------- |
| LendingPool | `0.0.4999355` | `0.0.7308459` |
| LendingPoolAddressesProvider | `0.0.4999346` | `0.0.7308451` |
| AaveProtocolDataProvider | `0.0.4999382` | `0.0.7308483` |
| WETHGateway | `0.0.4999384` | `0.0.7308485` |
| AaveOracle | `0.0.4999377` | `0.0.7308480` |

**Testnet reserves:** XSAUCE, USDC, KARATE, HBARX, SAUCE, WHBAR.
**Mainnet reserves:** the above plus DOVU, HST, PACK, STEAM, GRELF, KBL, BONZO, WETH.

Testnet assets come from the Bonzo Discord `#testnet-faucet`, or by swapping testnet HBAR on
[testnet.saucerswap.finance](https://testnet.saucerswap.finance). HBAR itself:
[portal.hedera.com/faucet](https://portal.hedera.com/faucet).

## Frontend contract interaction

Hooks live in `packages/nextjs/hooks/scaffold-hbar`. Use the names that exist:

- `useScaffoldReadContract` — not `useScaffoldContractRead`
- `useScaffoldWriteContract` — not `useScaffoldContractWrite`

Also: `useScaffoldWatchContractEvent`, `useScaffoldEventHistory`, `useDeployedContractInfo`,
`useScaffoldContract`, `useTransactor`.

```typescript
const { data: agent } = useScaffoldReadContract({
  contractName: "AgentRegistry",
  functionName: "agentOf",
  args: [agentId],
});
```

After deploy, ABIs and addresses land in `packages/nextjs/contracts/deployedContracts.ts`
(generated — do not hand-edit). Third-party ABIs go in
`packages/nextjs/contracts/externalContracts.ts`.

Network config: `packages/nextjs/scaffold.config.ts` (target networks, polling, RPC overrides,
WalletConnect).

### UI

Use `@scaffold-hbar-ui/components` for web3 UI: `Address`, `AddressInput`, `Balance`, `EtherInput`,
`IntegerInput`. Prefer DaisyUI classes over raw Tailwind where a DaisyUI component exists.

## Style

| Style | Use |
| --- | --- |
| `UpperCamelCase` | types, components, contracts |
| `lowerCamelCase` | variables, functions |
| `CONSTANT_CASE` | constants |
| `snake_case` | Foundry script filenames |

Solidity formatting is set in `foundry.toml`: 120 columns, 4-space tabs, double quotes.
Next.js imports use the `~~` alias. Add `"use client"` to pages that use hooks.

Prefer `type` over `interface` in TypeScript. No `T` prefix on types. Let TypeScript infer when it
can. Comments should add information — if a comment restates the line below it, delete it.
