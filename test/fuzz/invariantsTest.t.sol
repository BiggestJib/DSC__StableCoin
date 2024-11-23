// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantTest is StdInvariant, Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address weth;
    address wbtc;
    Handler handler;

    // Set up the environment for the test
    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
        // targetContract(address(dsce));
        handler = new Handler(dsce,dsc);
        targetContract(address(handler));

    }

    /**
     * @notice Ensures the protocol remains overcollateralized.
     * The total USD value of WETH and WBTC deposited must always exceed the total supply of DSC.
     */
    function invariant_testProtocol() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));
        uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);

        // Assert that the total collateral value in USD is greater than the total DSC supply
        assert(wethValue + wbtcValue >= totalSupply);
    }
}
