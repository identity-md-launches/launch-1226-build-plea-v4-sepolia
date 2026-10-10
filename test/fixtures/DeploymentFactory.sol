// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Test-only analogue of the launch factory. Bytecode is calldata, so this helper respects EIP-170/3860.
contract DeploymentFactory {
    event Deployed(address indexed deployed);

    function deploy(bytes[] calldata initcodes) external returns (address[] memory deployed) {
        deployed = new address[](initcodes.length);
        for (uint256 i; i < initcodes.length; ++i) {
            bytes memory code = initcodes[i];
            address result;
            assembly ("memory-safe") { result := create(0, add(code, 32), mload(code)) }
            require(result != address(0), "constructor failed");
            deployed[i] = result;
            emit Deployed(result);
        }
    }
}
