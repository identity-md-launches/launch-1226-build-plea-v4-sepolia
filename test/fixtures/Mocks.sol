// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IIntake} from "../../src/interfaces/IIntake.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";

contract TestAsset is ERC20 {
    constructor() ERC20("Test IMD", "TestIMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A paused ERC4626 vault and deliberately expensive first credit exercise the measured Sepolia budget.
contract TestSIMD is ERC4626 {
    bool public paused;
    mapping(address => bool) private registered;
    mapping(address => mapping(uint256 => uint256)) private firstCreditWork;
    constructor(IERC20 asset_) ERC20("Test staked IMD", "sIMD") ERC4626(asset_) {}

    function setPaused(bool value) external {
        paused = value;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        require(!paused, "TestSIMD paused");
        if (!registered[receiver]) {
            registered[receiver] = true;
            // 45 cold SSTOREs plus the real vault + Stacker work cost about 1.2M gas.
            for (uint256 i; i < 45; ++i) {
                firstCreditWork[receiver][i] = i + 1;
            }
        }
        return super.deposit(assets, receiver);
    }
}

contract MockIntake is IIntake {
    struct Request {
        address payer;
        address callbackTarget;
        bytes4 callbackSelector;
        bool completed;
    }
    mapping(bytes32 => Request) public requests;
    bytes public lastBody;
    bytes32 public lastAction;
    address public lastAsset;
    uint256 public lastAmount;
    uint256 private nonce;

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32 id)
    {
        require(msg.value == 0, "native");
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount));
        lastBody = body;
        lastAction = action;
        lastAsset = asset;
        lastAmount = amount;
        id = keccak256(abi.encode(msg.sender, ++nonce));
        requests[id] = Request(msg.sender, callback.target, callback.selector, false);
    }

    function completeWithoutVerdict(bytes32 id) external {
        requests[id].completed = true;
    }

    function deliver(bytes32 id, OracleAttestation.Attestation calldata a, bytes calldata sig)
        external
        returns (bool ok, bytes memory result)
    {
        Request storage r = requests[id];
        r.completed = true;
        uint256 stipend = 200_000;
        require(gasleft() >= stipend + stipend / 63 + 20_000, "callback gas short");
        (ok, result) = r.callbackTarget.call{gas: 200_000}(abi.encodeWithSelector(r.callbackSelector, id, a, sig));
    }
}

/// @dev Test-only ERC1271 shim at the fixed signer. Verifies real signatures without needing the production key.
contract TestOracleSigner {
    address public immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 digest, bytes calldata sig) external view returns (bytes4) {
        return ECDSA.recover(digest, sig) == signer ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @dev Only for RPC gas/state tests. Cryptographic correctness is covered by OracleConformance and PleaTest.
contract GasOracleSigner {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
}
