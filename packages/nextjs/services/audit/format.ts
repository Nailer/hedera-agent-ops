import type { AuditReceipt } from "./types";
import type { TokenMetadata } from "~~/services/tokens/tokenMetadata";

/**
 * Presentation helpers for the audit trail.
 *
 * Kept as pure functions rather than inline JSX so they can be tested directly. The components that
 * use them stay thin enough that rendering them adds no logic worth asserting.
 */

/**
 * Formats a raw on-chain amount using the token's decimals.
 *
 * @dev Done with BigInt string arithmetic rather than `Number(raw) / 10 ** decimals`. An HTS amount
 *      can exceed `Number.MAX_SAFE_INTEGER`, and the float route silently rounds — an audit trail
 *      that quietly misreports what moved is worse than one that shows nothing.
 */
export function formatTokenAmount(raw: bigint, decimals: number, maxFractionDigits = 6): string {
  if (decimals === 0) return raw.toString();

  const negative = raw < 0n;
  const digits = (negative ? -raw : raw).toString().padStart(decimals + 1, "0");

  const whole = digits.slice(0, digits.length - decimals);
  let fraction = digits.slice(digits.length - decimals);

  fraction = fraction.slice(0, maxFractionDigits).replace(/0+$/, "");

  const withGrouping = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const body = fraction.length > 0 ? `${withGrouping}.${fraction}` : withGrouping;

  return negative ? `-${body}` : body;
}

/** `0x1234…cdef`, for addresses that are identifiers rather than things to read. */
export function shortenAddress(address: string, lead = 6, tail = 4): string {
  if (address.length <= lead + tail + 1) return address;
  return `${address.slice(0, lead)}…${address.slice(-tail)}`;
}

export type HederaNetwork = "testnet" | "mainnet";

export function networkForChainId(chainId: number): HederaNetwork {
  return chainId === 295 ? "mainnet" : "testnet";
}

export function hashscanTransactionUrl(transactionHash: string, network: HederaNetwork = "testnet"): string {
  return `https://hashscan.io/${network}/transaction/${transactionHash}`;
}

export function hashscanAddressUrl(address: string, network: HederaNetwork = "testnet"): string {
  return `https://hashscan.io/${network}/address/${address}`;
}

/**
 * Renders an amount with its symbol, falling back to the raw value and a shortened address when the
 * token could not be resolved. Showing the raw number is honest; inventing decimals is not.
 */
export function describeAmount(raw: bigint, token: TokenMetadata | undefined, tokenAddress: string): string {
  if (!token) return `${raw.toString()} (${shortenAddress(tokenAddress)})`;
  return `${formatTokenAmount(raw, token.decimals)} ${token.symbol}`;
}

/**
 * A one-line summary of a receipt.
 *
 * Reads what happened rather than restating field names, because the point of the audit trail is
 * that a person can check it. `Repay` is phrased around the refund, since its `amountOut` is the
 * unspent remainder rather than anything received.
 */
export function describeReceipt(receipt: AuditReceipt, tokens: Map<string, TokenMetadata>): string {
  const spent = describeAmount(receipt.amountIn, tokens.get(receipt.assetIn.toLowerCase()), receipt.assetIn);
  const received = describeAmount(receipt.amountOut, tokens.get(receipt.assetOut.toLowerCase()), receipt.assetOut);

  switch (receipt.kind) {
    case "Swap":
      return `Swapped ${spent} for ${received}`;
    case "Supply":
      return `Supplied ${spent}, received ${received}`;
    case "Withdraw":
      return `Withdrew ${received} by redeeming ${spent}`;
    case "Borrow":
      return `Borrowed ${received}`;
    case "Repay":
      return receipt.amountOut > 0n ? `Repaid with ${spent}, ${received} returned` : `Repaid ${spent}`;
  }
}

/**
 * "just now", "4 minutes ago", "2 days ago".
 *
 * @dev `now` is a parameter rather than read from the clock so the output is deterministic under
 *      test. A relative time helper that reads `Date.now()` internally cannot be asserted on.
 */
export function relativeTime(then: Date, now: Date = new Date()): string {
  const seconds = Math.floor((now.getTime() - then.getTime()) / 1000);

  if (seconds < 0) return "in the future";
  if (seconds < 45) return "just now";

  const units: [label: string, seconds: number][] = [
    ["day", 86400],
    ["hour", 3600],
    ["minute", 60],
  ];

  for (const [label, size] of units) {
    if (seconds >= size) {
      const count = Math.floor(seconds / size);
      return `${count} ${label}${count === 1 ? "" : "s"} ago`;
    }
  }

  return "just now";
}
