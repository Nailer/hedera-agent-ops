import { ACTION_KINDS, type ActionKind, type AuditReceipt, consensusTimestampToDate } from "./types";
import { decodeAbiParameters, hexToString } from "viem";

/**
 * Decodes one `ActionExecuted` log from the mirror node into a typed receipt.
 *
 * The event is:
 *
 * ```solidity
 * event ActionExecuted(
 *     uint256 indexed agentId,
 *     bytes32 indexed protocolId,
 *     ActionKind indexed kind,
 *     address operator, address assetIn, uint256 amountIn,
 *     address assetOut, uint256 amountOut, bytes32 protocolRef, uint256 sequence
 * );
 * ```
 *
 * Three parameters are indexed, so they arrive in `topics[1..3]` rather than in `data`. The
 * remaining seven are ABI-encoded in `data` in declaration order. Decoding the wrong set from the
 * wrong place is the classic failure here, and it does not error — it silently yields plausible
 * nonsense, which is why the topic count is asserted before anything is read.
 */

/**
 * The event signature, exactly as it appears in the compiled ABI. Note `uint8` for the enum —
 * Solidity encodes enums as their smallest fitting uint, and writing `ActionKind` here would
 * produce a different, wrong selector.
 */
export const ACTION_EXECUTED_SIGNATURE =
  "ActionExecuted(uint256,bytes32,uint8,address,address,uint256,address,uint256,bytes32,uint256)" as const;

/**
 * `keccak256(ACTION_EXECUTED_SIGNATURE)`, used to filter mirror node logs to just our receipts.
 * A test derives this from the signature and asserts they agree, so changing the event without
 * updating this fails the suite rather than silently returning no receipts.
 */
export const ACTION_EXECUTED_TOPIC0 = "0x0e3aff325d7c5fd044174daccd6f080b89ea3e7d6247ce7e0b55ac69f1c9029d" as const;

/**
 * The non-indexed tail of the event, in declaration order.
 *
 * @dev Written as a const-asserted array rather than via `parseAbiParameters`, which returns a
 *      runtime-computed type. viem can then infer `0x${string}` for the addresses and `bigint` for
 *      the uints, so the decoded tuple lands in `AuditReceipt` without a cast. A cast would compile
 *      just as happily while hiding a genuine mismatch.
 */
const DATA_PARAMS = [
  { name: "operator", type: "address" },
  { name: "assetIn", type: "address" },
  { name: "amountIn", type: "uint256" },
  { name: "assetOut", type: "address" },
  { name: "amountOut", type: "uint256" },
  { name: "protocolRef", type: "bytes32" },
  { name: "sequence", type: "uint256" },
] as const;

export type MirrorNodeLog = {
  address: string;
  topics: string[];
  data: string;
  timestamp: string;
  block_number: number;
  transaction_hash: string;
  index: number;
};

export class ReceiptDecodeError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ReceiptDecodeError";
  }
}

/**
 * `bytes32("saucerswap-v2")` is the ASCII bytes left-aligned and zero-padded. Trimming the trailing
 * NULs recovers the label; anything non-printable means this was not a string-encoded identifier
 * and is surfaced as hex rather than as mojibake.
 */
export function decodeProtocolId(raw: string): string {
  const text = hexToString(raw as `0x${string}`).replace(/\0+$/, "");
  return /^[\x20-\x7e]*$/.test(text) && text.length > 0 ? text : raw;
}

function decodeActionKind(raw: string): ActionKind {
  const index = Number(BigInt(raw));
  const kind = ACTION_KINDS[index];
  if (kind === undefined) {
    // An unknown enum value means the contract emitted a variant this build does not know about,
    // i.e. the frontend is older than the deployment. Better to say so than to mislabel it.
    throw new ReceiptDecodeError(`Unknown ActionKind ordinal ${index}`);
  }
  return kind;
}

export function decodeReceipt(log: MirrorNodeLog): AuditReceipt {
  if (log.topics.length !== 4) {
    throw new ReceiptDecodeError(
      `Expected 4 topics for ActionExecuted (signature + 3 indexed), received ${log.topics.length}`,
    );
  }

  const [, agentIdTopic, protocolIdTopic, kindTopic] = log.topics;

  // viem widens `address` and `bytes32` to `string` here rather than to `0x${string}`, so the tuple
  // is narrowed explicitly. Widening `AuditReceipt` instead would push untyped hex onto every
  // consumer. The narrowing is safe because `decodeAbiParameters` throws on data that does not match
  // `DATA_PARAMS`, and the round-trip tests encode with these exact params and assert every field
  // comes back byte-identical.
  const [operator, assetIn, amountIn, assetOut, amountOut, protocolRef, sequence] = decodeAbiParameters(
    DATA_PARAMS,
    log.data as `0x${string}`,
  ) as readonly [`0x${string}`, `0x${string}`, bigint, `0x${string}`, bigint, `0x${string}`, bigint];

  return {
    agentId: BigInt(agentIdTopic),
    protocolId: decodeProtocolId(protocolIdTopic),
    kind: decodeActionKind(kindTopic),
    operator,
    assetIn,
    amountIn,
    assetOut,
    amountOut,
    protocolRef,
    sequence,
    consensusTimestamp: log.timestamp,
    consensusAt: consensusTimestampToDate(log.timestamp),
    transactionHash: log.transaction_hash as `0x${string}`,
    blockNumber: log.block_number,
  };
}
