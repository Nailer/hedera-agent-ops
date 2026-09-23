import { DEFAULT_MIRROR_NODE_URL, MirrorNodeError } from "~~/services/audit/mirrorNode";

/**
 * Resolves an HTS token's symbol and decimals from the mirror node.
 *
 * @dev Token metadata is deliberately *not* hardcoded anywhere in the frontend. `HelperConfig` is
 * the single place a protocol address is written, and duplicating a token list here would create a
 * second one that drifts. Asking the network also means a token the template has never heard of
 * still renders correctly.
 *
 * Two details the API imposes:
 *
 * **`decimals` arrives as a string.** `{"decimals": "6"}`, not `6`. Using it unparsed makes
 * `10 ** decimals` produce `NaN` and every amount renders as garbage, silently.
 *
 * **The endpoint accepts either form of id.** An EVM address (`0x…120f46`) and a Hedera id
 * (`0.0.1183558`) both resolve to the same token, so receipts can be rendered without converting
 * between the two address shapes first.
 */

export type TokenMetadata = {
  tokenId: string;
  symbol: string;
  name: string;
  decimals: number;
};

type MirrorNodeTokenResponse = {
  token_id?: string;
  symbol?: string;
  name?: string;
  /** A string in the API response, not a number. */
  decimals?: string | number;
};

/**
 * Process-lifetime cache. Token metadata is immutable for a given token, so there is nothing to
 * invalidate, and an audit feed asks for the same handful of tokens on every row.
 */
const cache = new Map<string, TokenMetadata>();

/** Exposed for tests; not part of the normal surface. */
export function clearTokenMetadataCache(): void {
  cache.clear();
}

export type FetchTokenMetadataOptions = {
  mirrorNodeUrl?: string;
  fetchImpl?: typeof fetch;
};

export async function fetchTokenMetadata(
  tokenAddressOrId: string,
  options: FetchTokenMetadataOptions = {},
): Promise<TokenMetadata> {
  const key = tokenAddressOrId.toLowerCase();
  const cached = cache.get(key);
  if (cached) return cached;

  const base = (options.mirrorNodeUrl ?? DEFAULT_MIRROR_NODE_URL).replace(/\/+$/, "");
  const doFetch = options.fetchImpl ?? fetch;

  let response: Response;
  try {
    response = await doFetch(`${base}/api/v1/tokens/${tokenAddressOrId}`);
  } catch (cause) {
    throw new MirrorNodeError(`Token metadata request failed: ${(cause as Error).message}`);
  }

  if (!response.ok) {
    throw new MirrorNodeError(`Mirror node returned ${response.status} for token ${tokenAddressOrId}`, response.status);
  }

  const body = (await response.json()) as MirrorNodeTokenResponse;

  const metadata: TokenMetadata = {
    tokenId: body.token_id ?? tokenAddressOrId,
    symbol: body.symbol ?? "?",
    name: body.name ?? "Unknown token",
    // Number() on a string is the whole point here — see the note above.
    decimals: Number(body.decimals ?? 0),
  };

  if (!Number.isFinite(metadata.decimals)) {
    throw new MirrorNodeError(`Token ${tokenAddressOrId} reported unusable decimals: ${String(body.decimals)}`);
  }

  cache.set(key, metadata);
  return metadata;
}

/**
 * Resolves several tokens at once, de-duplicated.
 *
 * @returns A map keyed by the lowercased input, with failures omitted rather than thrown — one
 *          unresolvable token should not blank an entire audit feed.
 */
export async function fetchTokenMetadataMany(
  addresses: readonly string[],
  options: FetchTokenMetadataOptions = {},
): Promise<Map<string, TokenMetadata>> {
  const unique = [...new Set(addresses.map(a => a.toLowerCase()))];
  const resolved = new Map<string, TokenMetadata>();

  await Promise.all(
    unique.map(async address => {
      try {
        resolved.set(address, await fetchTokenMetadata(address, options));
      } catch {
        // Deliberately swallowed: a token that will not resolve renders as its raw address.
      }
    }),
  );

  return resolved;
}
