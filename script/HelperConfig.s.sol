// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

contract HelperConfig is Script {
    struct NetworkConfig{
        address wethUsdPriceFeed;
        address wbtcUsdPriceFeed;
        address weth;
        address wbtc;
        uint256 deployerKey;
      }

      uint8 public constant DECIMALS = 8;
      int256 public constant ETH_USD_PRICE = 2000e8;
      int256 public constant BTC_USD_PRICE = 1000e8;
      int256 public DEFAULT_ANVIL_KEY = YOUR_DEFAULT_ANVIL_KEY;


      NetworkConfig public activeNetworkConfig; // stores active configuration

      constructor() {
        if(block.chainid == 11155111){
          activeNetworkConfig = getSepoliaEthConfig();
        } else {
          activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
      }

      function getSepoliaEthConfig() public view returns (NetworkConfig memory){
        return NetworkConfig({
            wethUsdPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306, // ETH / USD
            wbtcUsdPriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
            weth: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81,
            wbtc: 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063,
            deployerKey: vm.envUint("PRIVATE_KEY") // loading deployers private key from .env
        });
      }

      function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        if(activeNetworkConfig.wethUsdPriceFeed != address(0)){
           return activeNetworkConfig;
        }

        vm.startBroadcast();
        MockV3Aggregator ethUsdPriceFeed = new MockV3Aggregator(
          DECIMALS,
          ETH_USD_PRICE
        );
        // deploys mock chainlink price feed for ETH/USD.
        // creates a mock ERC-20 token for WETH.
        ERC20Mock wethMock = new ERC20Mock("WETH", "WETH", msg.sender, 1000e8);

         MockV3Aggregator btcUsdPriceFeed = new MockV3Aggregator(
          DECIMALS,
          BTC_USD_PRICE 
        );
        // Creates a mock ERC-20 token for WBTC
        ERC20Mock wbtcMock = new ERC20Mock("WBTC", "WBTC", msg.sender, 1000e8);

        vm.stopBroadcast();

        // Returns the newly created mock contract addresses for local testing
        return NetworkConfig({
            wethUsdPriceFeed: address(ethUsdPriceFeed),
            wbtcUsdPriceFeed: address(btcUsdPriceFeed),
            weth: address(wethMock),
            wbtc: address(wbtcMock),
            deployerKey: DEFAULT_ANVIL_KEY
        });
      } 
}
