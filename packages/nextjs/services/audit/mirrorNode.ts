import { ACTION_EXECUTED_TOPIC0, type MirrorNodeLog, decodeReceipt } from "./decodeReceipt";
import type { AuditPage } from "./types";
import { pad } from "viem";

/**
 * Reads the audit trail back from the Hedera mirror node.
 *
 * The router emits one `ActionExecuted` per successful action and no code path can skip it, so
 * these logs are the complete record of what an agent has done. Reading them from the mirror node
 * rather than from an indexer means the trail is verifiable by anyone holding the contract address
 * — no service in the middle to trust.
 *
 * @dev Three mirror node behaviours shape this file. The first two are not in the documentation and
 * were found by calling the live API:
 *
 * **Topic filtering requires a bounded timestamp range.** Querying `topic0` without one returns
 * HTTP 400: *"Cannot search topics without a valid timestamp range"*. Both a lower bound (`gt`/
 * `gte`) and an upper bound (`lt`/`lte`) are required — supplying only one is also rejected.
 *
 * **That range may not exceed 7 days.** Verified against the live API: a 6-day window is accepted,
 * an 8-day window returns *"must be positive and within 7d"*. So the full history of a long-lived
 * agent cannot be fetched in one query. `previousWindow` walks backwards a week at a time.
 *
 * **Pagination is cursor-based.** The response carries `links.next` as a *relative path* already
 * containing the right `timestamp=lte:` and `index=lt:` bounds. Follow it verbatim; constructing
 * offsets against a growing log set skips and repeats records.
 *
 * Mirror node reads are also eventually consistent. A transaction that has just succeeded on-chain
 * may not be queryable here yet, so anything that submits an action and reads it back must poll.
 */

export const DEFAULT_MIRROR_NODE_URL = "https://testnet.mirrornode.hedera.com";

/** The mirror node's hard ceiling on a topic-filtered timestamp range. */
export const MAX_TOPIC_WINDOW_SECONDS = 7 * 24 * 60 * 60;

export class MirrorNodeError extends Error {
  readonly status: number | undefined;

  constructor(message: string, status?: number) {
    super(message);
    this.name = "MirrorNodeError";
    this.status = status;
  }
}

/** A closed timestamp range in whole seconds, inclusive at both ends. */
export type TimeWindow = {
  fromSeconds: number;
  toSeconds: number;
};

type MirrorNodeLogsResponse = {
  logs?: MirrorNodeLog[];
  links?: { next?: string | null };
};

export type FetchReceiptsOptions = {
  /** The deployed `ActionRouter`, as an EVM address or a Hedera contract id. */
  routerAddress: string;
  /** Restrict to one agent. Omit for every agent's receipts. */
  agentId?: bigint;
  /** Required unless `cursor` is set — the mirror node rejects topic queries without one. */
  window?: TimeWindow;
  mirrorNodeUrl?: string;
  /** Mirror node caps this at 100. */
  limit?: number;
  /** A `links.next` value from a previous page. Used verbatim when set. */
  cursor?: string | null;
  /** Injectable for tests. */
  fetchImpl?: typeof fetch;
};

/** The most recent window the mirror node will accept, ending now. */
export function latestWindow(nowSeconds: number = Math.floor(Date.now() / 1000)): TimeWindow {
  return { fromSeconds: nowSeconds - MAX_TOPIC_WINDOW_SECONDS + 1, toSeconds: nowSeconds };
}

/**
 * The window immediately preceding `window`, for walking further back through an agent's history.
 * Ends one second before the given window starts, so the two never overlap and no receipt is
 * returned twice.
 */
export function previousWindow(window: TimeWindow): TimeWindow {
  const toSeconds = window.fromSeconds - 1;
  return { fromSeconds: toSeconds - MAX_TOPIC_WINDOW_SECONDS + 1, toSeconds };
}

export function assertWindowIsQueryable(window: TimeWindow): void {
  if (window.toSeconds < window.fromSeconds) {
    throw new MirrorNodeError(`Window ends before it starts: ${window.fromSeconds}..${window.toSeconds}`);
  }
  if (window.fromSeconds < 0) {
    throw new MirrorNodeError("Window bounds must be positive");
  }
  const span = window.toSeconds - window.fromSeconds;
  if (span >= MAX_TOPIC_WINDOW_SECONDS) {
    throw new MirrorNodeError(
      `Window spans ${span}s; the mirror node rejects topic queries wider than ${MAX_TOPIC_WINDOW_SECONDS}s (7 days)`,
    );
  }
}

/** Builds the relative logs path for the first page of a window. */
export function buildLogsPath(options: Omit<FetchReceiptsOptions, "fetchImpl" | "mirrorNodeUrl" | "cursor">): string {
  const window = options.window ?? latestWindow();
  assertWindowIsQueryable(window);

  const params = new URLSearchParams({
    topic0: ACTION_EXECUTED_TOPIC0,
    order: "desc",
    limit: String(options.limit ?? 25),
  });

  if (options.agentId !== undefined) {
    // agentId is the first indexed parameter, so it lands in topic1, left-padded to 32 bytes.
    params.set("topic1", pad(`0x${options.agentId.toString(16)}` as `0x${string}`, { size: 32 }));
  }

  // Appended rather than set: `timestamp` appears twice, once per bound.
  params.append("timestamp", `gte:${window.fromSeconds}`);
  params.append("timestamp", `lte:${window.toSeconds}`);

  return `/api/v1/contracts/${options.routerAddress}/results/logs?${params.toString()}`;
}

/**
 * Fetches one page of receipts.
 *
 * @returns The decoded receipts and the cursor for the next page within this window, or `null` when
 *          the window is exhausted. A `null` cursor does not mean the agent has no older history —
 *          it means this 7-day window is done. Use `previousWindow` to continue.
 */
export async function fetchAgentReceipts(options: FetchReceiptsOptions): Promise<AuditPage> {
  const base = (options.mirrorNodeUrl ?? DEFAULT_MIRROR_NODE_URL).replace(/\/+$/, "");
  const doFetch = options.fetchImpl ?? fetch;

  // A cursor already encodes every filter and bound from the original query, so it is used as-is.
  const path = options.cursor ?? buildLogsPath(options);

  let response: Response;
  try {
    response = await doFetch(`${base}${path}`);
  } catch (cause) {
    throw new MirrorNodeError(`Mirror node request failed: ${(cause as Error).message}`);
  }

  if (!response.ok) {
    throw new MirrorNodeError(`Mirror node returned ${response.status}`, response.status);
  }

  const body = (await response.json()) as MirrorNodeLogsResponse;
  const logs = body.logs ?? [];

  return {
    receipts: logs.map(decodeReceipt),
    // The mirror node signals "no more pages" with either a null or an absent `next`.
    nextCursor: body.links?.next ?? null,
  };
}
