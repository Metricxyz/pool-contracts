// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IPriceProvider} from "../../contracts/interfaces/IPriceProvider/IPriceProvider.sol";

/// @title Mock Price Provider
/// @notice Mock implementation of IPriceProvider for testing purposes
contract MockOracle is IPriceProvider {
  /// @notice Bid and ask prices in Q64.64 format
  uint128 public bidPrice;
  uint128 public askPrice;

  address public baseToken;
  address public quoteToken;

  /// @notice Set bid and ask prices for IPriceProvider
  /// @param _bidPrice The bid price in Q64.64 format
  /// @param _askPrice The ask price in Q64.64 format
  function setBidAndAskPrice(uint128 _bidPrice, uint128 _askPrice) external {
    bidPrice = _bidPrice;
    askPrice = _askPrice;
  }

  /// @notice Set the token pair this oracle serves
  function setTokens(address _baseToken, address _quoteToken) external {
    baseToken = _baseToken;
    quoteToken = _quoteToken;
  }

  /// @inheritdoc IPriceProvider
  function token0() external view returns (address) {
    return baseToken;
  }

  /// @inheritdoc IPriceProvider
  function token1() external view returns (address) {
    return quoteToken;
  }

  /// @inheritdoc IPriceProvider
  function getBidAndAskPrice() external view returns (uint128, uint128) {
    return (bidPrice, askPrice);
  }
}
