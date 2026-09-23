import { clearTokenMetadataCache, fetchTokenMetadata, fetchTokenMetadataMany } from "./tokenMetadata";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { MirrorNodeError } from "~~/services/audit/mirrorNode";

const SAUCE_EVM = "0x0000000000000000000000000000000000120f46";

function respond(body: unknown, ok = true, status = 200) {
  return vi.fn().mockResolvedValue({ ok, status, json: async () => body } as unknown as Response);
}

const SAUCE_RESPONSE = {
  token_id: "0.0.1183558",
  symbol: "SAUCE",
  name: "Sauce",
  // A string, exactly as the live API returns it.
  decimals: "6",
  type: "FUNGIBLE_COMMON",
};

beforeEach(() => {
  clearTokenMetadataCache();
});

describe("fetchTokenMetadata", () => {
  /**
   * The mirror node returns `"decimals": "6"`, a string. Left unparsed it flows into `10 ** decimals`
   * as NaN and every amount in the audit feed renders as garbage without erroring anywhere.
   */
  it("coerces the string decimals the API returns into a number", async () => {
    const token = await fetchTokenMetadata(SAUCE_EVM, { fetchImpl: respond(SAUCE_RESPONSE) });

    expect(token.decimals).toBe(6);
    expect(typeof token.decimals).toBe("number");
  });

  it("returns symbol, name and id", async () => {
    const token = await fetchTokenMetadata(SAUCE_EVM, { fetchImpl: respond(SAUCE_RESPONSE) });

    expect(token.symbol).toBe("SAUCE");
    expect(token.name).toBe("Sauce");
    expect(token.tokenId).toBe("0.0.1183558");
  });

  it("queries the token endpoint with the identifier as given", async () => {
    const fetchImpl = respond(SAUCE_RESPONSE);
    await fetchTokenMetadata("0.0.1183558", { fetchImpl });

    expect(fetchImpl).toHaveBeenCalledWith("https://testnet.mirrornode.hedera.com/api/v1/tokens/0.0.1183558");
  });

  /// Token metadata is immutable, so a second request for the same token is waste.
  it("caches across calls", async () => {
    const fetchImpl = respond(SAUCE_RESPONSE);

    await fetchTokenMetadata(SAUCE_EVM, { fetchImpl });
    await fetchTokenMetadata(SAUCE_EVM, { fetchImpl });

    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it("treats differently-cased addresses as the same token", async () => {
    const fetchImpl = respond(SAUCE_RESPONSE);

    await fetchTokenMetadata(SAUCE_EVM.toLowerCase(), { fetchImpl });
    await fetchTokenMetadata(SAUCE_EVM.toUpperCase(), { fetchImpl });

    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it("raises a typed error carrying the status when the token is unknown", async () => {
    await expect(fetchTokenMetadata(SAUCE_EVM, { fetchImpl: respond({}, false, 404) })).rejects.toMatchObject({
      name: "MirrorNodeError",
      status: 404,
    });
  });

  it("wraps a network failure", async () => {
    const fetchImpl = vi.fn().mockRejectedValue(new Error("connection reset"));
    await expect(fetchTokenMetadata(SAUCE_EVM, { fetchImpl })).rejects.toBeInstanceOf(MirrorNodeError);
  });

  /// Rendering amounts against NaN decimals would misreport every number on the page.
  it("rejects unusable decimals rather than rendering against NaN", async () => {
    const fetchImpl = respond({ ...SAUCE_RESPONSE, decimals: "not-a-number" });
    await expect(fetchTokenMetadata(SAUCE_EVM, { fetchImpl })).rejects.toBeInstanceOf(MirrorNodeError);
  });

  it("falls back to placeholders for a sparse response", async () => {
    const token = await fetchTokenMetadata(SAUCE_EVM, { fetchImpl: respond({}) });

    expect(token.symbol).toBe("?");
    expect(token.decimals).toBe(0);
  });
});

describe("fetchTokenMetadataMany", () => {
  it("de-duplicates addresses before requesting", async () => {
    const fetchImpl = respond(SAUCE_RESPONSE);

    await fetchTokenMetadataMany([SAUCE_EVM, SAUCE_EVM.toUpperCase(), SAUCE_EVM], { fetchImpl });

    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it("keys the result by lowercased address", async () => {
    const resolved = await fetchTokenMetadataMany([SAUCE_EVM.toUpperCase()], { fetchImpl: respond(SAUCE_RESPONSE) });

    expect(resolved.get(SAUCE_EVM.toLowerCase())?.symbol).toBe("SAUCE");
  });

  /// One unresolvable token must not blank the whole feed.
  it("omits failures instead of rejecting", async () => {
    const fetchImpl = vi
      .fn()
      .mockImplementation((url: string) =>
        url.endsWith("0xbad")
          ? Promise.resolve({ ok: false, status: 404, json: async () => ({}) } as unknown as Response)
          : Promise.resolve({ ok: true, status: 200, json: async () => SAUCE_RESPONSE } as unknown as Response),
      );

    const resolved = await fetchTokenMetadataMany([SAUCE_EVM, "0xbad"], { fetchImpl });

    expect(resolved.size).toBe(1);
    expect(resolved.get(SAUCE_EVM.toLowerCase())?.symbol).toBe("SAUCE");
    expect(resolved.has("0xbad")).toBe(false);
  });

  it("returns an empty map for no addresses", async () => {
    const resolved = await fetchTokenMetadataMany([], { fetchImpl: respond(SAUCE_RESPONSE) });
    expect(resolved.size).toBe(0);
  });
});
