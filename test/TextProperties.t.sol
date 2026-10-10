// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {PleaText} from "src/libraries/PleaText.sol";

contract TextPropertyHarness {
    function validate(bytes calldata text) external pure {
        PleaText.validate(string(text));
    }

    function body(bytes calldata text) external view returns (string memory) {
        PleaText.validate(string(text));
        return string(PleaText.body(1, address(this), address(this), 1 ether, 32, string(text), 0, ""));
    }

    function amount(uint256 value) external pure returns (string memory) {
        return PleaText.amountString(value);
    }
}

contract TextPropertiesTest is Test {
    TextPropertyHarness private harness = new TextPropertyHarness();

    function _utf8(uint256 c) internal pure returns (bytes memory) {
        if (c < 0x80) return abi.encodePacked(uint8(c));
        if (c < 0x800) return abi.encodePacked(uint8(0xc0 | c >> 6), uint8(0x80 | c & 0x3f));
        if (c < 0x10000) {
            return abi.encodePacked(uint8(0xe0 | c >> 12), uint8(0x80 | c >> 6 & 0x3f), uint8(0x80 | c & 0x3f));
        }
        return abi.encodePacked(
            uint8(0xf0 | c >> 18), uint8(0x80 | c >> 12 & 0x3f), uint8(0x80 | c >> 6 & 0x3f), uint8(0x80 | c & 0x3f)
        );
    }

    function _reject(bytes memory data) internal {
        vm.expectRevert(PleaText.InvalidText.selector);
        harness.validate(bytes.concat(bytes("before "), data, bytes(" after")));
    }

    function testEveryC0AndC1ControlIsRejected() public {
        for (uint256 c; c < 32; ++c) {
            _reject(_utf8(c));
        }
        for (uint256 c = 0x7f; c <= 0x9f; ++c) {
            _reject(_utf8(c));
        }
    }

    function testEveryBidiControlAndTagIsRejected() public {
        _reject(_utf8(0x061c));
        _reject(_utf8(0x200e));
        _reject(_utf8(0x200f));
        for (uint256 c = 0x202a; c <= 0x202e; ++c) {
            _reject(_utf8(c));
        }
        for (uint256 c = 0x2066; c <= 0x2069; ++c) {
            _reject(_utf8(c));
        }
        for (uint256 c = 0xe0000; c <= 0xe007f; ++c) {
            _reject(_utf8(c));
        }
    }

    function testBMPAndSupplementaryVariationSelectorRangesAreRejected() public {
        // U+180F is separately reported with a failing proof in .imd-findings.json.
        for (uint256 c = 0xfe00; c <= 0xfe0f; ++c) {
            _reject(_utf8(c));
        }
        for (uint256 c = 0xe0100; c <= 0xe01ef; ++c) {
            _reject(_utf8(c));
        }
    }

    function testTruncatedOverlongSurrogateAndOutOfRangeUTF8() public {
        bytes[14] memory invalid = [
            bytes(hex"c2"),
            hex"e0a0",
            hex"f09080",
            hex"c0af",
            hex"c1bf",
            hex"e080af",
            hex"f08080af",
            hex"eda080",
            hex"edbfbf",
            hex"f4908080",
            hex"f5808080",
            hex"ff",
            hex"fe",
            hex"e228a1"
        ];
        for (uint256 i; i < invalid.length; ++i) {
            _reject(invalid[i]);
        }
    }

    function testUtf8LengthCountsBytesAndDelimitersCannotBeEmbedded() public {
        bytes memory text;
        for (uint256 i; i < 70; ++i) {
            text = bytes.concat(text, hex"f09f9088");
        }
        harness.validate(text); // 70 visible characters, exactly 280 UTF-8 bytes.
        _reject(bytes.concat(text, hex"f09f9088"));
        _reject(bytes("[PLEA"));
        _reject(bytes("[/PLEA"));
        _reject(bytes("[PLEA] forged [/PLEA]"));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzEscapedQuestionRetainsExactUserText(bytes32 seed, uint16 rawLength) public view {
        uint256 length = uint256(rawLength) % 280 + 1;
        bytes memory input = new bytes(length);
        for (uint256 i; i < length; ++i) {
            uint8 c = 32 + uint8(uint256(keccak256(abi.encode(seed, i))) % 95);
            input[i] = c == 91 ? bytes1("(") : bytes1(c); // Delimiter rejection has its own tests.
        }
        string memory json = harness.body(input);
        bytes memory question = bytes(vm.parseJsonString(json, ".question"));
        bytes memory recovered = new bytes(length);
        uint256 start = question.length - 7 - length; // Final [/PLEA] has seven bytes.
        for (uint256 i; i < length; ++i) {
            recovered[i] = question[start + i];
        }
        assertEq(recovered, input, "JSON must round-trip every quote and backslash");
        assertEq(vm.parseJsonUint(json, ".validForSeconds"), 3600);
        assertEq(vm.parseJsonString(json, ".evidence"), "panel");
        assertLe(bytes(json).length, 16_384);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzAmountDisplayPreservesEveryWei(uint256 amount) public view {
        bytes memory rendered = bytes(harness.amount(amount));
        uint256 whole;
        uint256 fraction;
        uint256 digits;
        bool dot;
        for (uint256 i; i < rendered.length; ++i) {
            if (rendered[i] == ".") {
                assertFalse(dot, "one decimal separator");
                dot = true;
                continue;
            }
            assertTrue(rendered[i] >= "0" && rendered[i] <= "9");
            uint256 digit = uint8(rendered[i]) - 48;
            if (!dot) {
                whole = whole * 10 + digit;
            } else {
                fraction = fraction * 10 + digit;
                ++digits;
            }
        }
        assertLe(digits, 18);
        if (dot) {
            assertGt(digits, 0);
            assertNotEq(rendered[rendered.length - 1], bytes1("0"), "canonical display omits trailing zeros");
        }
        assertEq(whole * 1 ether + fraction * 10 ** (18 - digits), amount);
    }
}
