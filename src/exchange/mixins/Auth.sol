// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Auth
 * @notice Two-tier access control: admins can manage the system;
 *         operators can perform day-to-day exchange operations (matching orders, etc.).
 */
abstract contract Auth {
    // =========================================================================
    // Events
    // =========================================================================

    event NewAdmin(address indexed admin);
    event RemovedAdmin(address indexed admin);
    event NewOperator(address indexed operator);
    event RemovedOperator(address indexed operator);

    // =========================================================================
    // State
    // =========================================================================

    mapping(address => uint256) public admins;
    mapping(address => uint256) public operators;

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyAdmin() {
        require(admins[msg.sender] == 1, "Auth: not admin");
        _;
    }

    modifier onlyOperator() {
        require(operators[msg.sender] == 1, "Auth: not operator");
        _;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor() {
        admins[msg.sender] = 1;
        emit NewAdmin(msg.sender);
    }

    // =========================================================================
    // Admin Management
    // =========================================================================

    function addAdmin(address admin) external onlyAdmin {
        require(admins[admin] == 0, "Auth: already admin");
        admins[admin] = 1;
        emit NewAdmin(admin);
    }

    function removeAdmin(address admin) external onlyAdmin {
        require(admin != msg.sender, "Auth: cannot remove self");
        admins[admin] = 0;
        emit RemovedAdmin(admin);
    }

    function renounceAdmin() external onlyAdmin {
        admins[msg.sender] = 0;
        emit RemovedAdmin(msg.sender);
    }

    // =========================================================================
    // Operator Management
    // =========================================================================

    function addOperator(address operator) external onlyAdmin {
        require(operators[operator] == 0, "Auth: already operator");
        operators[operator] = 1;
        emit NewOperator(operator);
    }

    function removeOperator(address operator) external onlyAdmin {
        operators[operator] = 0;
        emit RemovedOperator(operator);
    }

    // =========================================================================
    // Views
    // =========================================================================

    function isAdmin(address account) external view returns (bool) {
        return admins[account] == 1;
    }

    function isOperator(address account) external view returns (bool) {
        return operators[account] == 1;
    }
}
