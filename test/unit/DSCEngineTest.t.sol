// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address BtcUsdPriceFeed;
    address weth;
    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed reddeemedFrom, address indexed reedemedTo, address indexed token, uint256 amount
    );

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, BtcUsdPriceFeed, weth,,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, 10 ether);
    }

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd, "USD value calculation failed");
    }

    function testRevertIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertIfTokenLengthDoesNotMatchPriceFeed() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(BtcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressAndPriceFeedLengthMismatch.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function testGetTokenAmountFomUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth, "Token amount calculation failed");
    }

    function testRevertWithUnAppprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock();
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier DepositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollaterAndGetAccountInfo() public DepositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedTotalDSCMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(expectedTotalDSCMinted, totalDscMinted, "Minted DSC mismatch");
        assertEq(expectedDepositAmount, AMOUNT_COLLATERAL, "Collateral deposit mismatch");
    }

    function testGetAccountInformationWithNoCollateral() public view {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 0, "Minted DSC should be zero");
        assertEq(collateralValueInUsd, 0, "Collateral value in USD should be zero");
    }

    function testEmitEventOnDepositCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectEmit(true, true, true, true);
        emit CollateralDeposited(USER, weth, AMOUNT_COLLATERAL); // Replace with actual event details.

        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testFuzzDepositCollateral(uint256 amount) public {
        vm.assume(amount > 0 && amount <= AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), amount);
        dsce.depositCollateral(weth, amount);
        vm.stopPrank();

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, 0, "No DSC should be minted yet");
        assertGt(collateralValueInUsd, 0, "Collateral value should be greater than zero");
    }

    function testMintDscSuccessfully() public DepositedCollateral {
        uint256 mintAmount = 1 ether; // 1 DSC
        vm.startPrank(USER);

        try dsce.mintDSC(mintAmount) {
            uint256 userBalance = dsc.balanceOf(USER);
            assertEq(userBalance, mintAmount, "User DSC balance should match minted amount");
        } catch (bytes memory reason) {
            emit log("Revert Reason:");
            emit log_bytes(reason);
            fail();
        }

        vm.stopPrank();
    }

    function testRevertMintingExceedingLimit() public DepositedCollateral {
        uint256 mintAmount = 1e24; // Exceeds collateral-backed limit
        vm.startPrank(USER);
        vm.expectRevert();
        dsce.mintDSC(mintAmount);
        vm.stopPrank();
    }

    function testMintTokens() public {
        vm.startPrank(address(dsce)); // Ensure only DSCEngine can mint
        uint256 mintAmount = 10e18; // 10 DSC
        dsc.mint(USER, mintAmount);

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, mintAmount, "User balance should match minted amount");
        vm.stopPrank();
    }

    function testPriceFeedFluctuations() public {
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(2000 * 1e8); // Simulate ETH price drop
        uint256 newPrice = dsce.getUsdValue(weth, 1 ether);

        assertEq(newPrice, 2000 ether, "Price should reflect the updated feed value");
    }

    // function testRevertWithdrawExceedingCollateral() public DepositedCollateral {
    //     vm.startPrank(USER);
    //     vm.expectRevert(DSCEngine.DSCEngine__InsufficientCollateral.selector);
    //     dsce.withdrawCollateral(weth, AMOUNT_COLLATERAL + 1 ether);
    //     vm.stopPrank();
    // }
}
