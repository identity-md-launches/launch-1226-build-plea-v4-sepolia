// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import {PleaText} from "./libraries/PleaText.sol";

interface IDistributionToken {
    function hook() external view returns (address);
}

interface IDistributionHook {
    function recordDistribution(address trader, uint256 amount) external;
}

contract PleaDistributor {
    using SafeERC20 for IERC20;
    error Unauthorized();
    error InvalidClaim();
    error RootAlreadySet();
    event RootSet(bytes32 root);
    event Claimed(address indexed account, uint256 amount);
    IERC20 public immutable token;
    address public immutable owner;
    bytes32 public merkleRoot;
    mapping(address => bool) public claimed;

    constructor(address token_, address owner_) {
        if (token_ == address(0) || owner_ == address(0)) revert InvalidClaim();
        token = IERC20(token_);
        owner = owner_;
    }

    /// @notice Pure request renderer shared with the gate to keep all four deployments below EIP-170.
    function oracleBody(
        uint256 id,
        address seller,
        address gate,
        uint256 amount,
        uint256 score,
        string calldata text,
        uint256 originalId,
        string calldata originalText
    ) external pure returns (bytes memory) {
        return PleaText.body(id, seller, gate, amount, score, text, originalId, originalText);
    }

    function setMerkleRoot(bytes32 root) external {
        if (msg.sender != owner) revert Unauthorized();
        if (merkleRoot != bytes32(0)) revert RootAlreadySet();
        if (root == bytes32(0)) revert InvalidClaim();
        merkleRoot = root;
        emit RootSet(root);
    }

    /// @notice Standard double-hashed leaf: keccak256(bytes.concat(keccak256(abi.encode(account, amount)))).
    function claim(address account, uint256 amount, bytes32[] calldata proof) external {
        // Receipt changes the holding-time ledger, so its timing belongs to the recipient.
        if (msg.sender != account) revert Unauthorized();
        if (account == address(0) || amount == 0 || proof.length > 64 || claimed[account] || merkleRoot == bytes32(0)) {
            revert InvalidClaim();
        }
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, amount))));
        if (!MerkleProof.verifyCalldata(proof, merkleRoot, leaf)) revert InvalidClaim();
        claimed[account] = true;
        emit Claimed(account, amount);
        token.safeTransfer(account, amount);
        IDistributionHook(IDistributionToken(address(token)).hook()).recordDistribution(account, amount);
    }
}
