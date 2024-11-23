// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";


contract Handler is Test {
  DSCEngine dsce;
  DecentralizedStableCoin dsc;
  ERC20Mock weth;
  ERC20Mock wbtc;
  uint256 public timesMintIsCalled;
  address[] usersWithCollateralDeposited;
  uint256 constant MAX_DEPOSIT_SIZE = type(uint96).max;
  MockV3Aggregator public ethUsdPrieFeed;
  constructor (DSCEngine _dscEnine, DecentralizedStableCoin _dsc) {
    dsce = _dscEnine;
    dsc = _dsc;
    address[] memory collateralTokens = dsce.getCollateralToken();
    weth= ERC20Mock(collateralTokens[0]);
    wbtc= ERC20Mock(collateralTokens[1]);
    // ethUsdPrieFeed = dsce.getCollateralTokenPriceFeed(address(weth));
  }
  function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
    ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
    amountCollateral = bound(amountCollateral,1,MAX_DEPOSIT_SIZE);
    vm.startPrank(msg.sender);
    collateral.mint(msg.sender, amountCollateral);
    collateral.approve(address(dsce), amountCollateral);
    dsce.depositCollateral(address(collateral), amountCollateral);
    vm.stopPrank();
    usersWithCollateralDeposited.push(msg.sender);
    
  }

  function redeemCollateral( uint256 collateralSeed, uint256 amountCollateral) public {
    ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
    uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(address(collateral), msg.sender);
    amountCollateral = bound(amountCollateral, 0,maxCollateralToRedeem );
    if (amountCollateral ==0 ){
      return;
    }
    dsce.redeemCollateral(address(collateral), amountCollateral);
  } 

  function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
    if(collateralSeed %2 ==0) {
      return weth;
    } else {
      return wbtc;
    }
  }
  function mintDSC(uint256 amount,uint256 addressSeed) public {
    if(usersWithCollateralDeposited.length ==0){
      return;
    }
    address sender = usersWithCollateralDeposited[addressSeed%usersWithCollateralDeposited.length];

    amount = bound(amount,1, MAX_DEPOSIT_SIZE);
   
     (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(sender);
     int256 maxDScToMint = (int256(collateralValueInUsd)/2) -int256(totalDscMinted);
     if(maxDScToMint <0){
      return;
     }
     amount = bound(amount,0 ,uint256(maxDScToMint));
     if(amount ==0){
      return;
     }
      vm.startPrank(sender);
    dsce.mintDSC(amount);
    vm.stopPrank();
    timesMintIsCalled++;
  }

  // function UpdateCollateralPrice(uint96 newPrice) public {
  //   int256 newPriceInt = int256(uint256(newPrice));
  //   ethUsdPrieFeed.updateAnswer(newPriceInt);
  // }
 
}