//SPDX-License-Identifier: MIT 

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentracyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@oppenzepplin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";


// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

/*   
@title DSCEngine
@author Avinash Singh

The system is designed to be as minimal as possible, and have the tokens maintain 
1 token == $1 peg.
This stable coin has properties:
-Exogenous Collateral 
-Dollar Pegged
-Algorithmically Stable 

Our DSC system should always be "overcollateralized". At no point, should the value of all collateral <= the value of all the DSC.

It is similar to DAI if DAI had no governance, no fees, and was only backed by Weth and WBTC

@notice This contract is the core of the DSC System. It handles all the logic for 
mining and redeeming DSC, as well as depositing & withdrawing collateral. 

@notice This contract is very loosely based on the MAKERDAO DSS DAI system.
*/

contract DSCEngine is ReentracyGuard {
    // errors // 
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TransferFailed();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    //state variables//
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18 ; // 1= 100% COLLATERALIZED
    uint256 private constant LIQUIDATION_BONUS = 10 // this means a 10% bonus

    mapping(address token => address priceFeed) private s_priceFeeds; // tracks price feed contracts for each collateral token deposited.
    mapping( address user => mapping(address token => uint256 amount)) private s_collateralDeposited; // records how much collateral each user has deposited per token 
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted; // debt tracking: tracks how much DSC each user has minted
    address[] private s_collateralTokens; // mantains a list of all approved collateral tokens. Ensures only whitelisted tokens are deposited.

    DecentralizedStableCoin private immutable i_dsc;

    //modifiers //
    modifier moreThanZero(uint256 amount){
        if(amount <= 0){
            revert DSCEngine__NeedsMoreThanZero();
        }
    }
    
    // allows only whitelisted tokens to be deposited as collateral
    modifier isAllowedToken(address token){
       if(s_priceFeeds[token] == address(0)){
        revert DSCEngine__NotAllowedToken();
       }
       _;
    }

    //events//
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);// emitted when a user deposits collateral into the system.
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo,  
     address indexed token, uint256 amount);  // if redeemedFrom != redeemedTo, then it is a liquidation

    constructor(
        address[] memory tokenAddresses,// an array of ERC-20 tokens that can be used as collateral 
        address[] memory priceFeedAddresses, // An array of chainlink price feed contract addresses to get USD prices for each collateral token.
        address dscAddress // address of dsc stablecoin address
    ){ 
        // USD Price feeds
       if(tokenAddresses.length != priceFeedAddresses.length){
        // ensures number of collateral tokens matches the number of price feeds
         revert DSCEngine__TokenAddressAndPriceFeedAddressesMustBeSameLength();
       }
       // for eg ETH/USD, BTC/USD, BTC/USD, MKR/USD etc
       for(uint256 i =0; i< tokenAddresses.lenght; i++){
      // loops through each collateral token, stores its price feed address in the mapping s_priceFeeds.
         s_priceFeeds[tokenAddresses[i] = priceFeedAddresses[i]]; 
         s_collateralTokens.push(tokenAddresses[i]); // pushes the token address into s_collateralTokens
       } 
         i_dsc = DecentralizedStableCoin(dscAddress); 
    }

   // EXTERNAL FUNCTIONS //

   /**
    * 
    * @param tokenCollateralAddress the address of the token to deposit as collateral 
    * @param amountCollateral the amount of collateral to deposit
    * @param amountDscToMint amount of dsc to mint
    * @notice this function will deposit your collateral and mintdsc in a single transaction 
    */
   function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint 
     ) 
    external
   {
    depositeCollateral(tokenCollateralAddress, amountCollateral);
    mintDsc(amountDscToMint);
    }


   /**
    * 
    * @param tokenCollateralAddress the address of the token to deposit as collateral
    * @param amountCollateral the amount of collateral to deposit
    */

   function depositCollateral( address tokenCollateralAddress, uint256 amountCollateral) 
    public
    moreThanZero(amountCollateral) 
    isAllowedToken(tokenCollateralAddress)
    nonReentrant
    {
      s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
      // we updated state (variable) better to emit an event now
       emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
      IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
       if(!success){
        revert DSCEngine__TransferFailed(); 
      }
    };

  // in order to redeem collateral
  // 1. health factor must be over 1 AFTER collateral pulled out                                             
   function redeemCollateralForDsc(
        address tokenCollateralAddress, 
        uint256 amountCollateral, 
        uint256 amountDscToBurn
     ) 
         external
         moreThanZero(amountCollateral)
         isAllowedToken(tokenCollateralAddress)
   {
     _burnDsc(amountDscToBurn, msg.sender, msg.sender);
     _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
     _revertIfHealthFactorIsBroken(msg.sender);
   };

   function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) 
   external
   moreThanZero(amountCollateral)
   nonReentrant
   isAllowedToken(tokenCollateralAddress)
   {
      _redeemCollateral( tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
      _revertIfHealthFactorIsBroken(msg.sender);
   }

   function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant{
    s_DSCMinted[msg.sender] += amountDscToMint;
    // if they minted too much ($150 DSC, $100 ETH)
    _revertIfHealthFactorIsBroken(msg.sender);
    bool minted = i_dsc.mint(msg.sender, amountDscToMint);
    if(!minted){
      revert DSCEngine__MintFailed();
    }
   };

     /*
     * @notice careful! You'll burn your DSC here! Make sure you want to do this...
     * @dev you might want to use this if you're nervous you might get liquidated and want to just burn
     * your DSC but keep your collateral in.
     */

   function burnDsc(uint256 amount) public moreThanZero(amount){   
    _burnDsc( amount,  msg.sender, msg.sender);  
      _revertIfHealthFactorIsBroken(msg.sender);  // I don't think thiss would ever hit''
   };
   
   // if we do start nearing undercollateralization, we need someone to liquidate positions
   /**
    * @param collateral The erc20 token address of the collateral to liquidate a user
    * @param user The address of user who has broken health factor. The _healthfactor should be less than MIN_HEALTH_FACTOR;
    * @param debtToCover The amount of DSC you want to burn to improve the users health factor
    * @notice You can partially liquidate a user
    * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work.
    * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentivise the liquidators.
    * For example, if the price of the collateral plummeted before anyone could be liquidated.    */
   function liquidate(address collateral, address user, uint256 debtToCover) external
   moreThanZero(debtToCover)
   isAllowedToken(collateral)
   nonReentrant
   {
    // need to check health factor of the user
    uint256 startingUserHealthFactor = _healthFactor(user);
    if(startingUserHealthFactor >= MIN_HEALTH_FACTOR){
      revert DSCEngine__HealthFactorOk();
    }
    // we want to burn their DSC "debt"
    // and take their collateral
    // bad user: $140 ETH, $100 DSC
    // $100 of DSC == ??? ETH?
    // 0.05 ETH
    uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
    // And give them a 10% bonus
    // So we are giving the liquidator $110 WETH for 100 DSC
    // we should implement a feature to liquidate in the event the protocol is insolvent
    // and sweep extra amounts into a treasury
    // 0.05 * 0.1 = 0.005.
    uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS)/ LIQUIDATION_PRECISION;
    uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral; 
    _redeemCollateral( collateral, totalCollateralToRedeem, user, msg.sender);
    // we need to burn dsc 
    _burnDsc(debtToCover, user, msg.sender);
    uint256 endingUserHealthFactor = _healthFactor(user);
    if(endingUserHealthFactor <= startingUserHealthFactor){
      revert DSCEngine__HealthFactorNotImproved();
    }
    _revertIfHealthFactorIsBroken(msg.sender); 
   };

   function getHealthFactor() external view{};

   // INTERNAL FUNCTIONS //

  function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
     s_DSCMinted[onBehalfOf] -= amountDscToBurn;
      bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
      // this conditional is hypothetically unreachable
      if(!success){
        revert DSCEngine__TransferFailed();
      }
      i_dsc.burn(amountDscToBurn);
  }

  function _redeemCollateral(
        address tokenCollateralAddress, 
        uint256 amountCollateral,
        address from,
        address to
     )
       private 
  {
    s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
    emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
    bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
    if(!success){
      revert DSCEngine__TransferFailed();
    }
  

   function _getAccountInformation(address user) private view returns (uint256 totalDscMinted, uint256 collateralValueInUsd){
     totalDscMinted = s_DSCMinted(user);
     collateralValueInUsd = getAccountCollateralValueInUsd(user);
   }

   // Returns how close to liquidation a user is
   // If a user goes below 1, then they can get liquidated

   function _healthFactor(address user) private view returns(uint256){
      // total DSC minted
      // total collateral VALUE
      (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
      uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
    return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
   }

   function _revertIfHealthFactorIsBroken(address user) internal view {
    // 1. Check health factor (do they have enough collateral?)
    // 2. Revert if they don't
    uint256 userHealthFactor = _healthFactor(user);
    if(userHealthFactor < MIN_HEALTH_FACTOR){
      revert DSCEngine__BreaksHealthFactor(userHealthFactor);
    }   
   }

   function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view 
   returns (uint256) {
    //price of ETH (token)
    // $/ETH ETH???
    // for example $2000/ ETH, $1000 = 0.5ETH
    AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
    (,int256 price,,,) = priceFeed.latestRoundData();
    return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
   }
  
   function getAccountCollateralValueInUsd(address user) public view returns (uint256 totalCollateralValueInUsd){
      // loop through each collateral token , get the amount thy have deposited, and map it to 
      // the price, to get the USD value 
      for(uint256 i = 0; i<s_collateralTokens.lenght; i++){
        address token = s_collateralTokens[i];
        uint256 amount = s_collateralDeposited[user][token];
        totalCollateralValueInUsd += getUsdValue(token, amount);
      }
      return totalCollateralValueInUsd;
   }

   function getUsdValue(address token, uint256 amount) public view returns(uint256){
      AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
      (,int256 price,,,) = priceFeed.latestRoundData();
      // 1 eth = 1000 usd
      // the returned value from cl will be 1000 * 1e8
      return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; 
   } 

   function getAccountInformation( address user) 
   external
   view
   returns(uint256 totalDscMinted, uint256 collateralValueInUsd)
   {
    (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
   }
  }
}
