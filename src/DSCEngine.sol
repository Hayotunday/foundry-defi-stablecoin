// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Idowu Daniel
 *
 * This system is designed to be as minimial as possible, and have the tokens maintain a 1 token == $1 peg.
 * This stablecoin ha the properties
 * - Exogenus Collateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar ro DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized".
 * At no point should the value of all collateral should be <= the $ backed of all the DSC.
 *
 * @notice This contract is the core of the DSC system. It handles all the logic for minting and redeeming DSC,
 *         as well as depositing and withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */

contract DSCEngine is ReentrancyGuard {
  //// Errors
  error DSCEngine__NeedsMoreThanZero();
  error DSCEngine__NotAllowedToken();
  error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
  error DSCEngine__TransferFailed();
  error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
  error DSCEngine__MintFailed();
  error DSCEngine__HealthFactorOk();
  error DSCEngine__HealthFactorNotImproved();

  //// Types
  using OracleLib for AggregatorV3Interface;

  //// State Variables
  uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
  uint256 private constant PRECISION = 1e18;
  uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
  uint256 private constant LIQUIDATION_PRECISION = 100;
  uint256 private constant LIQUIDATION_BONUS = 10; // 10% liquidation bonus
  uint256 private constant MIN_HEALTH_FACTOR = 1e18;

  mapping(address token => address priceFeed) private s_priceFeeds;
  mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
  mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

  address[] private s_collateralTokens;

  DecentralizedStableCoin private immutable i_dsc;

  //// Events
  event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
  event CollateralRedeemed(
    address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
  );

  //// Modifiers
  modifier moreThanZero(uint256 amount) {
    _moreThanZero(amount);
    _;
  }
  modifier isAllowedToken(address token) {
    _isAllowedToken(token);
    _;
  }

  //// Constructor
  constructor(address[] memory tokenAddresses, address[] memory priceFeedAddress, address dscAddress) {
    if (tokenAddresses.length != priceFeedAddress.length) {
      revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    }
    // USD Price Feeds
    // For example ETH / USD, BTC / USD
    for (uint256 i = 0; i < tokenAddresses.length; i++) {
      s_priceFeeds[tokenAddresses[i]] = priceFeedAddress[i];
      s_collateralTokens.push(tokenAddresses[i]);
    }
    i_dsc = DecentralizedStableCoin(dscAddress);
  }

  //// Functions
  //// External Functions
  /**
   * @notice follow CEI
   * @param tokenCollateralAddress The address of the token to deposit as collateral
   * @param amountCollateral The amount of collateral to deposit
   * @param amountDscToMint The amount of decentralized stablecoin to mint
   * @notice This function deposits collateral and mints DSC in a single transaction
   */
  function depositCollateralAndMintDsc(
    address tokenCollateralAddress,
    uint256 amountCollateral,
    uint256 amountDscToMint
  ) external {
    depositCollateral(tokenCollateralAddress, amountCollateral);
    mintDsc(amountDscToMint);
  }

  /**
   * @notice follow CEI
   * @param tokenCollateralAddress The address of the token to deposit as collateral
   * @param amountCollateral The amount of collateral to deposit
   */
  function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
    public
    nonReentrant
    moreThanZero(amountCollateral)
    isAllowedToken(tokenCollateralAddress)
  {
    s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
    emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
    bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
    if (!success) {
      revert DSCEngine__TransferFailed();
    }
  }

  /**
   * @notice follow CEI
   * @param amountDscToMint The amount of decentralized stablecoin to mint
   * @notice they must have more collateral value than the minimum threshold to mint
   */
  function mintDsc(uint256 amountDscToMint) public nonReentrant moreThanZero(amountDscToMint) {
    s_DSCMinted[msg.sender] += amountDscToMint;
    _revertIfHealthFactorIsBroken(msg.sender);
    bool minted = i_dsc.mint(msg.sender, amountDscToMint);
    if (!minted) {
      revert DSCEngine__MintFailed();
    }
  }

  /**
   * @param tokenCollateralAddress The collateral token address to redeem
   * @param amountCollateral The amount of collateral to redeem
   * @param amountDscToBurn The amount of DSC to burn
   * This function burns DSC and redeems underlying collateral in a single transaction
   */
  function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
    external
  {
    burnDsc(amountDscToBurn);
    redeemCollateral(tokenCollateralAddress, amountCollateral);
    // redeemCollateral already checks health factor
  }

  function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
    public
    nonReentrant
    moreThanZero(amountCollateral)
  {
    _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
    _revertIfHealthFactorIsBroken(msg.sender);
  }

  function burnDsc(uint256 amount) public moreThanZero(amount) {
    _burnDsc(msg.sender, msg.sender, amount);
    _revertIfHealthFactorIsBroken(msg.sender); // I don't think this would ever hit...
  }

  /**
   * If we do start nearing undercollateralization, we need a way to liquidate accounts
   * @notice This function liquidates a given account if its health factor is below the minimum threshold
   * @param collateral The collateral token address to liquidate from the user param
   * @param user The user to liquidate. who has broken the health factor.
   *             Their _healthFactor should be below MIN_HEALTH_FACTOR
   * @param debtToCover The amount of DSC to burn to cover the debt and improve user's health factor
   * @notice You can partially liquidate the user
   * @notice You will get a liquidation bonus (10%) for taking the risk of liquidating someone
   * @notice This function working assumes the protocol is roughly 200% overcollateralized in order for this to work
   * @notice A known bug would be if the protocol is 100% or less collateralized, then no one would be
   *         incentivized to liquidate since there would be no liquidation bonus.
   *         For example, if the price of the collateral plummeted before anyone could be liquidated.
   *
   * Follows CEI: Checks, Effects, and Interactions
   */
  function liquidate(address collateral, address user, uint256 debtToCover)
    external
    nonReentrant
    moreThanZero(debtToCover)
  {
    uint256 startingUserHealthFactor = _healthFactor(user);
    if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
      revert DSCEngine__HealthFactorOk();
    }
    // We want to burrn their DSC "debt" and take their collateral
    uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
    uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
    uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
    _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
    _burnDsc(user, msg.sender, debtToCover);

    uint256 endingUserHealthFactor = _healthFactor(user);
    if (endingUserHealthFactor <= startingUserHealthFactor) {
      revert DSCEngine__HealthFactorNotImproved();
    }
    _revertIfHealthFactorIsBroken(msg.sender);
  }

  //// Private and Internal View Functions
  /**
   * @dev low-level internal function, do not call unless the function calling it is checking for health factor being broken
   */

  function _burnDsc(address onBehalfOf, address dscFrom, uint256 amountDscToBurn) private {
    s_DSCMinted[onBehalfOf] -= amountDscToBurn;
    bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
    // This conditional is hypothetically unreachable
    if (!success) {
      revert DSCEngine__TransferFailed();
    }
    i_dsc.burn(amountDscToBurn);
    _revertIfHealthFactorIsBroken(msg.sender); // I don't think this would ever hit...
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

  function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
    AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
    (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
    // 1 ETH = 1000 USD
    // The returned value from Chainlink will be 1000 * 1e8
    // Most USD pairs have 8 decimals, so we will just pretend they all do
    // We want to have everything in terms of WEI, so we add 10 zeros at the end
    // To avoid overflow from multiplying large `amount` with the scaled price,
    // first scale the price to `PRECISION` (18 decimals), then multiply by amount.
    // adjustedPrice = price * ADDITIONAL_FEED_PRECISION / PRECISION
    uint256 adjustedPrice = (uint256(price) * ADDITIONAL_FEED_PRECISION) / PRECISION;
    return (amount * adjustedPrice);
  }

  function _getAccountInformation(address user)
    private
    view
    returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
  {
    totalDscMinted = s_DSCMinted[user];
    collateralValueInUsd = getAccountCollateralValue(user);
  }

  /**
   * @param user address of the user to calculate the health factor for
   * @return health how close to liquidation the user is
   * If a user goes below 1, then they can get liquidated
   */
  function _healthFactor(address user) private view returns (uint256) {
    // total DSC Minted
    // total collateral value
    (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
    uint256 collateralAdjustedForThreshold = ((collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION);
    return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted; // 150 /100
  }

  function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
    internal
    pure
    returns (uint256)
  {
    if (totalDscMinted == 0) return type(uint256).max;
    uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
    return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
  }

  /**
   * 1. Check health factor (do they have enough collateral)
   * 2. Revert if they don't
   * @param user address of user health to be checked
   */
  function _revertIfHealthFactorIsBroken(address user) internal view {
    uint256 userHealthFactor = _healthFactor(user);
    if (userHealthFactor < MIN_HEALTH_FACTOR) {
      revert DSCEngine__BreaksHealthFactor(userHealthFactor);
    }
  }

  /**
   * @notice Checks if the amount is more than zero
   * @dev internal function for the moreThanZero modifier
   * @param amount The amount to be check
   */
  function _moreThanZero(uint256 amount) internal pure {
    if (amount == 0) {
      revert DSCEngine__NeedsMoreThanZero();
    }
  }

  /**
   * @notice Checks if the token is allowed
   * @dev internal function for the isAllowedToken modifier
   * @param token The token to be check
   */
  function _isAllowedToken(address token) internal view {
    if (s_priceFeeds[token] == address(0)) {
      revert DSCEngine__NotAllowedToken();
    }
  }

  //// Public and External View Functions
  function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd) external pure returns (uint256) {
    return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
  }

  function getAccountInformation(address user)
    external
    view
    returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
  {
    return _getAccountInformation(user);
  }

  function getUsdValue(
    address token,
    uint256 amount // in WEI
  )
    external
    view
    returns (uint256)
  {
    return _getUsdValue(token, amount);
  }

  function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
    return s_collateralDeposited[user][token];
  }

  function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
    for (uint256 index = 0; index < s_collateralTokens.length; index++) {
      address token = s_collateralTokens[index];
      uint256 amount = s_collateralDeposited[user][token];
      totalCollateralValueInUsd += _getUsdValue(token, amount);
    }
    return totalCollateralValueInUsd;
  }

  function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
    AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
    (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
    // $100e18 USD Debt
    // 1 ETH = 2000 USD
    // The returned value from Chainlink will be 2000 * 1e8
    // Most USD pairs have 8 decimals, so we will just pretend they all do
    return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
  }

  function getPrecision() external pure returns (uint256) {
    return PRECISION;
  }

  function getAdditionalFeedPrecision() external pure returns (uint256) {
    return ADDITIONAL_FEED_PRECISION;
  }

  function getLiquidationThreshold() external pure returns (uint256) {
    return LIQUIDATION_THRESHOLD;
  }

  function getLiquidationBonus() external pure returns (uint256) {
    return LIQUIDATION_BONUS;
  }

  function getLiquidationPrecision() external pure returns (uint256) {
    return LIQUIDATION_PRECISION;
  }

  function getMinHealthFactor() external pure returns (uint256) {
    return MIN_HEALTH_FACTOR;
  }

  function getCollateralTokens() external view returns (address[] memory) {
    return s_collateralTokens;
  }

  function getDsc() external view returns (address) {
    return address(i_dsc);
  }

  function getCollateralTokenPriceFeed(address token) external view returns (address) {
    return s_priceFeeds[token];
  }

  function getHealthFactor(address user) external view returns (uint256) {
    return _healthFactor(user);
  }
}
