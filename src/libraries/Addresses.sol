// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

library Addresses {
    address internal constant MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address internal constant IMD = 0x2B69099E59b05901faA1DD164fabf098bf831E82;
    address internal constant STACKER = 0x293C7134Ab8f6Bf1D8fF44Ed806575f8F1bAF477;
    address internal constant INTAKE = 0x1397434cd35e8a9C8aC312A61D3A285EB31dea56;
    address internal constant ORACLE_ASSET = 0x44a1Cd38474FB1748400E7DEb5F8D786ccE3F89A;
    address internal constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    uint160 internal constant HOOK_FLAGS = (1 << 13) | (1 << 11) | (1 << 9) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2);
    uint160 internal constant HOOK_MASK = (1 << 14) - 1;
}
