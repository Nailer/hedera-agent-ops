"use client";

import { useState } from "react";
import { useAccount } from "wagmi";
import { useDeployedContractInfo, useScaffoldWriteContract } from "~~/hooks/scaffold-hbar";

/**
 * Sets a spend policy and executes a swap, from the browser.
 *
 * @dev Two things here are deliberately visible rather than hidden behind a button.
 *
 * **The policy is a separate step.** A freshly registered agent can spend nothing until its
 * controller authorises a specific token. Folding that into registration would hide the single most
 * important property of the registry — that authority is granted explicitly, per asset.
 *
 * **The approval is a separate step too.** The treasury keeps custody and grants the router an
 * allowance; the router never holds anything between actions. A UI that silently approved would
 * teach the opposite.
 *
 * Addresses come from `deployedContracts`, generated at deploy time — not hardcoded here.
 */

/** `[token(20) | fee(3) | token(20)]` — SaucerSwap V2 path encoding. */
function encodePath(tokenIn: string, fee: number, tokenOut: string): `0x${string}` {
  const feeHex = fee.toString(16).padStart(6, "0");
  return `0x${tokenIn.slice(2)}${feeHex}${tokenOut.slice(2)}`.toLowerCase() as `0x${string}`;
}

const ERC20_ABI = [
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
  },
] as const;

type Props = {
  agentId: bigint;
  /** The agent's controller, from the registry. Only they may set a policy. */
  controller?: string;
  /** The agent's operator. Only they may execute. */
  operator?: string;
};

export const ActionConsole = ({ agentId, controller, operator }: Props) => {
  const { address: connected } = useAccount();
  const { data: routerInfo } = useDeployedContractInfo({ contractName: "ActionRouter" });
  const { data: adapterInfo } = useDeployedContractInfo({ contractName: "SaucerSwapAdapter" });

  const [tokenIn, setTokenIn] = useState("");
  const [tokenOut, setTokenOut] = useState("");
  const [fee, setFee] = useState("3000");
  const [amountIn, setAmountIn] = useState("");
  const [minOut, setMinOut] = useState("0");
  const [maxPerAction, setMaxPerAction] = useState("");
  const [maxPerEpoch, setMaxPerEpoch] = useState("");
  const [status, setStatus] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const { writeContractAsync: writeRegistry, isPending: policyPending } = useScaffoldWriteContract({
    contractName: "AgentRegistry",
  });
  const { writeContractAsync: writeRouter, isPending: swapPending } = useScaffoldWriteContract({
    contractName: "ActionRouter",
  });

  const isController = Boolean(connected && controller && connected.toLowerCase() === controller.toLowerCase());
  const isOperator = Boolean(connected && operator && connected.toLowerCase() === operator.toLowerCase());

  const guard = (fn: () => Promise<void>) => async () => {
    setError(null);
    setStatus(null);
    try {
      await fn();
    } catch (cause) {
      setError((cause as Error).message.split("\n")[0]);
    }
  };

  const setPolicy = guard(async () => {
    if (!tokenIn || !maxPerAction || !maxPerEpoch) throw new Error("Token, per-action and per-epoch are all required.");
    await writeRegistry({
      functionName: "setSpendPolicy",
      args: [agentId, tokenIn, BigInt(maxPerAction), BigInt(maxPerEpoch), 86400n],
    });
    setStatus("Spend policy set. The agent may now spend that token, up to those limits.");
  });

  const approve = guard(async () => {
    if (!tokenIn || !routerInfo?.address) throw new Error("Input token required.");
    const { writeContract } = await import("@wagmi/core");
    const { wagmiConfig } = await import("~~/services/web3/wagmiConfig");
    await writeContract(wagmiConfig, {
      abi: ERC20_ABI,
      address: tokenIn as `0x${string}`,
      functionName: "approve",
      args: [routerInfo.address as `0x${string}`, BigInt(maxPerEpoch || amountIn || "0")],
    });
    setStatus("Router approved. Custody stays with the treasury — this only permits a pull during one call.");
  });

  const execute = guard(async () => {
    if (!adapterInfo?.address) throw new Error("SaucerSwap adapter is not deployed on this network.");
    if (!tokenIn || !tokenOut || !amountIn) throw new Error("Input token, output token and amount are all required.");

    const path = encodePath(tokenIn, Number(fee), tokenOut);
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 900);

    const { encodeAbiParameters } = await import("viem");
    const protocolData = encodeAbiParameters(
      [
        { name: "path", type: "bytes" },
        { name: "deadline", type: "uint256" },
      ],
      [path, deadline],
    );

    await writeRouter({
      functionName: "executeAction",
      args: [
        agentId,
        adapterInfo.address,
        {
          kind: 0, // Swap
          assetIn: tokenIn,
          amountIn: BigInt(amountIn),
          assetOut: tokenOut,
          minAmountOut: BigInt(minOut || "0"),
          protocolData,
        },
      ],
    });
    setStatus("Action submitted. The receipt appears in the audit trail once the mirror node catches up.");
  });

  if (!connected) {
    return (
      <div className="alert alert-info">
        <span>Connect a wallet to set a policy or execute an action.</span>
      </div>
    );
  }

  return (
    <div className="card bg-base-200">
      <div className="card-body gap-4">
        <div>
          <h3 className="card-title text-lg">Action console</h3>
          <p className="text-sm opacity-70">
            Amounts are in the token&apos;s smallest unit — SAUCE has 6 decimals, WHBAR 8.
          </p>
        </div>

        <div className="grid gap-3 md:grid-cols-2">
          <label className="form-control">
            <div className="label">
              <span className="label-text">Input token</span>
            </div>
            <input
              className="input input-bordered input-sm w-full font-mono text-xs"
              value={tokenIn}
              onChange={e => setTokenIn(e.target.value)}
              placeholder="0x…3aD2 (WHBAR)"
            />
          </label>
          <label className="form-control">
            <div className="label">
              <span className="label-text">Output token</span>
            </div>
            <input
              className="input input-bordered input-sm w-full font-mono text-xs"
              value={tokenOut}
              onChange={e => setTokenOut(e.target.value)}
              placeholder="0x…120f46 (SAUCE)"
            />
          </label>
        </div>

        <div className="divider my-0 text-xs">1 — controller sets the limits</div>

        <div className="grid gap-3 md:grid-cols-3">
          <label className="form-control">
            <div className="label">
              <span className="label-text text-xs">Max per action</span>
            </div>
            <input
              className="input input-bordered input-sm"
              value={maxPerAction}
              onChange={e => setMaxPerAction(e.target.value)}
              placeholder="500000000"
            />
          </label>
          <label className="form-control">
            <div className="label">
              <span className="label-text text-xs">Max per epoch</span>
            </div>
            <input
              className="input input-bordered input-sm"
              value={maxPerEpoch}
              onChange={e => setMaxPerEpoch(e.target.value)}
              placeholder="2000000000"
            />
          </label>
          <div className="flex items-end gap-2">
            <button className="btn btn-sm btn-outline" onClick={setPolicy} disabled={policyPending || !isController}>
              {policyPending ? "Setting…" : "Set policy"}
            </button>
            <button className="btn btn-sm btn-outline" onClick={approve}>
              Approve router
            </button>
          </div>
        </div>

        {!isController && controller && (
          <p className="text-xs opacity-60">
            Only the controller ({controller.slice(0, 10)}…) may set a policy — enforced by the contract, not by this
            form being disabled.
          </p>
        )}

        <div className="divider my-0 text-xs">2 — operator acts</div>

        <div className="grid gap-3 md:grid-cols-3">
          <label className="form-control">
            <div className="label">
              <span className="label-text text-xs">Amount in</span>
            </div>
            <input
              className="input input-bordered input-sm"
              value={amountIn}
              onChange={e => setAmountIn(e.target.value)}
              placeholder="100000000"
            />
          </label>
          <label className="form-control">
            <div className="label">
              <span className="label-text text-xs">Min out (slippage floor)</span>
            </div>
            <input className="input input-bordered input-sm" value={minOut} onChange={e => setMinOut(e.target.value)} />
          </label>
          <label className="form-control">
            <div className="label">
              <span className="label-text text-xs">Pool fee tier</span>
            </div>
            <select className="select select-bordered select-sm" value={fee} onChange={e => setFee(e.target.value)}>
              <option value="500">500</option>
              <option value="1500">1500</option>
              <option value="3000">3000</option>
              <option value="10000">10000</option>
            </select>
          </label>
        </div>

        {!isOperator && operator && (
          <p className="text-xs opacity-60">
            Only the operator ({operator.slice(0, 10)}…) may execute. The router checks this on chain.
          </p>
        )}

        {status && (
          <div className="alert alert-success text-sm">
            <span>{status}</span>
          </div>
        )}
        {error && (
          <div className="alert alert-error text-sm">
            <span>{error}</span>
          </div>
        )}

        <div className="card-actions">
          <button className="btn btn-primary" onClick={execute} disabled={swapPending || !isOperator}>
            {swapPending ? "Executing…" : "Execute swap"}
          </button>
        </div>
      </div>
    </div>
  );
};
