// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PleaHook} from "../../src/PleaHook.sol";
import {Addresses} from "../../src/libraries/Addresses.sol";

contract HostileRouter {
    IPoolManager constant manager = IPoolManager(Addresses.MANAGER);
    PleaHook private hook;
    bytes private data;
    uint8 private mode;
    uint160 private limit;

    function pull(address token, address from, address to, uint256 amount) external {
        require(IERC20(token).transferFrom(from, to, amount));
    }

    function attack(PleaHook hook_, uint8 mode_, bytes calldata data_, uint160 limit_) external {
        hook = hook_;
        mode = mode_;
        data = data_;
        limit = limit_;
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        if (mode == 2) {
            manager.modifyLiquidity(
                hook.poolKey(),
                IPoolManager.ModifyLiquidityParams(hook.tickLower(), hook.tickUpper(), 100, bytes32(0)),
                ""
            );
            return "";
        }
        manager.sync(Currency.wrap(Addresses.IMD));
        require(IERC20(Addresses.IMD).transfer(address(manager), 10 ether));
        manager.settle();
        manager.swap(
            hook.poolKey(),
            IPoolManager.SwapParams(!hook.plea0(), mode == 3 ? int256(1 ether) : -int256(10 ether), limit),
            data
        );
        if (mode == 1) manager.mint(address(this), uint256(uint160(address(hook.token()))), 1);
        return "";
    }
}
