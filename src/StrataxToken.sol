// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title StrataxToken
 * @notice Simple upgradeable ERC20 token for STRATAX
 */
contract StrataxToken is Initializable, ERC20Upgradeable, OwnableUpgradeable, UUPSUpgradeable {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the token and mints initial supply to owner
     * @param owner_ The token owner
     * @param initialSupply Initial token supply (18 decimals)
     */
    function initialize(address owner_, uint256 initialSupply) external initializer {
        require(owner_ != address(0), "Invalid owner");

        __ERC20_init("Stratax Token", "STRATAX");
        __Ownable_init(owner_);

        if (initialSupply > 0) {
            _mint(owner_, initialSupply);
        }
    }
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @notice Storage gap for future upgrades
    uint256[50] private __gap;
}
