"use client";

import { useCallback, useEffect, useState } from "react";
import { type TimeWindow, fetchAgentReceipts, latestWindow, previousWindow } from "~~/services/audit/mirrorNode";
import type { AuditReceipt } from "~~/services/audit/types";
import { type TokenMetadata, fetchTokenMetadataMany } from "~~/services/tokens/tokenMetadata";

/**
 * Loads an agent's audit trail from the mirror node.
 *
 * @dev Paging here has two levels, which is a consequence of the mirror node rather than a design
 * choice. Within a 7-day window it follows `links.next`; to reach anything older it has to open a
 * new window, because topic-filtered queries are rejected outright beyond 7 days. `loadMore`
 * handles both: it follows the cursor while one exists, then steps the window back.
 *
 * Token metadata is resolved for whatever assets appear, so amounts render with the right decimals
 * without the frontend holding an address book of its own.
 */

export type UseAgentAuditTrailOptions = {
  routerAddress: string | undefined;
  agentId?: bigint;
  mirrorNodeUrl?: string;
  /** How many empty windows to walk back before concluding there is nothing older. */
  maxEmptyWindows?: number;
};

export type UseAgentAuditTrailResult = {
  receipts: AuditReceipt[];
  tokens: Map<string, TokenMetadata>;
  isLoading: boolean;
  error: Error | undefined;
  hasMore: boolean;
  loadMore: () => void;
  reload: () => void;
};

const DEFAULT_MAX_EMPTY_WINDOWS = 4;

export function useAgentAuditTrail(options: UseAgentAuditTrailOptions): UseAgentAuditTrailResult {
  const { routerAddress, agentId, mirrorNodeUrl } = options;
  const maxEmptyWindows = options.maxEmptyWindows ?? DEFAULT_MAX_EMPTY_WINDOWS;

  const [receipts, setReceipts] = useState<AuditReceipt[]>([]);
  const [tokens, setTokens] = useState<Map<string, TokenMetadata>>(new Map());
  const [cursor, setCursor] = useState<string | null>(null);
  const [window, setWindow] = useState<TimeWindow | undefined>(undefined);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<Error | undefined>(undefined);
  const [hasMore, setHasMore] = useState(true);
  const [reloadKey, setReloadKey] = useState(0);

  const resolveTokens = useCallback(
    async (incoming: AuditReceipt[]) => {
      const addresses = incoming.flatMap(r => [r.assetIn, r.assetOut]);
      if (addresses.length === 0) return;

      const resolved = await fetchTokenMetadataMany(addresses, { mirrorNodeUrl });
      setTokens(previous => new Map([...previous, ...resolved]));
    },
    [mirrorNodeUrl],
  );

  const load = useCallback(
    async (from: { window: TimeWindow; cursor: string | null }) => {
      if (!routerAddress) return;

      setIsLoading(true);
      setError(undefined);

      try {
        let activeWindow = from.window;
        let activeCursor = from.cursor;
        let emptyWindows = 0;

        // Walk back through windows until something turns up or we give up. A window with no
        // receipts is normal — an agent simply did nothing that week.
        for (;;) {
          const page = await fetchAgentReceipts({
            routerAddress,
            agentId,
            window: activeWindow,
            cursor: activeCursor,
            mirrorNodeUrl,
          });

          if (page.receipts.length > 0) {
            setReceipts(previous => [...previous, ...page.receipts]);
            await resolveTokens(page.receipts);

            setWindow(activeWindow);
            setCursor(page.nextCursor);
            setHasMore(true);
            return;
          }

          if (page.nextCursor) {
            activeCursor = page.nextCursor;
            continue;
          }

          emptyWindows += 1;
          if (emptyWindows >= maxEmptyWindows) {
            setWindow(activeWindow);
            setCursor(null);
            setHasMore(false);
            return;
          }

          activeWindow = previousWindow(activeWindow);
          activeCursor = null;
        }
      } catch (cause) {
        setError(cause as Error);
      } finally {
        setIsLoading(false);
      }
    },
    [routerAddress, agentId, mirrorNodeUrl, maxEmptyWindows, resolveTokens],
  );

  useEffect(() => {
    setReceipts([]);
    setTokens(new Map());
    setCursor(null);
    setWindow(undefined);
    setHasMore(true);

    if (!routerAddress) return;
    void load({ window: latestWindow(), cursor: null });
    // `load` is stable for a given router/agent, and re-running on every render would re-fetch.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [routerAddress, agentId, mirrorNodeUrl, reloadKey]);

  const loadMore = useCallback(() => {
    if (isLoading || !hasMore || !window) return;

    // Cursor first: it continues inside the current window. Only once it is exhausted does the
    // window step back, because the two must not be advanced at the same time.
    void load(cursor ? { window, cursor } : { window: previousWindow(window), cursor: null });
  }, [isLoading, hasMore, window, cursor, load]);

  const reload = useCallback(() => setReloadKey(key => key + 1), []);

  return { receipts, tokens, isLoading, error, hasMore, loadMore, reload };
}
