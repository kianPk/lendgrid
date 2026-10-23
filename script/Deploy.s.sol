// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {SimplePriceOracle} from "../src/Oracle.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract DeployLendGrid is Script {
    function run() external {
        address deployer = msg.sender;
        vm.startBroadcast();
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH", 18);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        SimplePriceOracle oracle = new SimplePriceOracle(deployer);
        oracle.setPrice(address(weth), 3000e8);
        oracle.setPrice(address(usdc), 1e8);
        LendingPool pool = new LendingPool(address(weth), address(usdc), address(oracle), deployer, 7500, 8000, 500);
        vm.stopBroadcast();
        console2.log("WETH", address(weth));
        console2.log("USDC", address(usdc));
        console2.log("Oracle", address(oracle));
        console2.log("Pool", address(pool));
    }
}
