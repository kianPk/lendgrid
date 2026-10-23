// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title SimplePriceOracle
/// @notice Permissioned price feed (8 decimals) for lab / demo markets.
contract SimplePriceOracle is AccessControl {
    bytes32 public constant FEEDER_ROLE = keccak256("FEEDER_ROLE");

    mapping(address => uint256) public priceE8; // USD price with 8 decimals
    mapping(address => uint256) public updatedAt;

    event PriceUpdated(address indexed asset, uint256 priceE8, uint256 timestamp);

    error ZeroPrice();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FEEDER_ROLE, admin);
    }

    function setPrice(address asset, uint256 price) external onlyRole(FEEDER_ROLE) {
        if (price == 0) revert ZeroPrice();
        priceE8[asset] = price;
        updatedAt[asset] = block.timestamp;
        emit PriceUpdated(asset, price, block.timestamp);
    }

    function getPrice(address asset) external view returns (uint256) {
        return priceE8[asset];
    }
}
