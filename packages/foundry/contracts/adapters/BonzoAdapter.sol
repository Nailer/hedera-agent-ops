// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IAgentAction } from "../interfaces/IAgentAction.sol";
import { IBonzoLendingPool, IBonzoDataProvider } from "../interfaces/IBonzoLendingPool.sol";
import { IHederaTokenService } from "../interfaces/IHederaTokenService.sol";

/**
 * @title BonzoAdapter
 * @notice Translates `IAgentAction` lending operations into Bonzo (Aave v2) calls.
 *
 * @dev **Supported: `Supply`, `Withdraw`, `Repay`. Not `Borrow`.**
 *
 * The omission is deliberate, not an oversight. `ActionRouter` pulls `amountIn` of `assetIn` from
 * the treasury *before* calling an adapter, because that is what makes the custody window one call
 * long and the spend budget enforceable. Borrowing spends nothing — that is its entire nature — so
 * routing it through that flow would mean pulling tokens the treasury does not have and, by
 * definition, would not need to borrow if it did. Supporting it properly needs a second entry point
 * on the router with its own authorisation model, since the risk being taken is debt rather than
 * spend. `supportsAction` returns false for `Borrow`, so the router rejects it up front with a
 * named error rather than failing somewhere inside Bonzo.
 *
 * **Declared assets are checked against the protocol, never trusted.** This is the same class of
 * check as path validation in the SaucerSwap adapter, and it exists for the same reason: the
 * registry charges an agent's budget against `request.assetIn`, and the router measures delivery in
 * `request.assetOut`, but neither inspects whether those two are actually related. The aToken for a
 * reserve is resolved from Bonzo's own data provider and compared with what the caller declared, so
 * a request cannot claim to supply one asset while moving another.
 *
 * **`protocolData` is `abi.encode(uint256 interestRateMode)`**, used only by `Repay`; 1 is stable
 * and 2 is variable. Empty data defaults to variable, which is the mode most Bonzo reserves offer —
 * SAUCE on testnet has `stableBorrowRateEnabled = false`.
 */
contract BonzoAdapter is IAgentAction, Ownable {
    using SafeERC20 for IERC20;

    error BonzoAdapter__ZeroAddress();
    error BonzoAdapter__ReserveNotListed(address asset);
    error BonzoAdapter__AssetOutIsNotTheAToken(address declared, address expected);
    error BonzoAdapter__AssetInIsNotTheAToken(address declared, address expected);
    error BonzoAdapter__RepayAssetsMustMatch(address assetIn, address assetOut);
    error BonzoAdapter__InvalidRateMode(uint256 rateMode);
    error BonzoAdapter__AssociationFailed(address token, int64 responseCode);

    event TokenAssociated(address indexed token);

    address private constant HTS = 0x0000000000000000000000000000000000000167;
    int64 private constant HTS_SUCCESS = 22;
    int64 private constant HTS_ALREADY_ASSOCIATED = 194;

    uint256 private constant RATE_MODE_STABLE = 1;
    uint256 private constant RATE_MODE_VARIABLE = 2;
    uint16 private constant NO_REFERRAL = 0;

    IBonzoLendingPool public immutable lendingPool;
    IBonzoDataProvider public immutable dataProvider;

    constructor(address initialOwner, address lendingPoolAddress, address dataProviderAddress) Ownable(initialOwner) {
        if (lendingPoolAddress == address(0) || dataProviderAddress == address(0)) {
            revert BonzoAdapter__ZeroAddress();
        }
        lendingPool = IBonzoLendingPool(lendingPoolAddress);
        dataProvider = IBonzoDataProvider(dataProviderAddress);
    }

    /// @inheritdoc IAgentAction
    function protocolId() external pure returns (bytes32) {
        return bytes32("bonzo-v1");
    }

    /// @inheritdoc IAgentAction
    function supportsAction(ActionKind kind) external pure returns (bool) {
        return kind == ActionKind.Supply || kind == ActionKind.Withdraw || kind == ActionKind.Repay;
    }

    /**
     * @notice Associate this adapter with an HTS token so it can hold and move it.
     * @dev Needed for both underlyings and aTokens — an aToken is itself an HTS token on Hedera.
     *      Idempotent: an already-associated token returns 194 and is treated as success.
     */
    function associate(address token) external onlyOwner {
        if (token == address(0)) revert BonzoAdapter__ZeroAddress();
        int64 responseCode = IHederaTokenService(HTS).associateToken(address(this), token);
        if (responseCode != HTS_SUCCESS && responseCode != HTS_ALREADY_ASSOCIATED) {
            revert BonzoAdapter__AssociationFailed(token, responseCode);
        }
        emit TokenAssociated(token);
    }

    /// @inheritdoc IAgentAction
    function execute(ActionRequest calldata request, address onBehalfOf)
        external
        payable
        returns (ActionResult memory)
    {
        if (request.kind == ActionKind.Supply) return _supply(request);
        if (request.kind == ActionKind.Withdraw) return _withdraw(request);
        if (request.kind == ActionKind.Repay) return _repay(request, onBehalfOf);
        revert IAgentAction__UnsupportedAction(request.kind);
    }

    /**
     * @dev Supply the underlying and take delivery of aTokens.
     *      aTokens are minted directly to `msg.sender` (the router), which is both what the
     *      `IAgentAction` contract requires and what lets the router measure the position it gained
     *      without a second transfer needing its own association.
     */
    function _supply(ActionRequest calldata request) private returns (ActionResult memory) {
        address aToken = _aTokenFor(request.assetIn);
        if (request.assetOut != aToken) {
            revert BonzoAdapter__AssetOutIsNotTheAToken(request.assetOut, aToken);
        }

        IERC20(request.assetIn).forceApprove(address(lendingPool), request.amountIn);
        lendingPool.deposit(request.assetIn, request.amountIn, msg.sender, NO_REFERRAL);
        IERC20(request.assetIn).forceApprove(address(lendingPool), 0);

        // aTokens mint 1:1 against the supplied amount at deposit time. The router measures the
        // real delta regardless, so this figure is reported rather than relied upon.
        return ActionResult({
            assetOut: request.assetOut, amountOut: request.amountIn, protocolRef: bytes32(uint256(uint160(aToken)))
        });
    }

    /**
     * @dev Burn aTokens held by this adapter and send the underlying to the router.
     *      The router transferred the aTokens in before this call, and Bonzo burns from
     *      `msg.sender` — which is this adapter, not the treasury.
     */
    function _withdraw(ActionRequest calldata request) private returns (ActionResult memory) {
        address aToken = _aTokenFor(request.assetOut);
        if (request.assetIn != aToken) {
            revert BonzoAdapter__AssetInIsNotTheAToken(request.assetIn, aToken);
        }

        uint256 withdrawn = lendingPool.withdraw(request.assetOut, request.amountIn, msg.sender);

        return ActionResult({
            assetOut: request.assetOut, amountOut: withdrawn, protocolRef: bytes32(uint256(uint160(aToken)))
        });
    }

    /**
     * @dev Repay the agent's debt. Bonzo caps repayment at the outstanding balance, so any excess
     *      is returned to the router — which is why `assetIn` and `assetOut` are the same token
     *      here, and why the router's same-asset accounting path exists.
     * @param onBehalfOf The agent's treasury: whose debt is being cleared.
     */
    function _repay(ActionRequest calldata request, address onBehalfOf) private returns (ActionResult memory) {
        if (request.assetIn != request.assetOut) {
            revert BonzoAdapter__RepayAssetsMustMatch(request.assetIn, request.assetOut);
        }
        // Confirms the reserve is listed before approving anything against it.
        address aToken = _aTokenFor(request.assetIn);

        uint256 rateMode = _rateModeFrom(request.protocolData);

        IERC20(request.assetIn).forceApprove(address(lendingPool), request.amountIn);
        uint256 repaid = lendingPool.repay(request.assetIn, request.amountIn, rateMode, onBehalfOf);
        IERC20(request.assetIn).forceApprove(address(lendingPool), 0);

        uint256 refund = request.amountIn - repaid;
        if (refund > 0) {
            IERC20(request.assetIn).safeTransfer(msg.sender, refund);
        }

        return
            ActionResult({
                assetOut: request.assetOut, amountOut: refund, protocolRef: bytes32(uint256(uint160(aToken)))
            });
    }

    /// @dev Resolves the aToken from Bonzo itself. A zero address means the reserve is not listed.
    function _aTokenFor(address asset) private view returns (address aToken) {
        (aToken,,) = dataProvider.getReserveTokensAddresses(asset);
        if (aToken == address(0)) revert BonzoAdapter__ReserveNotListed(asset);
    }

    /// @dev Empty `protocolData` defaults to variable, the mode most reserves offer.
    function _rateModeFrom(bytes calldata protocolData) private pure returns (uint256 rateMode) {
        if (protocolData.length == 0) return RATE_MODE_VARIABLE;
        rateMode = abi.decode(protocolData, (uint256));
        if (rateMode != RATE_MODE_STABLE && rateMode != RATE_MODE_VARIABLE) {
            revert BonzoAdapter__InvalidRateMode(rateMode);
        }
    }
}
