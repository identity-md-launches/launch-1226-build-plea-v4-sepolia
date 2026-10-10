// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {CabalGate} from "../src/CabalGate.sol";

contract VectorConsumer is OracleAttestationConsumer {
    constructor(address signer) OracleAttestationConsumer(signer) {}

    function verify(OracleAttestation.Attestation calldata a, bytes calldata sig) external {
        _verifyAttestation(a, sig);
        _consume(a.requestId);
    }
}

/// @notice Protocol-published viem vector, independent of locally generated signatures.
contract OracleConformanceTest is Test {
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    VectorConsumer consumer;

    function setUp() public {
        vm.chainId(11155111);
        vm.warp(1800000000);
        VectorConsumer implementation = new VectorConsumer(SIGNER);
        vm.etch(VECTOR_CONSUMER, address(implementation).code);
        consumer = VectorConsumer(VECTOR_CONSUMER);
    }

    function vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: 5,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: 1800000000,
            expiresAt: 1800003600
        });
    }

    function testDigestMatchesProtocol() public view {
        assertEq(consumer.attestationDigest(vector()), VECTOR_DIGEST);
    }

    function testProtocolSignatureAcceptedUnder200k() public {
        consumer.verify{gas: 200_000}(vector(), VECTOR_SIGNATURE);
        assertTrue(consumer.consumed(vector().requestId));
    }

    function testCallbackSelector() public pure {
        assertEq(CabalGate.onOracleResult.selector, bytes4(0x510379c7));
    }

    function testDomainSeparatesChainsAndConsumers() public {
        vm.chainId(1);
        assertNotEq(consumer.attestationDigest(vector()), VECTOR_DIGEST);
        vm.chainId(11155111);
        VectorConsumer another = new VectorConsumer(SIGNER);
        assertNotEq(another.attestationDigest(vector()), VECTOR_DIGEST);
    }
}
