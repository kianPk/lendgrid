// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SimplePriceOracle} from "./Oracle.sol";

/// @title LendingPool
/// @notice Overcollateralized single-market lending pool:
///         deposit collateral → borrow debt asset → repay / withdraw / liquidate.
/// @dev Lab-grade protocol surface (oracle, HF, liquidation bonus) — not a mainnet fork.
contract LendingPool is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    IERC20 public immutable collateral;
    IERC20 public immutable debtAsset;
    SimplePriceOracle public immutable oracle;

    uint8 public immutable collateralDecimals;
    uint8 public immutable debtDecimals;

    /// @dev LTV / liquidation threshold in bps (e.g. 7500 = 75%).
    uint16 public ltvBps;
    uint16 public liquidationThresholdBps;
    uint16 public liquidationBonusBps; // e.g. 500 = +5% bonus to liquidator
    uint16 public constant BPS = 10_000;

    mapping(address => uint256) public collateralBalance;
    mapping(address => uint256) public debtBalance;
    mapping(address => uint256) public userBorrowIndex;

    uint256 public totalCollateral;
    uint256 public totalDebt;

    /// @dev Liquidity index (1e18). Grows as interest accrues.
    uint256 public borrowIndex = 1e18;
    uint256 public lastAccrual;
    /// @dev Base + slope APR in bps (utilization kink model, simplified).
    uint16 public baseRateBps = 200; // 2%
    uint16 public slope1Bps = 800; // +8% to kink
    uint16 public slope2Bps = 4000; // steep after kink
    uint16 public kinkBps = 8000; // 80% utilization

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event Liquidated(
        address indexed user, address indexed liquidator, uint256 repayAmount, uint256 seizedCollateral
    );
    event ParamsUpdated(uint16 ltvBps, uint16 liqThresholdBps, uint16 liqBonusBps);
    event Accrued(uint256 borrowIndex, uint256 timestamp, uint256 borrowAprBps);

    error InvalidParams();
    error InsufficientCollateral();
    error HealthyPosition();
    error ZeroAmount();
    error Undercollateralized();

    constructor(
        address collateral_,
        address debtAsset_,
        address oracle_,
        address admin_,
        uint16 ltvBps_,
        uint16 liquidationThresholdBps_,
        uint16 liquidationBonusBps_
    ) {
        if (liquidationThresholdBps_ < ltvBps_ || liquidationThresholdBps_ >= BPS) revert InvalidParams();
        if (liquidationBonusBps_ > 2000) revert InvalidParams();

        collateral = IERC20(collateral_);
        debtAsset = IERC20(debtAsset_);
        oracle = SimplePriceOracle(oracle_);
        collateralDecimals = IERC20Metadata(collateral_).decimals();
        debtDecimals = IERC20Metadata(debtAsset_).decimals();

        ltvBps = ltvBps_;
        liquidationThresholdBps = liquidationThresholdBps_;
        liquidationBonusBps = liquidationBonusBps_;
        lastAccrual = block.timestamp;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(GUARDIAN_ROLE, admin_);
    }

    // ─── Interest ────────────────────────────────────────────────────────────

    function cash() public view returns (uint256) {
        return debtAsset.balanceOf(address(this));
    }

    function utilizationBps() public view returns (uint256) {
        uint256 debt = totalDebt;
        uint256 deposits = debt + cash();
        if (deposits == 0) return 0;
        return (debt * BPS) / deposits;
    }

    /// @notice Instantaneous borrow APR in bps from a two-slope utilization curve.
    function borrowAprBps() public view returns (uint256) {
        uint256 u = utilizationBps();
        if (u <= kinkBps) {
            return baseRateBps + (slope1Bps * u) / kinkBps;
        }
        uint256 excess = u - kinkBps;
        return baseRateBps + slope1Bps + (slope2Bps * excess) / (BPS - kinkBps);
    }

    function accrue() public {
        uint256 dt = block.timestamp - lastAccrual;
        if (dt == 0 || totalDebt == 0) {
            lastAccrual = block.timestamp;
            return;
        }
        uint256 apr = borrowAprBps();
        // index *= 1 + apr * dt / year
        uint256 interestFactor = (apr * dt * 1e18) / (uint256(BPS) * 365 days);
        borrowIndex += (borrowIndex * interestFactor) / 1e18;
        // Grow aggregate debt with the same factor (principal-only accounting for lab)
        totalDebt += (totalDebt * interestFactor) / 1e18;
        lastAccrual = block.timestamp;
        emit Accrued(borrowIndex, block.timestamp, apr);
    }

    function _syncUser(address user) internal {
        uint256 idx = userBorrowIndex[user];
        if (debtBalance[user] == 0) {
            userBorrowIndex[user] = borrowIndex;
            return;
        }
        if (idx == 0 || idx == borrowIndex) {
            userBorrowIndex[user] = borrowIndex;
            return;
        }
        debtBalance[user] = (debtBalance[user] * borrowIndex) / idx;
        userBorrowIndex[user] = borrowIndex;
    }

    // ─── Valuation ───────────────────────────────────────────────────────────

    function _usd(address token, uint256 amount, uint8 decimals_) internal view returns (uint256) {
        uint256 price = oracle.getPrice(token); // 1e8
        // amount * price / 10^decimals → USD with 8 decimals
        return (amount * price) / (10 ** decimals_);
    }

    function collateralUsd(address user) public view returns (uint256) {
        return _usd(address(collateral), collateralBalance[user], collateralDecimals);
    }

    function debtUsd(address user) public view returns (uint256) {
        return _usd(address(debtAsset), debtBalance[user], debtDecimals);
    }

    /// @notice Health factor scaled by 1e18. Max uint if no debt.
    function healthFactor(address user) public view returns (uint256) {
        uint256 debt = debtUsd(user);
        if (debt == 0) return type(uint256).max;
        uint256 thresh = (collateralUsd(user) * liquidationThresholdBps) / BPS;
        return (thresh * 1e18) / debt;
    }

    function maxBorrow(address user) public view returns (uint256) {
        uint256 maxDebtUsd = (collateralUsd(user) * ltvBps) / BPS;
        uint256 current = debtUsd(user);
        if (maxDebtUsd <= current) return 0;
        uint256 roomUsd = maxDebtUsd - current;
        uint256 price = oracle.getPrice(address(debtAsset));
        return (roomUsd * (10 ** debtDecimals)) / price;
    }

    // ─── User actions ────────────────────────────────────────────────────────

    function deposit(uint256 amount) external whenNotPaused nonReentrant {
        accrue();
        if (amount == 0) revert ZeroAmount();
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        collateralBalance[msg.sender] += amount;
        totalCollateral += amount;
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external whenNotPaused nonReentrant {
        accrue();
        _syncUser(msg.sender);
        if (amount == 0) revert ZeroAmount();
        collateralBalance[msg.sender] -= amount;
        totalCollateral -= amount;
        if (healthFactor(msg.sender) < 1e18) revert Undercollateralized();
        collateral.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function borrow(uint256 amount) external whenNotPaused nonReentrant {
        accrue();
        _syncUser(msg.sender);
        if (amount == 0) revert ZeroAmount();
        debtBalance[msg.sender] += amount;
        totalDebt += amount;
        userBorrowIndex[msg.sender] = borrowIndex;
        if (debtUsd(msg.sender) > (collateralUsd(msg.sender) * ltvBps) / BPS) {
            revert InsufficientCollateral();
        }
        debtAsset.safeTransfer(msg.sender, amount);
        emit Borrowed(msg.sender, amount);
    }

    function repay(uint256 amount) external whenNotPaused nonReentrant {
        accrue();
        _syncUser(msg.sender);
        if (amount == 0) revert ZeroAmount();
        uint256 debt = debtBalance[msg.sender];
        uint256 pay = amount > debt ? debt : amount;
        debtAsset.safeTransferFrom(msg.sender, address(this), pay);
        debtBalance[msg.sender] = debt - pay;
        totalDebt -= pay;
        emit Repaid(msg.sender, pay);
    }

    /// @notice Liquidate unhealthy account: repay debt, seize collateral + bonus.
    function liquidate(address user, uint256 repayAmount) external whenNotPaused nonReentrant {
        accrue();
        _syncUser(user);
        if (repayAmount == 0) revert ZeroAmount();
        if (healthFactor(user) >= 1e18) revert HealthyPosition();

        uint256 debt = debtBalance[user];
        uint256 pay = repayAmount > debt ? debt : repayAmount;

        uint256 payUsd = _usd(address(debtAsset), pay, debtDecimals);
        uint256 collPrice = oracle.getPrice(address(collateral));
        // collateral to seize = repayUsd * (1 + bonus) / collPrice
        uint256 seizeUsd = (payUsd * (BPS + liquidationBonusBps)) / BPS;
        uint256 seize = (seizeUsd * (10 ** collateralDecimals)) / collPrice;
        if (seize > collateralBalance[user]) seize = collateralBalance[user];

        debtAsset.safeTransferFrom(msg.sender, address(this), pay);
        debtBalance[user] -= pay;
        totalDebt -= pay;

        collateralBalance[user] -= seize;
        totalCollateral -= seize;
        collateral.safeTransfer(msg.sender, seize);

        emit Liquidated(user, msg.sender, pay, seize);
    }

    function seedLiquidity(uint256 amount) external {
        debtAsset.safeTransferFrom(msg.sender, address(this), amount);
    }

    function setParams(uint16 ltvBps_, uint16 liqThresholdBps_, uint16 liqBonusBps_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (liqThresholdBps_ < ltvBps_ || liqThresholdBps_ >= BPS) revert InvalidParams();
        if (liqBonusBps_ > 2000) revert InvalidParams();
        ltvBps = ltvBps_;
        liquidationThresholdBps = liqThresholdBps_;
        liquidationBonusBps = liqBonusBps_;
        emit ParamsUpdated(ltvBps_, liqThresholdBps_, liqBonusBps_);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
