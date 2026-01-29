// SPDX-License-Identifier: MIT

// What are our invariants?
// 1. The total supply of DSC should always be less than the total value of collateral in the system
// 2. Getter view functions should never revert <- evergreen invariant

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {Handler} from "test/invariant/Handler.t.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract InvariantsTest is StdInvariant, Test {
  DeployDSC deployer;
  DSCEngine dsce;
  DecentralizedStableCoin dsc;
  HelperConfig config;
  address weth;
  address wbtc;
  Handler handler;

  function setUp() public {
    deployer = new DeployDSC();
    (dsc, dsce, config) = deployer.run();
    (,, weth, wbtc,) = config.activeNetworkConfig();
    // targetContract(address(dsce));
    handler = new Handler(dsce, dsc);
    targetContract(address(handler));
  }

  function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
    // get value of all the collateral in the protocol and compare it to all the debt
    uint256 totalSupply = dsc.totalSupply();
    uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
    uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

    uint256 totalWethValue = dsce.getUsdValue(weth, totalWethDeposited);
    uint256 totalWbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);

    console.log("weth value:", totalWethValue);
    console.log("wbtc value:", totalWbtcValue);
    console.log("Total supply:", totalSupply);
    console.log("Times mintdsc called:", handler.timesMintIsCalled());

    assert(totalWethValue + totalWbtcValue >= totalSupply);
  }

  // function invariant_gettersShouldNotRevert() public view {
  //     dsce.getPrecision();
  //     dsce.getAdditionalFeedPrecision();
  //     dsce.getLiquidationThreshold();
  //     dsce.getLiquidationBonus();
  //     dsce.getLiquidationPrecision();
  //     dsce.getMinHealthFactor();
  //     dsce.getCollateralTokens();
  //     dsce.getDsc();
  //     dsce.getCollateralTokenPriceFeed(weth);
  //     dsce.getHealthFactor(address(1));
  // }
}
