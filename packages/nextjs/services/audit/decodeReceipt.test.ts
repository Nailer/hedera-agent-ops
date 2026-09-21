import {
  ACTION_EXECUTED_SIGNATURE,
  ACTION_EXECUTED_TOPIC0,
  type MirrorNodeLog,
  ReceiptDecodeError,
  decodeProtocolId,
  decodeReceipt,
} from "./decodeReceipt";
import { consensusTimestampToDate } from "./types";
import { encodeAbiParameters, pad, parseAbiParameters, stringToHex, toEventSelector } from "viem";
import { describe, expect, it } from "vitest";

/**
 * Decoding a log is the step where a mistake produces plausible nonsense rather than an error: read
 * the wrong field from the wrong place and you get a valid-looking address that means nothing. So
 * these tests build logs the way the chain does — indexed parameters into topics, the rest
 * ABI-encoded into data — and check the values come back out where they went in.
 */

const OPERATOR = "0x1111111111111111111111111111111111111111" as const;
const ASSET_IN = "0x2222222222222222222222222222222222222222" as const;
const ASSET_OUT = "0x3333333333333333333333333333333333333333" as const;
const PROTOCOL_REF = pad("0xdeadbeef", { size: 32 });

const DATA_PARAMS = parseAbiParameters(
  "address operator, address assetIn, uint256 amountIn, address assetOut, uint256 amountOut, bytes32 protocolRef, uint256 sequence",
);

function buildLog(overrides: Partial<MirrorNodeLog> = {}, values?: Partial<Record<string, bigint>>): MirrorNodeLog {
  const data = encodeAbiParameters(DATA_PARAMS, [
    OPERATOR,
    ASSET_IN,
    values?.amountIn ?? 1_000_000n,
    ASSET_OUT,
    values?.amountOut ?? 42n,
    PROTOCOL_REF,
    values?.sequence ?? 1n,
  ]);

  return {
    address: "0xf67dbe9bd1b331ca379c44b5562eaa1ce831ebc2",
    topics: [
      ACTION_EXECUTED_TOPIC0,
      pad(`0x${(values?.agentId ?? 7n).toString(16)}` as `0x${string}`, { size: 32 }),
      pad(stringToHex("saucerswap-v2"), { size: 32, dir: "right" }),
      pad(`0x${(values?.kind ?? 0n).toString(16)}` as `0x${string}`, { size: 32 }),
    ],
    data,
    timestamp: "1729179977.085503000",
    block_number: 10595774,
    transaction_hash: "0xb8eab6589f3ed2d1842006404387442bfa0f58589c47f338a82417478d0336b7",
    index: 0,
    ...overrides,
  };
}

describe("ACTION_EXECUTED_TOPIC0", () => {
  /**
   * The constant is hardcoded so it can be used without pulling in the ABI, which makes it possible
   * for it to drift from the event. Deriving it here means changing the event breaks this test
   * rather than silently returning zero receipts forever.
   */
  it("matches keccak256 of the event signature", () => {
    expect(ACTION_EXECUTED_TOPIC0).toBe(toEventSelector(`event ${ACTION_EXECUTED_SIGNATURE}`));
  });

  it("encodes the enum as uint8, not as a named type", () => {
    expect(ACTION_EXECUTED_SIGNATURE).toContain("uint8");
    expect(ACTION_EXECUTED_SIGNATURE).not.toContain("ActionKind");
  });
});

describe("decodeReceipt", () => {
  it("reads indexed parameters from topics and the rest from data", () => {
    const receipt = decodeReceipt(buildLog());

    expect(receipt.agentId).toBe(7n);
    expect(receipt.protocolId).toBe("saucerswap-v2");
    expect(receipt.kind).toBe("Swap");
    expect(receipt.operator).toBe(OPERATOR);
    expect(receipt.assetIn).toBe(ASSET_IN);
    expect(receipt.amountIn).toBe(1_000_000n);
    expect(receipt.assetOut).toBe(ASSET_OUT);
    expect(receipt.amountOut).toBe(42n);
    expect(receipt.protocolRef).toBe(PROTOCOL_REF);
    expect(receipt.sequence).toBe(1n);
  });

  it("carries the transaction hash and block number through", () => {
    const receipt = decodeReceipt(buildLog());
    expect(receipt.transactionHash).toBe("0xb8eab6589f3ed2d1842006404387442bfa0f58589c47f338a82417478d0336b7");
    expect(receipt.blockNumber).toBe(10595774);
  });

  it.each([
    [0n, "Swap"],
    [1n, "Supply"],
    [2n, "Withdraw"],
    [3n, "Borrow"],
    [4n, "Repay"],
  ])("decodes ActionKind ordinal %s as %s", (ordinal, expected) => {
    expect(decodeReceipt(buildLog({}, { kind: ordinal })).kind).toBe(expected);
  });

  /// An ordinal we do not know means the frontend is older than the deployment. Saying so beats
  /// mislabelling the action as whatever happens to be at index 0.
  it("rejects an unknown ActionKind ordinal", () => {
    expect(() => decodeReceipt(buildLog({}, { kind: 99n }))).toThrow(ReceiptDecodeError);
  });

  it("rejects a log with the wrong number of topics", () => {
    const log = buildLog();
    expect(() => decodeReceipt({ ...log, topics: log.topics.slice(0, 3) })).toThrow(ReceiptDecodeError);
    expect(() => decodeReceipt({ ...log, topics: [...log.topics, ACTION_EXECUTED_TOPIC0] })).toThrow(
      ReceiptDecodeError,
    );
  });

  it("preserves large amounts without precision loss", () => {
    const huge = 2n ** 255n - 1n;
    const receipt = decodeReceipt(buildLog({}, { amountIn: huge, amountOut: huge }));
    expect(receipt.amountIn).toBe(huge);
    expect(receipt.amountOut).toBe(huge);
  });
});

describe("decodeProtocolId", () => {
  it("recovers a string-encoded identifier", () => {
    expect(decodeProtocolId(pad(stringToHex("bonzo-v1"), { size: 32, dir: "right" }))).toBe("bonzo-v1");
  });

  /// A bytes32 that is not text should surface as hex rather than as mojibake.
  it("returns hex unchanged when the bytes are not printable ASCII", () => {
    const notText = pad("0xdeadbeef", { size: 32 });
    expect(decodeProtocolId(notText)).toBe(notText);
  });

  it("returns hex unchanged for all-zero bytes", () => {
    const zero = pad("0x00", { size: 32 });
    expect(decodeProtocolId(zero)).toBe(zero);
  });
});

describe("consensusTimestampToDate", () => {
  /**
   * Hedera timestamps are `seconds.nanos`. A Date holds milliseconds, so nanosecond precision is
   * lost on purpose — the full-precision string is kept separately because the mirror node's
   * pagination cursors are built from it.
   */
  it("converts seconds and nanoseconds to a Date", () => {
    const date = consensusTimestampToDate("1729179977.085503000");
    expect(date.getTime()).toBe(1729179977000 + 85);
  });

  it("handles a timestamp with no fractional part", () => {
    expect(consensusTimestampToDate("1729179977").getTime()).toBe(1729179977000);
  });

  it("pads short nanosecond fields rather than misreading them", () => {
    // ".5" is 500ms, not 5ns — the field is left-aligned within 9 digits.
    expect(consensusTimestampToDate("1729179977.5").getTime()).toBe(1729179977500);
  });
});
