import { ACTION_EXECUTED_TOPIC0, type MirrorNodeLog } from "./decodeReceipt";
import {
  MAX_TOPIC_WINDOW_SECONDS,
  MirrorNodeError,
  assertWindowIsQueryable,
  buildLogsPath,
  fetchAgentReceipts,
  latestWindow,
  previousWindow,
} from "./mirrorNode";
import { encodeAbiParameters, pad, parseAbiParameters, stringToHex } from "viem";
import { describe, expect, it, vi } from "vitest";

/** A fixed, valid window so path assertions do not depend on the clock. */
const WINDOW = { fromSeconds: 1_789_464_870, toSeconds: 1_789_983_270 };

const ROUTER = "0xf67DBe9bD1B331cA379c44b5562EAa1CE831EbC2";

const DATA_PARAMS = parseAbiParameters(
  "address operator, address assetIn, uint256 amountIn, address assetOut, uint256 amountOut, bytes32 protocolRef, uint256 sequence",
);

function log(sequence: bigint): MirrorNodeLog {
  return {
    address: ROUTER.toLowerCase(),
    topics: [
      ACTION_EXECUTED_TOPIC0,
      pad("0x07", { size: 32 }),
      pad(stringToHex("saucerswap-v2"), { size: 32, dir: "right" }),
      pad("0x00", { size: 32 }),
    ],
    data: encodeAbiParameters(DATA_PARAMS, [
      "0x1111111111111111111111111111111111111111",
      "0x2222222222222222222222222222222222222222",
      1_000_000n,
      "0x3333333333333333333333333333333333333333",
      42n,
      pad("0xdeadbeef", { size: 32 }),
      sequence,
    ]),
    timestamp: "1729179977.085503000",
    block_number: 10595774,
    transaction_hash: "0xb8eab6589f3ed2d1842006404387442bfa0f58589c47f338a82417478d0336b7",
    index: 0,
  };
}

function respond(body: unknown, ok = true, status = 200) {
  return vi.fn().mockResolvedValue({
    ok,
    status,
    json: async () => body,
  } as unknown as Response);
}

/**
 * The mirror node refuses topic-filtered queries without a bounded timestamp range, and rejects any
 * range wider than 7 days. Both were found by calling the live API — `topic0` alone returns HTTP
 * 400 "Cannot search topics without a valid timestamp range", and an 8-day range returns "must be
 * positive and within 7d". These tests pin that behaviour so the constraint cannot be refactored
 * away by someone who has not hit it.
 */
describe("time windows", () => {
  it("caps the maximum window at 7 days", () => {
    expect(MAX_TOPIC_WINDOW_SECONDS).toBe(7 * 24 * 60 * 60);
  });

  it("produces a latest window that the mirror node would accept", () => {
    const window = latestWindow(1_789_983_270);
    expect(window.toSeconds).toBe(1_789_983_270);
    expect(window.toSeconds - window.fromSeconds).toBeLessThan(MAX_TOPIC_WINDOW_SECONDS);
    expect(() => assertWindowIsQueryable(window)).not.toThrow();
  });

  /// Windows must not overlap, or a receipt on the boundary is returned in both pages.
  it("steps back without overlapping the previous window", () => {
    const first = latestWindow(1_789_983_270);
    const second = previousWindow(first);

    expect(second.toSeconds).toBe(first.fromSeconds - 1);
    expect(second.toSeconds).toBeLessThan(first.fromSeconds);
    expect(() => assertWindowIsQueryable(second)).not.toThrow();
  });

  it("keeps stepping back indefinitely without producing an invalid window", () => {
    let window = latestWindow(1_789_983_270);
    for (let i = 0; i < 10; i++) {
      window = previousWindow(window);
      expect(() => assertWindowIsQueryable(window)).not.toThrow();
    }
  });

  it("rejects a window of exactly 7 days, which the API refuses", () => {
    const window = { fromSeconds: 1_000_000, toSeconds: 1_000_000 + MAX_TOPIC_WINDOW_SECONDS };
    expect(() => assertWindowIsQueryable(window)).toThrow(MirrorNodeError);
  });

  it("rejects an inverted window", () => {
    expect(() => assertWindowIsQueryable({ fromSeconds: 200, toSeconds: 100 })).toThrow(MirrorNodeError);
  });

  it("rejects negative bounds", () => {
    expect(() => assertWindowIsQueryable({ fromSeconds: -1, toSeconds: 100 })).toThrow(MirrorNodeError);
  });
});

describe("buildLogsPath", () => {
  /// Without both bounds the live API returns 400. Asserting both are present is the regression
  /// guard for the bug that would otherwise make every audit query fail.
  it("emits both a lower and an upper timestamp bound", () => {
    const path = buildLogsPath({ routerAddress: ROUTER, window: WINDOW });
    expect(path).toContain(`timestamp=${encodeURIComponent(`gte:${WINDOW.fromSeconds}`)}`);
    expect(path).toContain(`timestamp=${encodeURIComponent(`lte:${WINDOW.toSeconds}`)}`);
  });

  it("refuses to build a path for a window the API would reject", () => {
    const tooWide = { fromSeconds: 1_000_000, toSeconds: 1_000_000 + MAX_TOPIC_WINDOW_SECONDS + 1 };
    expect(() => buildLogsPath({ routerAddress: ROUTER, window: tooWide })).toThrow(MirrorNodeError);
  });

  it("falls back to the latest window when none is given", () => {
    expect(buildLogsPath({ routerAddress: ROUTER })).toContain("timestamp=");
  });

  it("filters to ActionExecuted by topic0", () => {
    expect(buildLogsPath({ routerAddress: ROUTER, window: WINDOW })).toContain(
      `topic0=${encodeURIComponent(ACTION_EXECUTED_TOPIC0)}`,
    );
  });

  /// agentId is the first indexed parameter, so it belongs in topic1, left-padded to 32 bytes.
  /// An unpadded value silently matches nothing.
  it("puts agentId in topic1, padded to 32 bytes", () => {
    const path = buildLogsPath({ routerAddress: ROUTER, agentId: 7n, window: WINDOW });
    expect(path).toContain(encodeURIComponent(pad("0x07", { size: 32 })));
  });

  it("omits topic1 entirely when no agent is given", () => {
    expect(buildLogsPath({ routerAddress: ROUTER, window: WINDOW })).not.toContain("topic1");
  });

  it("targets the router's logs endpoint", () => {
    expect(buildLogsPath({ routerAddress: ROUTER, window: WINDOW })).toContain(
      `/api/v1/contracts/${ROUTER}/results/logs`,
    );
  });

  it("defaults to newest first", () => {
    expect(buildLogsPath({ routerAddress: ROUTER, window: WINDOW })).toContain("order=desc");
  });
});

describe("fetchAgentReceipts", () => {
  it("decodes the returned logs", async () => {
    const fetchImpl = respond({ logs: [log(1n), log(2n)], links: { next: null } });

    const page = await fetchAgentReceipts({ routerAddress: ROUTER, window: WINDOW, fetchImpl });

    expect(page.receipts).toHaveLength(2);
    expect(page.receipts[0].sequence).toBe(1n);
    expect(page.receipts[1].sequence).toBe(2n);
    expect(page.receipts[0].protocolId).toBe("saucerswap-v2");
  });

  it("returns an empty page rather than throwing when there are no logs", async () => {
    const page = await fetchAgentReceipts({ routerAddress: ROUTER, window: WINDOW, fetchImpl: respond({ logs: [] }) });
    expect(page.receipts).toEqual([]);
    expect(page.nextCursor).toBeNull();
  });

  it("treats an absent links block as the end of the trail", async () => {
    const page = await fetchAgentReceipts({
      routerAddress: ROUTER,
      window: WINDOW,
      fetchImpl: respond({ logs: [log(1n)] }),
    });
    expect(page.nextCursor).toBeNull();
  });

  it("surfaces the mirror node's next cursor", async () => {
    const next = "/api/v1/contracts/x/results/logs?limit=25&timestamp=lte:1729179977.085503000&index=lt:0";
    const page = await fetchAgentReceipts({
      routerAddress: ROUTER,
      fetchImpl: respond({ logs: [log(1n)], links: { next } }),
    });
    expect(page.nextCursor).toBe(next);
  });

  /**
   * The cursor already encodes every filter from the original query. Rebuilding the path would drop
   * those bounds and re-read the first page forever.
   */
  it("follows a cursor verbatim instead of rebuilding the query", async () => {
    const cursor = "/api/v1/contracts/x/results/logs?limit=25&timestamp=lte:123.456&index=lt:0";
    const fetchImpl = respond({ logs: [], links: { next: null } });

    await fetchAgentReceipts({ routerAddress: ROUTER, cursor, fetchImpl });

    expect(fetchImpl).toHaveBeenCalledWith(`https://testnet.mirrornode.hedera.com${cursor}`);
  });

  it("strips a trailing slash from the base url so the path is not doubled", async () => {
    const fetchImpl = respond({ logs: [] });
    await fetchAgentReceipts({
      routerAddress: ROUTER,
      window: WINDOW,
      mirrorNodeUrl: "https://testnet.mirrornode.hedera.com/",
      fetchImpl,
    });
    const called = fetchImpl.mock.calls[0][0] as string;
    expect(called).not.toContain("com//api");
  });

  it("raises a typed error carrying the status on a non-ok response", async () => {
    const fetchImpl = respond({}, false, 502);
    await expect(fetchAgentReceipts({ routerAddress: ROUTER, window: WINDOW, fetchImpl })).rejects.toMatchObject({
      name: "MirrorNodeError",
      status: 502,
    });
  });

  it("wraps a network failure rather than leaking it raw", async () => {
    const fetchImpl = vi.fn().mockRejectedValue(new Error("connection reset"));
    await expect(fetchAgentReceipts({ routerAddress: ROUTER, window: WINDOW, fetchImpl })).rejects.toBeInstanceOf(
      MirrorNodeError,
    );
  });

  it("propagates a decode failure instead of silently dropping the receipt", async () => {
    const malformed = { ...log(1n), topics: [ACTION_EXECUTED_TOPIC0] };
    await expect(
      fetchAgentReceipts({ routerAddress: ROUTER, window: WINDOW, fetchImpl: respond({ logs: [malformed] }) }),
    ).rejects.toThrow();
  });
});
