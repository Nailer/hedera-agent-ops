/**
 * The audit trail's shape.
 *
 * A receipt is one `ActionExecuted` event emitted by `ActionRouter`, read back from the Hedera
 * mirror node. The router emits exactly one per successful action and no code path can skip it, so
 * the set of receipts for an agent is the complete record of what that agent has done.
 */

/** Mirrors `IAgentAction.ActionKind`. Order is significant — it is the on-chain enum encoding. */
export const ACTION_KINDS = ["Swap", "Supply", "Withdraw", "Borrow", "Repay"] as const;

export type ActionKind = (typeof ACTION_KINDS)[number];

export type AuditReceipt = {
  /** Which agent acted. */
  agentId: bigint;
  /** Adapter's stable protocol identifier, decoded from bytes32, e.g. "saucerswap-v2". */
  protocolId: string;
  kind: ActionKind;
  /** The operator key that submitted the action. */
  operator: `0x${string}`;
  assetIn: `0x${string}`;
  amountIn: bigint;
  assetOut: `0x${string}`;
  /**
   * What the router *measured* arriving, not what the adapter claimed. See `ActionRouter`: the
   * adapter's own figure is discarded for accounting, so this number survives a lying adapter.
   */
  amountOut: bigint;
  /** The venue touched — a pool address hash, or an aToken address. */
  protocolRef: `0x${string}`;
  /** Per-agent counter starting at 1, giving a total order independent of block ordering. */
  sequence: bigint;

  /** Hedera consensus timestamp as returned by the mirror node, `"seconds.nanos"`. */
  consensusTimestamp: string;
  /** The same instant as a JS Date, truncated to milliseconds. */
  consensusAt: Date;
  transactionHash: `0x${string}`;
  blockNumber: number;
};

/** One page of receipts. `nextCursor` is the mirror node's own relative `links.next` path. */
export type AuditPage = {
  receipts: AuditReceipt[];
  nextCursor: string | null;
};

/**
 * Converts a Hedera consensus timestamp (`"1729179977.085503000"`, seconds and nanoseconds) into a
 * Date.
 *
 * @dev Precision is deliberately lost here: consensus timestamps carry nanoseconds and a JS Date
 *      holds milliseconds. The full-precision string is kept alongside in `consensusTimestamp`,
 *      because it is what the mirror node's pagination cursors are built from — rounding it and
 *      feeding it back would skip or repeat records.
 */
export function consensusTimestampToDate(timestamp: string): Date {
  const [seconds, nanos = "0"] = timestamp.split(".");
  const millis = Number(seconds) * 1000 + Math.floor(Number(nanos.padEnd(9, "0")) / 1_000_000);
  return new Date(millis);
}
