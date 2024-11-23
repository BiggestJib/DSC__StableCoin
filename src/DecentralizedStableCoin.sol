// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ERC20Burnable, ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/*
 * @title DecentralizedStableCoin
 * @author Olaosebikan Ajibola
 * @Collateral: Exogenous (ETH & BTC) 
 * @Minting: Algorithms (ETH & BTC)
 * @Relative Stability: Pegged to USD
 * 
 * This contract implements an ERC20 token as part of the stablecoin system governed by DSCEngine.
 * It handles minting and burning functionalities with additional checks for stability.
 */

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    // Custom errors for more gas-efficient error handling
    error DecentralizedStableCoin_MustBeGreaterThanZero();
    error DecentralizedStableCoin_InsufficientBalance();
    error DecentralizedStableCoin_ZeroAddress();

    // Constructor to initialize the token name, symbol, and set ownership
    constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable(msg.sender) {}

    /**
     * @notice Burns a specific amount of tokens from the owner's account.
     * @dev Overrides the burn function in ERC20Burnable.
     * @param _amount The amount of tokens to burn.
     */
    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);

        // Validation checks
        if (_amount <= 0) {
            revert DecentralizedStableCoin_MustBeGreaterThanZero();
        }
        if (balance < _amount) {
            revert DecentralizedStableCoin_InsufficientBalance();
        }

        // Call the inherited burn function
        super.burn(_amount);
    }

    /**
     * @notice Mints a specific amount of tokens to the given address.
     * @dev Can only be called by the owner.
     * @param _to The address to receive the minted tokens.
     * @param _amount The amount of tokens to mint.
     * @return success True if the mint operation is successful.
     */
    function mint(address _to, uint256 _amount) external onlyOwner returns (bool success) {
        // Validation checks
        if (_to == address(0)) {
            revert DecentralizedStableCoin_ZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentralizedStableCoin_MustBeGreaterThanZero();
        }

        // Mint the specified amount of tokens to the specified address
        _mint(_to, _amount);
        return true;
    }
}
