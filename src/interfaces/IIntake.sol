// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }
    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32 requestId);
    function requests(bytes32 id)
        external
        view
        returns (address payer, address callbackTarget, bytes4 callbackSelector, bool completed);
}

interface IStacker {
    function credit(address trader, uint256 imdAmount) external returns (uint256 shares);
}
