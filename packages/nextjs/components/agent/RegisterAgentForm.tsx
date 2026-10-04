"use client";

import { useState } from "react";
import { HederaAddressInput } from "@scaffold-hbar-ui/components";
import { useAccount } from "wagmi";
import { useScaffoldWriteContract } from "~~/hooks/scaffold-hbar";

/**
 * Registers an agent from the browser.
 *
 * The three roles are separate fields rather than one, because that separation is the point of the
 * registry and hiding it behind a single "create" button would teach the wrong model. The form
 * defaults all three to the connected wallet so a first agent is one click, and says plainly why
 * you would not do that in production.
 */
export const RegisterAgentForm = ({ onRegistered }: { onRegistered?: () => void }) => {
  const { address: connected } = useAccount();

  const [controllerNote, setControllerNote] = useState(false);
  const [operator, setOperator] = useState("");
  const [treasury, setTreasury] = useState("");
  const [metadataURI, setMetadataURI] = useState("");
  const [error, setError] = useState<string | null>(null);

  const { writeContractAsync, isPending } = useScaffoldWriteContract({ contractName: "AgentRegistry" });

  const effectiveOperator = operator || connected || "";
  const effectiveTreasury = treasury || connected || "";
  const allSameAccount = Boolean(connected) && effectiveOperator === connected && effectiveTreasury === connected;

  const submit = async () => {
    setError(null);
    if (!effectiveOperator || !effectiveTreasury) {
      setError("Connect a wallet, or fill in an operator and treasury.");
      return;
    }

    try {
      await writeContractAsync({
        functionName: "registerAgent",
        args: [effectiveOperator, effectiveTreasury, metadataURI || "ipfs://"],
      });
      setOperator("");
      setTreasury("");
      setMetadataURI("");
      onRegistered?.();
    } catch (cause) {
      // The wallet's own rejection message is more useful than anything invented here.
      setError((cause as Error).message.split("\n")[0]);
    }
  };

  if (!connected) {
    return (
      <div className="alert alert-info">
        <span>Connect a wallet to register an agent.</span>
      </div>
    );
  }

  return (
    <div className="card bg-base-200">
      <div className="card-body gap-4">
        <div>
          <h3 className="card-title text-lg">Register an agent</h3>
          <p className="text-sm opacity-70">
            The caller becomes the <strong>controller</strong>. Registration alone grants no spending ability — set a
            spend policy afterwards.
          </p>
        </div>

        <label className="form-control">
          <div className="label">
            <span className="label-text">Operator — the key that submits actions</span>
          </div>
          <HederaAddressInput
            value={effectiveOperator}
            onChange={setOperator}
            placeholder="0.0.n or 0x… — defaults to the connected wallet"
          />
        </label>

        <label className="form-control">
          <div className="label">
            <span className="label-text">Treasury — where the funds live</span>
          </div>
          <HederaAddressInput
            value={effectiveTreasury}
            onChange={setTreasury}
            placeholder="0.0.n or 0x… — defaults to the connected wallet"
          />
        </label>

        <label className="form-control">
          <div className="label">
            <span className="label-text">Metadata URI — what this agent claims to do</span>
          </div>
          <input
            className="input input-bordered w-full"
            value={metadataURI}
            onChange={e => setMetadataURI(e.target.value)}
            placeholder="ipfs://…"
          />
        </label>

        {allSameAccount && (
          <div className="alert alert-warning text-sm">
            <span>
              All three roles are the same account. Fine for a demo. In production the operator is a hot key that will
              eventually leak — keeping it separate from the controller is what stops a leak becoming a drained
              treasury.{" "}
              <button className="link" onClick={() => setControllerNote(v => !v)}>
                {controllerNote ? "hide" : "why?"}
              </button>
            </span>
          </div>
        )}

        {controllerNote && (
          <p className="text-sm opacity-70">
            A compromised operator can spend up to the limit the controller already set, and cannot raise that limit,
            redirect the treasury, or restart an agent the controller has stopped.
          </p>
        )}

        {error && (
          <div className="alert alert-error text-sm">
            <span>{error}</span>
          </div>
        )}

        <div className="card-actions">
          <button className="btn btn-primary" onClick={submit} disabled={isPending}>
            {isPending ? "Registering…" : "Register agent"}
          </button>
        </div>
      </div>
    </div>
  );
};
