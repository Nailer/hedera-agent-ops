"use client";

import {
  describeReceipt,
  hashscanTransactionUrl,
  networkForChainId,
  relativeTime,
  shortenAddress,
} from "~~/services/audit/format";
import type { AuditReceipt } from "~~/services/audit/types";
import type { TokenMetadata } from "~~/services/tokens/tokenMetadata";

/**
 * The audit trail, as a list of receipts read back from the mirror node.
 *
 * Every row links to HashScan. That is the point of the whole feature: nothing here has to be taken
 * on trust, because each line names the transaction it came from and anyone can go and look.
 *
 * Deliberately thin — the formatting and phrasing live in `services/audit/format.ts` where they are
 * tested directly.
 */

type AuditFeedProps = {
  receipts: AuditReceipt[];
  tokens: Map<string, TokenMetadata>;
  chainId: number;
  isLoading: boolean;
  error?: Error;
  hasMore: boolean;
  onLoadMore: () => void;
};

export const AuditFeed = ({ receipts, tokens, chainId, isLoading, error, hasMore, onLoadMore }: AuditFeedProps) => {
  const network = networkForChainId(chainId);

  if (error) {
    return (
      <div className="alert alert-error">
        <span>Could not read the audit trail: {error.message}</span>
      </div>
    );
  }

  if (receipts.length === 0 && isLoading) {
    return (
      <div className="flex justify-center py-8">
        <span className="loading loading-spinner loading-lg" />
      </div>
    );
  }

  if (receipts.length === 0) {
    return (
      <div className="text-center py-8 opacity-70">
        <p>No actions recorded yet.</p>
        <p className="text-sm mt-1">
          Receipts appear here once an agent executes through the router. The mirror node is eventually consistent, so a
          very recent action may take a moment.
        </p>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-3">
      {receipts.map(receipt => (
        <div key={`${receipt.transactionHash}-${receipt.sequence}`} className="card bg-base-100 shadow-sm">
          <div className="card-body p-4">
            <div className="flex items-start justify-between gap-4 flex-wrap">
              <div className="flex flex-col gap-1">
                <div className="flex items-center gap-2 flex-wrap">
                  <span className="badge badge-primary badge-sm">{receipt.kind}</span>
                  <span className="badge badge-ghost badge-sm">{receipt.protocolId}</span>
                  <span className="text-xs opacity-60">#{receipt.sequence.toString()}</span>
                </div>
                <p className="font-medium">{describeReceipt(receipt, tokens)}</p>
                <p className="text-xs opacity-60">
                  agent {receipt.agentId.toString()} · operator {shortenAddress(receipt.operator)}
                </p>
              </div>

              <div className="flex flex-col items-end gap-1">
                <span className="text-xs opacity-60" title={receipt.consensusTimestamp}>
                  {relativeTime(receipt.consensusAt)}
                </span>
                <a
                  href={hashscanTransactionUrl(receipt.transactionHash, network)}
                  target="_blank"
                  rel="noreferrer"
                  className="link link-primary text-xs"
                >
                  verify on HashScan
                </a>
              </div>
            </div>
          </div>
        </div>
      ))}

      {hasMore && (
        <button className="btn btn-outline btn-sm self-center" onClick={onLoadMore} disabled={isLoading}>
          {isLoading ? <span className="loading loading-spinner loading-xs" /> : "Load older receipts"}
        </button>
      )}

      {!hasMore && <p className="text-center text-xs opacity-50 py-2">End of the recorded trail.</p>}
    </div>
  );
};
