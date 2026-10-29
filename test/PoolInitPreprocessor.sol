// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {BinDataLibrary} from "../contracts/libraries/BinDataLibrary.sol";
import {BinState} from "../contracts/types/PoolStorage.sol";

abstract contract PoolInitPreprocessor {
  using BinDataLibrary for BinDataLibrary.BinData;

  function _getScaleMultipliers(address token0, address token1)
    internal
    view
    returns (uint256 token0ScaleMultiplier, uint256 token1ScaleMultiplier)
  {
    uint8 token0Decimals = IERC20Metadata(token0).decimals();
    uint8 token1Decimals = IERC20Metadata(token1).decimals();
    uint8 internalDecimals = 18;
    if (token0Decimals > internalDecimals) internalDecimals = token0Decimals;
    if (token1Decimals > internalDecimals) internalDecimals = token1Decimals;
    token0ScaleMultiplier = 10 ** (internalDecimals - token0Decimals);
    token1ScaleMultiplier = 10 ** (internalDecimals - token1Decimals);
  }

  function _countBins(uint256[] memory packedArray) internal pure returns (uint16 count) {
    for (uint16 i = 0; i < packedArray.length; i++) {
      uint256 packed = packedArray[i];
      for (uint8 j = 0; j < 5; j++) {
        BinDataLibrary.BinData binData = BinDataLibrary.toBinData(packed, j);
        (uint16 length,,) = binData.unpack();
        if (length == 0) break;
        count++;
      }
    }
  }

  function _unpackBinStates(uint256[] memory nonNegativeBinDataArray, uint256[] memory negativeBinDataArray)
    internal
    pure
    returns (BinState[] memory nonNegativeBinStates, BinState[] memory negativeBinStates)
  {
    uint16 nonNegativeCount = _countBins(nonNegativeBinDataArray);
    uint16 negativeCount = _countBins(negativeBinDataArray);

    nonNegativeBinStates = new BinState[](nonNegativeCount);
    negativeBinStates = new BinState[](negativeCount);

    {
      uint16 k = 0;
      for (uint16 i = 0; i < nonNegativeBinDataArray.length; i++) {
        uint256 packed = nonNegativeBinDataArray[i];
        for (uint8 j = 0; j < 5; j++) {
          BinDataLibrary.BinData binData = BinDataLibrary.toBinData(packed, j);
          (uint16 length, uint16 buyFee, uint16 sellFee) = binData.unpack();
          if (length == 0) break;
          nonNegativeBinStates[k] = BinState({
            token0BalanceScaled: 0, token1BalanceScaled: 0, lengthE6: length, addFeeBuyE6: buyFee, addFeeSellE6: sellFee
          });
          k++;
        }
      }
    }

    {
      uint16 k = 0;
      for (uint16 i = 0; i < negativeBinDataArray.length; i++) {
        uint256 packed = negativeBinDataArray[i];
        for (uint8 j = 0; j < 5; j++) {
          BinDataLibrary.BinData binData = BinDataLibrary.toBinData(packed, j);
          (uint16 length, uint16 buyFee, uint16 sellFee) = binData.unpack();
          if (length == 0) break;
          negativeBinStates[k] = BinState({
            token0BalanceScaled: 0, token1BalanceScaled: 0, lengthE6: length, addFeeBuyE6: buyFee, addFeeSellE6: sellFee
          });
          k++;
        }
      }
    }
  }
}
