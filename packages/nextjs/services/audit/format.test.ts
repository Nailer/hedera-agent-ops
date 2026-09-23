import {
  describeAmount,
  describeReceipt,
  formatTokenAmount,
  hashscanAddressUrl,
  hashscanTransactionUrl,
  networkForChainId,
  relativeTime,
  shortenAddress,
} from "./format";
import type { AuditReceipt } from "./types";
import { describe, expect, it } from "vitest";
import type { TokenMetadata } from "~~/services/tokens/tokenMetadata";

const SAUCE: TokenMetadata = { tokenId: "0.0.1183558", symbol: "SAUCE", name: "Sauce", decimals: 6 };
const WHBAR: TokenMetadata = { tokenId: "0.0.15058", symbol: "WHBAR", name: "WHBAR", decimals: 8 };

const ASSET_IN = "0x0000000000000000000000000000000000003aD2";
const ASSET_OUT = "0x0000000000000000000000000000000000120f46";

const tokens = new Map<string, TokenMetadata>([
  [ASSET_IN.toLowerCase(), WHBAR],
  [ASSET_OUT.toLowerCase(), SAUCE],
]);

function receipt(overrides: Partial<AuditReceipt> = {}): AuditReceipt {
  return {
    agentId: 1n,
    protocolId: "saucerswap-v2",
    kind: "Swap",
    operator: "0x1111111111111111111111111111111111111111",
    assetIn: ASSET_IN,
    amountIn: 100_000_000n,
    assetOut: ASSET_OUT,
    amountOut: 46_482_761n,
    protocolRef: "0xdead",
    sequence: 1n,
    consensusTimestamp: "1729179977.085503000",
    consensusAt: new Date(1729179977085),
    transactionHash: "0xb8eab6589f3ed2d1842006404387442bfa0f58589c47f338a82417478d0336b7",
    blockNumber: 10595774,
    ...overrides,
  } as AuditReceipt;
}

describe("formatTokenAmount", () => {
  it("places the decimal point according to the token's decimals", () => {
    expect(formatTokenAmount(46_482_761n, 6)).toBe("46.482761");
    expect(formatTokenAmount(100_000_000n, 8)).toBe("1");
  });

  it("groups thousands", () => {
    expect(formatTokenAmount(1_234_567_890_123n, 6)).toBe("1,234,567.890123");
  });

  it("trims trailing zeros rather than padding the fraction", () => {
    expect(formatTokenAmount(1_500_000n, 6)).toBe("1.5");
    expect(formatTokenAmount(2_000_000n, 6)).toBe("2");
  });

  it("pads amounts smaller than one unit", () => {
    expect(formatTokenAmount(1n, 6)).toBe("0.000001");
    expect(formatTokenAmount(123n, 6)).toBe("0.000123");
  });

  it("returns the raw value for a zero-decimal token", () => {
    expect(formatTokenAmount(42n, 0)).toBe("42");
  });

  it("handles zero", () => {
    expect(formatTokenAmount(0n, 6)).toBe("0");
  });

  /**
   * The reason this uses BigInt string arithmetic rather than dividing a Number. An HTS amount can
   * exceed Number.MAX_SAFE_INTEGER, and the float route rounds silently — an audit trail that
   * quietly misreports what moved is worse than one that shows nothing.
   */
  it("does not lose precision on amounts beyond Number.MAX_SAFE_INTEGER", () => {
    const huge = 123456789012345678901234567890n;
    expect(formatTokenAmount(huge, 18)).toBe("123,456,789,012.345678");
    expect(formatTokenAmount(9_007_199_254_740_993n, 0)).toBe("9007199254740993");
  });

  it("caps the fraction at the requested number of digits", () => {
    expect(formatTokenAmount(1_234_567_891n, 9, 3)).toBe("1.234");
  });

  it("keeps the sign on negative amounts", () => {
    expect(formatTokenAmount(-1_500_000n, 6)).toBe("-1.5");
  });
});

describe("shortenAddress", () => {
  it("elides the middle of a full address", () => {
    expect(shortenAddress("0x0000000000000000000000000000000000120f46")).toBe("0x0000…0f46");
  });

  it("leaves a short string alone", () => {
    expect(shortenAddress("0x1234")).toBe("0x1234");
  });
});

describe("hashscan links", () => {
  it("builds testnet links by default", () => {
    expect(hashscanTransactionUrl("0xabc")).toBe("https://hashscan.io/testnet/transaction/0xabc");
    expect(hashscanAddressUrl("0xdef")).toBe("https://hashscan.io/testnet/address/0xdef");
  });

  it("builds mainnet links when asked", () => {
    expect(hashscanTransactionUrl("0xabc", "mainnet")).toBe("https://hashscan.io/mainnet/transaction/0xabc");
  });

  it("maps chain ids to networks", () => {
    expect(networkForChainId(295)).toBe("mainnet");
    expect(networkForChainId(296)).toBe("testnet");
  });
});

describe("describeAmount", () => {
  it("renders the amount with its symbol when the token is known", () => {
    expect(describeAmount(46_482_761n, SAUCE, ASSET_OUT)).toBe("46.482761 SAUCE");
  });

  /// Showing the raw number is honest. Guessing decimals would misreport the amount.
  it("falls back to the raw value and a short address for an unknown token", () => {
    expect(describeAmount(46_482_761n, undefined, ASSET_OUT)).toBe("46482761 (0x0000…0f46)");
  });
});

describe("describeReceipt", () => {
  it("describes a swap in both legs", () => {
    expect(describeReceipt(receipt(), tokens)).toBe("Swapped 1 WHBAR for 46.482761 SAUCE");
  });

  it("describes a supply", () => {
    expect(describeReceipt(receipt({ kind: "Supply" }), tokens)).toBe("Supplied 1 WHBAR, received 46.482761 SAUCE");
  });

  it("describes a withdraw as redeeming the input", () => {
    expect(describeReceipt(receipt({ kind: "Withdraw" }), tokens)).toBe(
      "Withdrew 46.482761 SAUCE by redeeming 1 WHBAR",
    );
  });

  it("describes a borrow by what arrived", () => {
    expect(describeReceipt(receipt({ kind: "Borrow" }), tokens)).toBe("Borrowed 46.482761 SAUCE");
  });

  /**
   * Repay is phrased around the refund because its amountOut is the unspent remainder, not
   * something received. Calling that "received" would read as though the agent gained it.
   */
  it("describes a repay with change as a refund", () => {
    expect(describeReceipt(receipt({ kind: "Repay" }), tokens)).toBe("Repaid with 1 WHBAR, 46.482761 SAUCE returned");
  });

  it("describes an exact repay without mentioning a refund", () => {
    expect(describeReceipt(receipt({ kind: "Repay", amountOut: 0n }), tokens)).toBe("Repaid 1 WHBAR");
  });

  it("still describes a receipt whose tokens are unknown", () => {
    expect(describeReceipt(receipt(), new Map())).toContain("100000000");
  });
});

describe("relativeTime", () => {
  const now = new Date("2026-09-23T12:00:00Z");

  it.each([
    [new Date("2026-09-23T11:59:40Z"), "just now"],
    [new Date("2026-09-23T11:56:00Z"), "4 minutes ago"],
    [new Date("2026-09-23T11:00:00Z"), "1 hour ago"],
    [new Date("2026-09-21T12:00:00Z"), "2 days ago"],
  ])("renders %s as %s", (then, expected) => {
    expect(relativeTime(then, now)).toBe(expected);
  });

  it("singularises one minute", () => {
    expect(relativeTime(new Date("2026-09-23T11:59:00Z"), now)).toBe("1 minute ago");
  });

  /// Mirror node timestamps can land marginally ahead of local clock skew.
  it("does not produce a negative duration", () => {
    expect(relativeTime(new Date("2026-09-23T12:00:30Z"), now)).toBe("in the future");
  });
});
