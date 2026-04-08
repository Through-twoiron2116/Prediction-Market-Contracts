// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WrappedCollateral
 * @notice 1:1 wrapper around the underlying collateral (USDC) used internally
 *         by the NegRiskAdapter. Wrapping is restricted to the owner (adapter),
 *         but anyone can unwrap.
 *
 *         Why wrap? The NegRiskAdapter uses `splitPosition` on the CTF which
 *         requires the collateral to come from within the contract. Wrapping
 *         lets the adapter hold USDC under its own accounting while the CTF
 *         tracks the wrapped token.
 */
contract WrappedCollateral is ERC20 {
    using SafeERC20 for IERC20;

    address public immutable owner;
    IERC20 public immutable underlying;

    modifier onlyOwner() {
        require(msg.sender == owner, "WCol: not owner");
        _;
    }

    constructor(address _underlying, string memory _name, string memory _symbol)
        ERC20(_name, _symbol)
    {
        require(_underlying != address(0), "WCol: zero underlying");
        owner = msg.sender;
        underlying = IERC20(_underlying);
    }

    // =========================================================================
    // Owner-only
    // =========================================================================

    /**
     * @notice Pull `amount` of underlying from `from` and mint wrapped tokens to `to`.
     */
    function wrap(address from, address to, uint256 amount) external onlyOwner {
        underlying.safeTransferFrom(from, address(this), amount);
        _mint(to, amount);
    }

    /**
     * @notice Mint wrapped tokens without pulling underlying (for internal accounting).
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @notice Burn wrapped tokens from `from` without releasing underlying.
     */
    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }

    /**
     * @notice Transfer underlying to `to` (used when releasing fees/collateral).
     */
    function release(address to, uint256 amount) external onlyOwner {
        underlying.safeTransfer(to, amount);
    }

    // =========================================================================
    // Public
    // =========================================================================

    /**
     * @notice Burn caller's wrapped tokens and receive underlying 1:1.
     */
    function unwrap(address to, uint256 amount) external {
        _burn(msg.sender, amount);
        underlying.safeTransfer(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6; // USDC
    }
}
