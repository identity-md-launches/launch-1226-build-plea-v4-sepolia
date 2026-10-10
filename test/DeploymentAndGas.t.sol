// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PLEA} from "src/PLEA.sol";
import {CabalGate} from "src/CabalGate.sol";
import {PleaHook} from "src/PleaHook.sol";
import {PleaDistributor} from "src/PleaDistributor.sol";
import {PleaLaunch} from "src/PleaLaunch.sol";
import {Addresses} from "src/libraries/Addresses.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {DeploymentFactory} from "./fixtures/DeploymentFactory.sol";
import {TestAsset} from "./fixtures/Mocks.sol";
import {MineSalt} from "../script/MineSalt.s.sol";

contract DeploymentAndGasTest is Test {
    uint256 private constant START = 1791775740;
    uint256 private constant GAS_CEILING = 16_700_000;
    address private owner;
    PLEA private token;
    CabalGate private gate;
    PleaDistributor private distributor;
    PleaLaunch private launch;
    bytes private initcode;
    bytes32 private salt;

    function setUp() public {
        owner = makeAddr("application owner, distinct from factory");
    }

    function _intrinsic(bytes memory data) private pure returns (uint256 gas) {
        gas = 21_000;
        for (uint256 i; i < data.length; ++i) {
            gas += data[i] == 0 ? 4 : 16;
        }
    }

    function _underCeiling(address target, bytes memory data, string memory action) private returns (bytes memory) {
        uint256 intrinsic = _intrinsic(data);
        vm.cool(target);
        uint256 beforeGas = gasleft();
        (bool ok, bytes memory result) = target.call{gas: GAS_CEILING - intrinsic}(data);
        uint256 measured = beforeGas - gasleft() + intrinsic;
        assertTrue(ok, action);
        assertLt(measured, GAS_CEILING, action);
        emit log_named_uint(action, measured);
        return result;
    }

    function _applications() private {
        DeploymentFactory factory = new DeploymentFactory();
        token = PLEA(vm.computeCreateAddress(address(factory), 1));
        gate = CabalGate(vm.computeCreateAddress(address(factory), 2));
        distributor = PleaDistributor(vm.computeCreateAddress(address(factory), 3));
        launch = PleaLaunch(vm.computeCreateAddress(address(factory), 4));
        bytes[] memory codes = new bytes[](4);
        codes[0] = bytes.concat(type(PLEA).creationCode, abi.encode(owner));
        codes[1] = bytes.concat(type(CabalGate).creationCode, abi.encode(address(token)));
        codes[2] = bytes.concat(type(PleaDistributor).creationCode, abi.encode(address(token), owner));
        codes[3] = bytes.concat(
            type(PleaLaunch).creationCode, abi.encode(address(token), address(gate), address(distributor), START)
        );
        bytes memory result = _underCeiling(
            address(factory), abi.encodeCall(factory.deploy, (codes)), "atomic factory launch plus intrinsic gas"
        );
        address[] memory deployed = abi.decode(result, (address[]));
        assertEq(deployed[0], address(token));
        assertEq(deployed[1], address(gate));
        assertEq(deployed[2], address(distributor));
        assertEq(deployed[3], address(launch));
        assertEq(token.owner(), owner, "factory must not own token");
        assertEq(distributor.owner(), owner);
        assertEq(launch.owner(), owner);
        assertEq(token.launcher(), address(launch));
        assertEq(token.totalSupply(), 0, "mint only in init");
        assertEq(token.hook(), address(0));
        assertEq(token.gate(), address(0));
        assertEq(token.distributor(), address(0));
        assertEq(gate.intake(), Addresses.INTAKE);
        assertEq(gate.oracleAsset(), Addresses.ORACLE_ASSET);
        assertEq(gate.oracleSigner(), Addresses.SIGNER);
        initcode = bytes.concat(type(PleaHook).creationCode, abi.encode(address(token), address(gate), owner));
        assertEq(launch.hookInitcodeHash(), keccak256(initcode));
        MineSalt miner = new MineSalt();
        (bool found, bytes32 foundSalt, address predicted,) =
            miner.run(address(launch), keccak256(initcode), 0, 1_000_000);
        assertTrue(found);
        salt = foundSalt;
        assertEq(predicted, launch.predictHook(salt));
        assertEq(uint160(predicted) & Addresses.HOOK_MASK, Addresses.HOOK_FLAGS);
    }

    function _managerAndAsset() private {
        PoolManager implementation = new PoolManager(owner);
        bytes memory code = address(implementation).code;
        bytes32 original = bytes32(uint256(uint160(address(implementation))));
        bytes32 replacement = bytes32(uint256(uint160(Addresses.MANAGER)));
        uint256 patched;
        for (uint256 i; i + 32 <= code.length; ++i) {
            bytes32 word;
            assembly ("memory-safe") { word := mload(add(add(code, 32), i)) }
            if (word == original) {
                assembly ("memory-safe") { mstore(add(add(code, 32), i), replacement) }
                ++patched;
            }
        }
        assertGt(patched, 0, "relocate immutable NoDelegateCall self address");
        vm.etch(Addresses.MANAGER, code);
        TestAsset asset = new TestAsset();
        vm.etch(Addresses.IMD, address(asset).code);
    }

    function _hookAndSeed() private {
        _underCeiling(
            address(launch), abi.encodeCall(launch.deployHook, (salt, initcode)), "CREATE2 hook plus intrinsic gas"
        );
        PleaHook h = PleaHook(launch.hook());
        assertEq(token.balanceOf(address(h)), 900_000_000 ether);
        assertEq(token.balanceOf(address(distributor)), 100_000_000 ether);
        assertEq(token.totalSupply(), token.SUPPLY());
        assertEq(address(h.MANAGER()), Addresses.MANAGER);
        vm.warp(START);
        vm.cool(address(token));
        vm.cool(address(h));
        vm.cool(Addresses.MANAGER);
        vm.cool(Addresses.IMD);
        _underCeiling(address(launch), abi.encodeCall(launch.seed, ()), "seed plus intrinsic gas");
        assertEq(h.seededAt(), START);
        assertEq(TestAsset(Addresses.IMD).balanceOf(Addresses.MANAGER), 0, "seed is PLEA only");
        assertEq(token.balanceOf(address(h)), 0);
        assertEq(token.balanceOf(Addresses.MANAGER) + h.totalBurned(), 900_000_000 ether);
        assertEq(h.launchFeeBps(), 7000);
    }

    function testFactoryRehearsalBeforeAnyExternalDependencyExists() public {
        assertEq(Addresses.MANAGER.code.length, 0);
        assertEq(Addresses.IMD.code.length, 0);
        assertEq(Addresses.STACKER.code.length, 0);
        assertEq(Addresses.INTAKE.code.length, 0);
        assertEq(Addresses.ORACLE_ASSET.code.length, 0);
        vm.chainId(11155111);
        vm.warp(START - 1 days);
        _applications();
        vm.expectRevert(CabalGate.NotReady.selector);
        gate.submitSell(1 ether, "Not initialized");
        vm.expectRevert(PleaLaunch.NotOpen.selector);
        launch.seed();
        _managerAndAsset();
        _hookAndSeed();
    }

    function testImmutableInitcodeArgumentsAndAllHookBitsAreEnforced() public {
        _applications();
        bytes memory wrongOwner =
            bytes.concat(type(PleaHook).creationCode, abi.encode(address(token), address(gate), address(this)));
        vm.expectRevert(PleaLaunch.InvalidInitcode.selector);
        launch.deployHook(salt, wrongOwner);
        vm.expectRevert(PleaLaunch.InvalidInitcode.selector);
        launch.deployHook(salt, bytes.concat(initcode, hex"00"));
        bytes32 wrong;
        while ((uint160(launch.predictHook(wrong)) & Addresses.HOOK_MASK) == Addresses.HOOK_FLAGS) {
            wrong = bytes32(uint256(wrong) + 1);
        }
        vm.expectRevert(PleaLaunch.InvalidSalt.selector);
        launch.deployHook(wrong, initcode);
        assertEq(token.totalSupply(), 0);
        assertEq(launch.hook(), address(0));
        assertEq(token.launcher(), address(launch));
        vm.expectRevert(PLEA.Unauthorized.selector);
        token.setLauncher(address(this));
    }

    function testMainnetForkDeploymentGasWithLocalSepoliaDependencies() public {
        string memory url = vm.envOr("PLEA_MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        // Optional: the verifier has no network. The block makes the local fork reproducible.
        uint256 forkBlock = vm.envOr("PLEA_MAINNET_FORK_BLOCK", uint256(26_161_700));
        vm.createSelectFork(url, forkBlock);
        assertEq(block.chainid, 1);
        vm.chainId(11155111);
        _applications();
        _managerAndAsset();
        _hookAndSeed();
    }
}
