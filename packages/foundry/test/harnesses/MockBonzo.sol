// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IBonzoLendingPool, IBonzoDataProvider } from "../../contracts/interfaces/IBonzoLendingPool.sol";
import { MockERC20 } from "./MockERC20.sol";

/// @notice Reserve registry stand-in. Unlisted reserves return the zero address, as Bonzo does.
contract MockBonzoDataProvider is IBonzoDataProvider {
    mapping(address underlying => address aToken) public aTokenOf;

    function setReserve(address underlying, address aToken) external {
        aTokenOf[underlying] = aToken;
    }

    function getReserveTokensAddresses(address asset)
        external
        view
        returns (address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress)
    {
        return (aTokenOf[asset], address(0), address(0));
    }
}

/**
 * @notice Lending pool stand-in.
 *
 * @dev Pulls the underlying via `transferFrom` on deposit and repay so the adapter's allowance
 *      handling is genuinely exercised. Mints and burns aTokens to mirror Aave's 1:1 accounting,
 *      and caps repayment at the recorded debt so the refund path is reachable.
 */
contract MockBonzoLendingPool is IBonzoLendingPool {
    MockBonzoDataProvider public immutable dataProvider;

    mapping(address account => mapping(address asset => uint256)) public debtOf;

    address public lastDepositOnBehalfOf;
    address public lastWithdrawTo;
    address public lastRepayOnBehalfOf;
    uint256 public lastRateMode;

    constructor(MockBonzoDataProvider dataProvider_) {
        dataProvider = dataProvider_;
    }

    function setDebt(address account, address asset, uint256 amount) external {
        debtOf[account][asset] = amount;
    }

    function deposit(address asset, uint256 amount, address onBehalfOf, uint16) external {
        lastDepositOnBehalfOf = onBehalfOf;
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        MockERC20(dataProvider.aTokenOf(asset)).mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        lastWithdrawTo = to;
        // Aave burns the caller's aTokens; the adapter is the caller here.
        MockERC20(dataProvider.aTokenOf(asset)).burnFrom(msg.sender, amount);
        IERC20(asset).transfer(to, amount);
        return amount;
    }

    function repay(address asset, uint256 amount, uint256 rateMode, address onBehalfOf) external returns (uint256) {
        lastRepayOnBehalfOf = onBehalfOf;
        lastRateMode = rateMode;

        uint256 debt = debtOf[onBehalfOf][asset];
        uint256 repaid = amount > debt ? debt : amount;

        IERC20(asset).transferFrom(msg.sender, address(this), repaid);
        debtOf[onBehalfOf][asset] = debt - repaid;
        return repaid;
    }
}
