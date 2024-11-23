// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20Burnable, ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from
    "lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./library/Oraclelib.sol";


/*
 * @title DSCEngine
 * @dev This contract manages the Decentralized Stablecoin (DSC) system with minimal complexity, 
 * maintaining the peg of 1 token = $1. It facilitates collateral deposits, DSC minting, redemption, and liquidation.
 * 
 * @notice Key features of the DSC system:
 * - Exogenous collateral
 * - Dollar-pegged
 * - Algorithmically stable
 * 
 * @details Differences from DAI:
 * - No governance
 * - No fees
 * - Backed solely by WETH and WVTC
 * 
 * @important The system must always remain overcollateralized. The value of all collateral must never be less than 
 * the value of DSC in circulation.
 */

contract DSCEngine is ReentrancyGuard {
    /////////////////////
    ////// ERRORS ///////
    /////////////////////

    error DSCEngine__NeedMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedLengthMismatch();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealfactorIsOkay();
    error DSCEngine__HealthFactorNotImproved();



    ////////////////////////////
    //////      TYPE    /S /////
    ////////////////////////////
    using OracleLib for AggregatorV3Interface;



    ////////////////////////////
    ////// STATE VARIABLES /////
    ////////////////////////////

    uint256 private constant LIQUIDATION_THRESHOLD = 50;

    mapping(address => address) private s_priceFeeds; // Maps collateral token addresses to their price feed addresses
    mapping(address => mapping(address => uint256)) private s_collateralDeposited; // Tracks collateral deposits by users
    mapping(address => uint256) private s_DSCMinted; // Tracks DSC tokens minted by users
    address[] private s_collateralTokens; // List of allowed collateral tokens
    DecentralizedStableCoin private immutable i_dsc; // DSC token instance

    /////////////////////
    ////// EVENTS ///////
    /////////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed reddeemedFrom, address indexed reedemedTo, address indexed token, uint256 amount
    );

    /////////////////////
    ////// MODIFIERS /////
    /////////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    ////////////////////////////
    ////// CONSTRUCTOR /////////
    ////////////////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressAndPriceFeedLengthMismatch();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ///////////////////////////////
    ////// EXTERNAL FUNCTIONS /////
    ///////////////////////////////

    function depositCollateralAndMintDSC(address tokenCollateral, uint256 amountCollateral, uint256 amountDscTomint)
        public
    {
        depositCollateral(tokenCollateral, amountCollateral);
        mintDSC(amountDscTomint);
    }

    function depositCollateral(address tokenCollateral, uint256 amountCollateral)
        public
        isAllowedToken(tokenCollateral)
        moreThanZero(amountCollateral)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateral] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateral, amountCollateral);

        bool success = IERC20(tokenCollateral).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDSC(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        //reddem collateral already check health factor
    }

    //in order to redeem collateral their health factor must be over 1 after colateral is pulled
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        nonReentrant
        moreThanZero(amountCollateral)
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfNotEnoughCollateral(msg.sender);
    }

    function mintDSC(uint256 amountToMint) public nonReentrant moreThanZero(amountToMint) {
        s_DSCMinted[msg.sender] += amountToMint;
        _revertIfNotEnoughCollateral(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountToMint);

        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDSC(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);

        _revertIfNotEnoughCollateral(msg.sender); //i dont think this is needed
    }

    // If someone is almost undercollateralized, they can be liquidated
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        nonReentrant
        moreThanZero(debtToCover)
    {
        uint256 startingUserHealtFactor = _healthFactor(user);
        if (startingUserHealtFactor >= 1e18) {
            revert DSCEngine__HealfactorIsOkay();
        }

        uint256 tokenAmountFromCollateral = getTokenAmountFromUsd(collateral, debtToCover);

        uint256 bonusCollateral = tokenAmountFromCollateral * 10 / 100;
        uint256 totlCollateralToReedem = tokenAmountFromCollateral + bonusCollateral;

        _redeemCollateral(user, msg.sender, collateral, totlCollateralToReedem);
        _burnDsc(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealtFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfNotEnoughCollateral(msg.sender);
    }

    function getHealthFactor() external view {}

    /////////////////////
    ////// PRIVATE FUNCTIONS ///////
    /////////////////////
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / 100;
        return (collateralAdjustedForThreshold * 1e18) / totalDscMinted;
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateral(user);
    }

    function _revertIfNotEnoughCollateral(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < 1e18) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /////////////////////
    ////// PUBLIC FUNCTIONS ///////
    /////////////////////

    function getAccountCollateral(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((uint256(price) * 1e10) * amount) / 1e18;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        require(price > 0, "Invalid price");

        // Adjust price from 8 decimals to 18 decimals
        uint256 adjustedPrice = uint256(price) * 1e10;

        // Calculate token amount
        return (usdAmountInWei * 1e18) / adjustedPrice;
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }
    function getCollateralToken() external view returns(address[] memory) {
        return s_collateralTokens;
    }
    
    function getCollateralBalanceOfUser(address user, address token) external view returns(uint256) {
        return s_collateralDeposited[user][token];
    }
}
