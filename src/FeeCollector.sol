// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {StrataxCalculations} from "./libraries/StrataxCalculations.sol";

/**
 * @title FeeCollector
 * @notice Contract for collecting and withdrawing ERC20 token fees
 * @dev Uses OpenZeppelin's upgradeable contracts pattern
 */
contract FeeCollector is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    /// @notice Stratax fee in basis points e.g., 5 for 0.05%
    uint256 public strataxFee;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when fees are collected
    /// @param token Address of the token collected
    /// @param from Address that sent the fees
    /// @param amount Amount of fees collected
    event FeesCollected(address indexed token, address indexed from, uint256 indexed amount);

    /// @notice Emitted when fees are withdrawn
    /// @param token Address of the token withdrawn
    /// @param to Address that received the fees
    /// @param amount Amount of fees withdrawn
    event FeesWithdrawn(address indexed token, address indexed to, uint256 indexed amount);

    /// @notice Emitted when the fee is updated
    /// @param newFee The new fee value
    /// @param oldFee The old fee value
    event FeeUpdated(uint256 indexed newFee, uint256 indexed oldFee);

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the FeeCollector contract
    /// @dev Can only be called once due to initializer modifier. The fee must be less than FEE_PRECISION
    /// @param _owner The address that will own the contract
    /// @param _strataxFee The initial Stratax fee in basis points
    function initialize(address _owner, uint256 _strataxFee) external initializer {
        __Ownable_init(_owner);
        require(_strataxFee < StrataxCalculations.FLASHLOAN_FEE_PREC, "Fee <= 10,000");
        strataxFee = _strataxFee;
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Collects fees by transferring tokens from sender to this contract
     * @dev Requires prior token approval. Reverts if amount is zero or token address is invalid
     * @param _token The ERC20 token address
     * @param _amount The amount of fees to collect
     */
    function collectFees(address _token, uint256 _amount) external {
        require(_amount > 0, "Amount must be greater than zero");
        require(_token != address(0), "Invalid token address");
        /// forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(_token).transferFrom(msg.sender, address(this), _amount);

        //TODO: track trading volume here

        emit FeesCollected(_token, msg.sender, _amount);
    }

    /**
     * @notice Withdraws all accumulated fees for a specific token
     * @dev Only callable by owner. Transfers entire balance to the owner
     * @param _token The ERC20 token address to withdraw
     */
    function withdrawFees(address _token) external onlyOwner {
        require(_token != address(0), "Invalid token address");

        uint256 balance = IERC20(_token).balanceOf(address(this));
        require(balance > 0, "No fees to withdraw");
        /// forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(_token).transfer(msg.sender, balance);

        emit FeesWithdrawn(_token, msg.sender, balance);
    }

    /**
     * @notice Sets a new Stratax fee
     * @dev Only callable by owner. New fee must be less than FEE_PRECISION
     * @param _newFee The new fee value in basis points
     */
    function setFee(uint256 _newFee) external onlyOwner {
        uint256 oldFee = strataxFee;
        require(_newFee < StrataxCalculations.FLASHLOAN_FEE_PREC, "Fee too large");
        strataxFee = _newFee;
        emit FeeUpdated(_newFee, oldFee);
    }

    /**
     * @notice Withdraws a specific amount of fees for a token
     * @dev Only callable by owner. Allows partial withdrawal of accumulated fees
     * @param _token The ERC20 token address to withdraw
     * @param _amount The amount to withdraw
     */
    function withdrawFees(address _token, uint256 _amount) external onlyOwner {
        require(_token != address(0), "Invalid token address");
        require(_amount > 0, "Amount must be greater than zero");

        uint256 balance = IERC20(_token).balanceOf(address(this));
        require(balance >= _amount, "Insufficient balance");

        bool success = IERC20(_token).transfer(msg.sender, _amount);
        require(success, "Transfer failed");

        emit FeesWithdrawn(_token, msg.sender, _amount);
    }

    /**
     * @notice Authorizes contract upgrades
     * @dev Required by UUPSUpgradeable - only allows owner to upgrade
     * @param newImplementation The address of the new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /*//////////////////////////////////////////////////////////////
                            STORAGE GAP
    //////////////////////////////////////////////////////////////*/

    /// @notice Storage gap for future upgrades
    /// @dev Reserves 50 storage slots for adding new state variables in future upgrades without affecting storage layout
    uint256[50] private __gap;
}
