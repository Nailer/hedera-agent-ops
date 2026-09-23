"use client";

import Link from "next/link";
import { useParams } from "next/navigation";
import type { NextPage } from "next";
import { AuditFeed } from "~~/components/agent/AuditFeed";
import { useDeployedContractInfo, useScaffoldReadContract, useTargetNetwork } from "~~/hooks/scaffold-hbar";
import { useAgentAuditTrail } from "~~/hooks/useAgentAuditTrail";
import { hashscanAddressUrl, networkForChainId, shortenAddress } from "~~/services/audit/format";

/**
 * One agent: who controls it, who operates it, where its funds sit, and everything it has done.
 *
 * The three roles are shown separately on purpose. The separation is the security model — a
 * compromised operator can spend within a limit the controller set and nothing more — and a page
 * that collapsed them into one "owner" would hide the property that matters most.
 */
const AgentDetailPage: NextPage = () => {
  const params = useParams<{ agentId: string }>();
  const { targetNetwork } = useTargetNetwork();
  const { data: routerInfo } = useDeployedContractInfo({ contractName: "ActionRouter" });

  const parsed = Number(params?.agentId);
  const isValidId = Number.isInteger(parsed) && parsed > 0;
  const agentId = isValidId ? BigInt(parsed) : undefined;

  const { data: agent, isLoading: isAgentLoading } = useScaffoldReadContract({
    contractName: "AgentRegistry",
    functionName: "agentOf",
    args: [agentId],
  });

  const { data: actionCount } = useScaffoldReadContract({
    contractName: "ActionRouter",
    functionName: "actionCount",
    args: [agentId],
  });

  const audit = useAgentAuditTrail({ routerAddress: routerInfo?.address, agentId });
  const network = networkForChainId(targetNetwork.id);

  if (!isValidId) {
    return (
      <div className="flex flex-col items-center py-20 gap-4">
        <p className="text-lg">Agent ids start at 1.</p>
        <Link href="/agents" className="btn btn-sm">
          Back to agents
        </Link>
      </div>
    );
  }

  const roles: [label: string, address: string | undefined, hint: string][] = [
    ["Controller", agent?.controller, "sets policy and can rotate the operator"],
    ["Operator", agent?.operator, "submits actions, and nothing else"],
    ["Treasury", agent?.treasury, "holds the funds and receives the output"],
  ];

  return (
    <div className="flex flex-col grow px-5 py-10 max-w-5xl mx-auto w-full gap-10">
      <header className="flex flex-col gap-2">
        <Link href="/agents" className="link text-sm w-fit opacity-70">
          ← all agents
        </Link>
        <div className="flex items-center gap-3 flex-wrap">
          <h1 className="text-3xl font-bold">Agent #{parsed}</h1>
          {agent && (
            <span className={`badge ${agent.active ? "badge-success" : "badge-ghost"}`}>
              {agent.active ? "active" : "inactive"}
            </span>
          )}
        </div>
        {agent?.metadataURI && <p className="opacity-70 text-sm break-all">{agent.metadataURI}</p>}
      </header>

      {isAgentLoading && !agent && <span className="loading loading-spinner loading-lg self-center" />}

      {agent && (
        <section className="grid gap-3 sm:grid-cols-3">
          {roles.map(([label, address, hint]) => (
            <div key={label} className="card bg-base-100 shadow-sm">
              <div className="card-body p-4 gap-1">
                <span className="text-xs uppercase tracking-wide opacity-60">{label}</span>
                {address ? (
                  <a
                    href={hashscanAddressUrl(address, network)}
                    target="_blank"
                    rel="noreferrer"
                    className="link link-primary font-mono text-sm"
                  >
                    {shortenAddress(address)}
                  </a>
                ) : (
                  <span className="opacity-50 text-sm">—</span>
                )}
                <span className="text-xs opacity-60">{hint}</span>
              </div>
            </div>
          ))}
        </section>
      )}

      <section className="flex flex-col gap-3">
        <div className="flex items-baseline gap-3">
          <h2 className="text-xl font-semibold">Audit trail</h2>
          {typeof actionCount === "bigint" && (
            <span className="text-sm opacity-60">
              {actionCount.toString()} action{actionCount === 1n ? "" : "s"} recorded on-chain
            </span>
          )}
        </div>
        <p className="text-sm opacity-70">
          Every receipt below was emitted by the router and read back from the mirror node. The amounts are what the
          router measured arriving, not what an adapter reported.
        </p>
        <AuditFeed
          receipts={audit.receipts}
          tokens={audit.tokens}
          chainId={targetNetwork.id}
          isLoading={audit.isLoading}
          error={audit.error}
          hasMore={audit.hasMore}
          onLoadMore={audit.loadMore}
        />
      </section>
    </div>
  );
};

export default AgentDetailPage;
