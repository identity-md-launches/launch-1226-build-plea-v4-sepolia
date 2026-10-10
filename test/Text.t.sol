// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {PleaText} from "../src/libraries/PleaText.sol";

contract TextHarness {
    function validate(string calldata text) external pure {
        PleaText.validate(text);
    }

    function body(string calldata text) external view returns (bytes memory) {
        PleaText.validate(text);
        return PleaText.body(1, address(this), address(this), 1.125 ether, 32, text, 0, "");
    }

    function amount(uint256 a) external pure returns (string memory) {
        return PleaText.amountString(a);
    }
}

contract TextTest is Test {
    TextHarness harness = new TextHarness();

    function testValidUnicodeAndEscaping() public view {
        string memory text = unicode'Please: "rent", a \\ path, café, 山 and 🐈.';
        string memory json = string(harness.body(text));
        string memory question = vm.parseJsonString(json, ".question");
        assertTrue(bytes(question).length > bytes(text).length);
        assertEq(vm.parseJsonUint(json, ".v"), 1);
        assertEq(vm.parseJsonUint(json, ".quorum"), 17);
        assertEq(vm.parseJsonString(json, ".definitions.facts"), "FACT SCORE is final; do not rescore it.");
        assertEq(vm.parseJsonUint(json, ".consumer.chainId"), 11155111);
        assertEq(harness.amount(1.125 ether), "1.125");
        assertEq(harness.amount(1), "0.000000000000000001");
    }

    function testBadUTF8ControlsAndDelimiters() public {
        bytes[] memory bad = new bytes[](20);
        bad[0] = hex"00";
        bad[1] = hex"7f";
        bad[2] = hex"c080";
        bad[3] = hex"eda080";
        bad[4] = hex"f4908080";
        bad[5] = hex"f09f";
        bad[6] = hex"d89c";
        bad[7] = hex"e2808b";
        bad[8] = hex"e280ae";
        bad[9] = hex"efb88f";
        bad[10] = hex"f3a08080";
        bad[11] = hex"f3a081bf";
        bad[12] = hex"f3a08480";
        bad[13] = bytes("[PLEA");
        bad[14] = bytes("[/PLEA");
        bad[15] = hex"0a";
        bad[16] = hex"c29f";
        bad[17] = hex"efbbbf";
        bad[18] = hex"e281a0";
        bad[19] = hex"80";
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(PleaText.InvalidText.selector);
            harness.validate(string(bad[i]));
        }
    }

    function testByteLengthBoundaries() public {
        vm.expectRevert(PleaText.InvalidText.selector);
        harness.validate("");
        bytes memory max = new bytes(280);
        for (uint256 i; i < max.length; ++i) {
            max[i] = "x";
        }
        harness.validate(string(max));
        vm.expectRevert(PleaText.InvalidText.selector);
        harness.validate(string(bytes.concat(max, bytes("x"))));
    }

    function testMongolianVariationSelectorsAreRejected() public {
        for (uint8 last = 0x8b; last <= 0x8f; ++last) {
            vm.expectRevert(PleaText.InvalidText.selector);
            harness.validate(string(abi.encodePacked(hex"e1a0", last)));
        }
        // Adjacent visible Mongolian characters remain valid.
        harness.validate(string(hex"e1a08a"));
        harness.validate(string(hex"e1a090"));
    }

    function testFuzzASCIIProducesValidJSON(bytes memory data) public view {
        uint256 length = data.length % 280 + 1;
        bytes memory text = new bytes(length);
        for (uint256 i; i < length; ++i) {
            text[i] = bytes1(uint8(32 + (uint8(keccak256(abi.encode(data, i))[0]) % 90)));
        }
        // Avoid accidentally generating a rejected delimiter; the random alphabet never contains ']'.
        for (uint256 i; i < length; ++i) {
            if (text[i] == "[") text[i] = "(";
        }
        string memory body = string(harness.body(string(text)));
        assertEq(vm.parseJsonString(body, ".answerType"), "bool");
        assertEq(vm.parseJsonUint(body, ".panelSize"), 30);
    }
}
