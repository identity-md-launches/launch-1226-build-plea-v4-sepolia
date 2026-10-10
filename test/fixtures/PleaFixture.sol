// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PLEA} from "../../src/PLEA.sol";
import {CabalGate} from "../../src/CabalGate.sol";
import {PleaHook} from "../../src/PleaHook.sol";
import {PleaDistributor} from "../../src/PleaDistributor.sol";
import {PleaLaunch} from "../../src/PleaLaunch.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../../src/OracleAttestation.sol";
import {Addresses} from "../../src/libraries/Addresses.sol";
import {PleaText} from "../../src/libraries/PleaText.sol";
import {HostileRouter} from "./HostileRouter.sol";
import {MineSalt} from "../../script/MineSalt.s.sol";
import {TestAsset, TestSIMD, MockIntake, TestOracleSigner} from "./Mocks.sol";
import {Stacker, IStakedIMD} from "./Stacker.sol";

abstract contract PleaFixture is Test {
    uint256 constant START = 1791775740;
    uint256 constant SIGN_KEY = 0x12345;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    PLEA token;
    PLEA orphan;
    CabalGate gate;
    PleaDistributor distributor;
    PleaLaunch launch;
    PleaHook hook;
    TestAsset imd;
    TestAsset feeToken;
    TestSIMD simd;
    MockIntake intake;
    Stacker stacker;
    PoolManager manager;
    MineSalt miner;
    bytes code;
    bytes32 salt;

    function setUp() public virtual {
        vm.chainId(11155111);
        vm.warp(START - 1 days);
        // Constructor rehearsal runs before any fixed external dependency exists.
        token = new PLEA(address(this));
        gate = new CabalGate(address(token));
        distributor = new PleaDistributor(address(token), address(this));
        launch = new PleaLaunch(address(token), address(gate), address(distributor), START);
        orphan = new PLEA(address(this));
        // The actual v4 core implementation is constructed, never loaded with getCode.
        PoolManager implementation = new PoolManager(address(this));
        bytes memory runtime = address(implementation).code;
        // Relocate NoDelegateCall's immutable self-address along with the runtime. No opcode is changed.
        bytes32 original = bytes32(uint256(uint160(address(implementation))));
        bytes32 target = bytes32(uint256(uint160(Addresses.MANAGER)));
        for (uint256 i; i + 32 <= runtime.length; ++i) {
            bytes32 word;
            assembly ("memory-safe") { word := mload(add(add(runtime, 32), i)) }
            if (word == original) {
                assembly ("memory-safe") { mstore(add(add(runtime, 32), i), target) }
            }
        }
        vm.etch(Addresses.MANAGER, runtime);
        manager = PoolManager(Addresses.MANAGER);
        TestAsset asset = new TestAsset();
        vm.etch(Addresses.IMD, address(asset).code);
        vm.etch(Addresses.ORACLE_ASSET, address(asset).code);
        imd = TestAsset(Addresses.IMD);
        feeToken = TestAsset(Addresses.ORACLE_ASSET);
        simd = new TestSIMD(IERC20(address(imd)));
        Stacker stackerImplementation = new Stacker(IERC20(address(imd)), IStakedIMD(address(simd)));
        vm.etch(Addresses.STACKER, address(stackerImplementation).code);
        stacker = Stacker(Addresses.STACKER);
        vm.prank(address(stacker));
        imd.approve(address(simd), type(uint256).max);
        MockIntake intakeImplementation = new MockIntake();
        vm.etch(Addresses.INTAKE, address(intakeImplementation).code);
        intake = MockIntake(Addresses.INTAKE);
        TestOracleSigner signer = new TestOracleSigner(vm.addr(SIGN_KEY));
        vm.etch(Addresses.SIGNER, address(signer).code);
        miner = new MineSalt();
        code = miner.initcode(address(token), address(gate), address(this));
        (bool found, bytes32 mined,,) = miner.run(address(launch), keccak256(code), 0, 200_000);
        require(found, "salt not found");
        salt = mined;
        launch.deployHook(salt, code);
        hook = PleaHook(launch.hook());
        launch.seed();
        _fund(ALICE);
        _fund(BOB);
    }

    function _fund(address who) internal {
        imd.mint(who, 100_000 ether);
        feeToken.mint(who, 10 ether);
        vm.startPrank(who);
        imd.approve(address(gate), type(uint256).max);
        feeToken.approve(address(gate), type(uint256).max);
        token.approve(address(gate), type(uint256).max);
        vm.stopPrank();
    }

    function _limit() internal view returns (uint160) {
        return hook.plea0() ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1;
    }

    function _buy(address who, uint256 amount) internal returns (uint256 out) {
        uint160 limit = _limit();
        vm.prank(who);
        return gate.buy(amount, 1, limit);
    }

    function _afterLaunch() internal {
        vm.warp(hook.seededAt() + 90 minutes);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _submit(address who, uint256 amount) internal returns (uint256 id) {
        vm.prank(who);
        id = gate.submitSell(amount, "My rent is due; the rest stays with the Cabal.");
    }

    function _attestation(uint256 id, bool answer) internal view returns (OracleAttestation.Attestation memory a) {
        a.requestId = keccak256(abi.encode("oracle UUID", id));
        a.chainId = 1;
        a.questionHash = keccak256("resolved question, not knowable when asking");
        a.answer = abi.encode(answer);
        a.panelSize = 30;
        a.quorum = 17;
        a.agreed = 17;
        uint256 now_ = vm.getBlockTimestamp();
        a.issuedAt = uint64(now_);
        a.expiresAt = uint64(now_ + 1 hours);
    }

    function _sig(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGN_KEY, gate.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _verdict(uint256 id, bool yes) internal {
        OracleAttestation.Attestation memory a = _attestation(id, yes);
        (bool ok, bytes memory reason) = intake.deliver(gate.pleas(id).intakeId, a, _sig(a));
        if (!ok) {
            assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
        }
    }
}
