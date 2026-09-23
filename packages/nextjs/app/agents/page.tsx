"use client";

import Link from "next/link";
import type { NextPage } from "next";
import { AuditFeed } from "~~/components/agent/AuditFeed";
import { useDeployedContractInfo, useScaffoldReadContract, useTargetNetwork } from "~~/hooks/scaffold-hbar";
import { useAgentAuditTrail } from "~~/hooks/useAgentAuditTrail";
import { hashscanAddressUrl, networkForChainId } from "~~/services/audit/format";

/**
 * The registry, and everything every agent has done.
 *
 * The count comes from the contract; the activity comes from the mirror node. Neither reads from a
 * database we control, which is the whole claim — anyone can check both from the chain alone.
 */
const AgentsPage: NextPage = () => {
  const { targetNetwork } = useTargetNetwork();
  const { data: routerInfo } = useDeployedContractInfo({ contractName: "ActionRouter" });
  const { data: registryInfo } = useDeployedContractInfo({ contractName: "AgentRegistry" });

  const { data: agentCount } = useScaffoldReadContract({
    contractName: "AgentRegistry",
    functionName: "agentCount",
  });

  const audit = useAgentAuditTrail({ routerAddress: routerInfo?.address });
  const network = networkForChainId(targetNetwork.id);

  const count = typeof agentCount === "bigint" ? Number(agentCount) : 0;
  // Ids run from 1 to agentCount inclusive; zero is never a valid agent.
  const agentIds = Array.from({ length: count }, (_, i) => i + 1);

  return (
    <div className="flex flex-col grow px-5 py-10 max-w-5xl mx-auto w-full gap-10">
      <header className="flex flex-col gap-2">
        <h1 className="text-3xl font-bold">Agents</h1>
        <p className="opacity-70">
          Registered agents and the actions they have taken, read from the registry contract and the Hedera mirror node.
        </p>
        {registryInfo?.address && (
          <a
            href={hashscanAddressUrl(registryInfo.address, network)}
            target="_blank"
            rel="noreferrer"
            className="link link-primary text-sm w-fit"
          >
            registry on HashScan
          </a>
        )}
      </header>

      <section className="flex flex-col gap-3">
        <h2 className="text-xl font-semibold">
          Registered {count > 0 && <span className="badge badge-neutral align-middle">{count}</span>}
        </h2>

        {count === 0 ? (
          <div className="text-sm opacity-70">
            No agents registered yet. Call <code className="text-xs">registerAgent</code> on the registry — the Debug
            Contracts page is the quickest way.
          </div>
        ) : (
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            {agentIds.map(id => (
              <Link key={id} href={`/agents/${id}`} className="card bg-base-100 shadow-sm hover:shadow-md transition">
                <div className="card-body p-4">
                  <span className="text-xs opacity-60">agent</span>
                  <span className="text-2xl font-bold">#{id}</span>
                </div>
              </Link>
            ))}
          </div>
        )}
      </section>

      <section className="flex flex-col gap-3">
        <h2 className="text-xl font-semibold">All activity</h2>
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

export default AgentsPage;
