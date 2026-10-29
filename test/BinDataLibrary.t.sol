// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {Test} from "forge-std/Test.sol";
import {BinDataLibrary} from "../contracts/libraries/BinDataLibrary.sol";

contract BinDataLibraryTest is Test {
  using BinDataLibrary for BinDataLibrary.BinData;
  using BinDataLibrary for BinDataLibrary.BinDataPackedx5;

  function test_packAndUnpack5BinData() public pure {
    // Create 5 distinct BinData values
    BinDataLibrary.BinData bin0 = BinDataLibrary.pack(1000, 100, 50);
    BinDataLibrary.BinData bin1 = BinDataLibrary.pack(2000, 200, 150);
    BinDataLibrary.BinData bin2 = BinDataLibrary.pack(3000, 300, 250);
    BinDataLibrary.BinData bin3 = BinDataLibrary.pack(4000, 400, 350);
    BinDataLibrary.BinData bin4 = BinDataLibrary.pack(5000, 500, 450);

    // Pack all 5 bins into a single uint256
    uint256 packed = uint256(BinDataLibrary.BinData.unwrap(bin0)) | (uint256(BinDataLibrary.BinData.unwrap(bin1)) << 48)
      | (uint256(BinDataLibrary.BinData.unwrap(bin2)) << 96) | (uint256(BinDataLibrary.BinData.unwrap(bin3)) << 144)
      | (uint256(BinDataLibrary.BinData.unwrap(bin4)) << 192);

    BinDataLibrary.BinDataPackedx5 packedData = BinDataLibrary.BinDataPackedx5.wrap(packed);

    // Unpack and verify each position
    for (uint8 i = 0; i < 5; i++) {
      BinDataLibrary.BinData extracted = packedData.getBinData(i);
      (uint16 length, uint16 buyFee, uint16 sellFee) = extracted.unpack();

      uint16 expectedLength = uint16(1000 + (uint256(i) * 1000));
      uint16 expectedBuyFee = uint16(100 + (uint256(i) * 100));
      uint16 expectedSellFee = uint16(50 + (uint256(i) * 100));

      assertEq(length, expectedLength, "Length mismatch");
      assertEq(buyFee, expectedBuyFee, "Buy fee mismatch");
      assertEq(sellFee, expectedSellFee, "Sell fee mismatch");
    }
  }

  function test_toBinData_allPositions() public pure {
    // Create 5 distinct BinData values packed in uint256
    uint256 packed = (uint256(1000) | (uint256(100) << 16) | (uint256(50) << 32))
      | ((uint256(2000) | (uint256(200) << 16) | (uint256(150) << 32)) << 48)
      | ((uint256(3000) | (uint256(300) << 16) | (uint256(250) << 32)) << 96)
      | ((uint256(4000) | (uint256(400) << 16) | (uint256(350) << 32)) << 144)
      | ((uint256(5000) | (uint256(500) << 16) | (uint256(450) << 32)) << 192);

    // Test toBinData function for all positions
    for (uint8 i = 0; i < 5; i++) {
      BinDataLibrary.BinData extracted = BinDataLibrary.toBinData(packed, i);
      (uint16 length, uint16 buyFee, uint16 sellFee) = extracted.unpack();

      uint16 expectedLength = uint16(1000 + (uint256(i) * 1000));
      uint16 expectedBuyFee = uint16(100 + (uint256(i) * 100));
      uint16 expectedSellFee = uint16(50 + (uint256(i) * 100));

      assertEq(length, expectedLength, "Length mismatch in toBinData");
      assertEq(buyFee, expectedBuyFee, "Buy fee mismatch in toBinData");
      assertEq(sellFee, expectedSellFee, "Sell fee mismatch in toBinData");
    }
  }

  function test_getBinData_matchesToBinData() public pure {
    // Verify that getBinData and toBinData return the same results
    uint256 packed = (uint256(1234) | (uint256(567) << 16) | (uint256(890) << 32))
      | ((uint256(2345) | (uint256(678) << 16) | (uint256(901) << 32)) << 48)
      | ((uint256(3456) | (uint256(789) << 16) | (uint256(123) << 32)) << 96)
      | ((uint256(4567) | (uint256(890) << 16) | (uint256(234) << 32)) << 144)
      | ((uint256(5678) | (uint256(901) << 16) | (uint256(345) << 32)) << 192);

    BinDataLibrary.BinDataPackedx5 packedData = BinDataLibrary.BinDataPackedx5.wrap(packed);

    for (uint8 i = 0; i < 5; i++) {
      BinDataLibrary.BinData fromGetBinData = packedData.getBinData(i);
      BinDataLibrary.BinData fromToBinData = BinDataLibrary.toBinData(packed, i);

      (uint16 length1, uint16 buyFee1, uint16 sellFee1) = fromGetBinData.unpack();
      (uint16 length2, uint16 buyFee2, uint16 sellFee2) = fromToBinData.unpack();

      assertEq(length1, length2, "Length mismatch between methods");
      assertEq(buyFee1, buyFee2, "Buy fee mismatch between methods");
      assertEq(sellFee1, sellFee2, "Sell fee mismatch between methods");
    }
  }

  function test_packUnpack_edgeCases() public pure {
    // Test with max values (uint16 max = 65535)
    BinDataLibrary.BinData maxData = BinDataLibrary.pack(65535, 65535, 65535);
    (uint16 length, uint16 buyFee, uint16 sellFee) = maxData.unpack();
    assertEq(length, 65535, "Max length");
    assertEq(buyFee, 65535, "Max buy fee");
    assertEq(sellFee, 65535, "Max sell fee");

    // Test with zero values
    BinDataLibrary.BinData zeroData = BinDataLibrary.pack(0, 0, 0);
    (length, buyFee, sellFee) = zeroData.unpack();
    assertEq(length, 0, "Zero length");
    assertEq(buyFee, 0, "Zero buy fee");
    assertEq(sellFee, 0, "Zero sell fee");
  }

  function testFuzz_packUnpack(uint16 length, uint16 buyFee, uint16 sellFee) public pure {
    BinDataLibrary.BinData data = BinDataLibrary.pack(length, buyFee, sellFee);
    (uint16 outLength, uint16 outBuyFee, uint16 outSellFee) = data.unpack();

    assertEq(outLength, length, "Length mismatch");
    assertEq(outBuyFee, buyFee, "Buy fee mismatch");
    assertEq(outSellFee, sellFee, "Sell fee mismatch");
  }

  function testFuzz_getBinData_allPositions(
    uint16[5] memory lengths,
    uint16[5] memory buyFees,
    uint16[5] memory sellFees
  ) public pure {
    // Pack 5 bins
    uint256 packed = 0;
    for (uint256 i = 0; i < 5; i++) {
      uint256 binData = uint256(lengths[i]) | (uint256(buyFees[i]) << 16) | (uint256(sellFees[i]) << 32);
      packed |= binData << (i * 48);
    }

    BinDataLibrary.BinDataPackedx5 packedData = BinDataLibrary.BinDataPackedx5.wrap(packed);

    // Verify all positions
    for (uint8 i = 0; i < 5; i++) {
      BinDataLibrary.BinData extracted = packedData.getBinData(i);
      (uint16 length, uint16 buyFee, uint16 sellFee) = extracted.unpack();

      assertEq(length, lengths[i], "Length mismatch in fuzz test");
      assertEq(buyFee, buyFees[i], "Buy fee mismatch in fuzz test");
      assertEq(sellFee, sellFees[i], "Sell fee mismatch in fuzz test");
    }
  }
}
