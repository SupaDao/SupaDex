// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

/// @title UUPSUpgradeableBase
/// @notice Base contract for UUPS upgradeable contracts with role-based authorization
/// @dev All upgradeable contracts should inherit from this base
abstract contract UUPSUpgradeableBase is Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    /// @notice Role identifier for upgrade authorization
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Error thrown when upgrade is not authorized
    error UnauthorizedUpgrade(address caller);

    /// @notice Error thrown when implementation is invalid
    error InvalidImplementation(address implementation);

    /// @notice Emitted when contract is upgraded
    event Upgraded(address indexed implementation);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the base upgradeable contract
    /// @param admin The address that will be granted the DEFAULT_ADMIN_ROLE and UPGRADER_ROLE
    function __UUPSUpgradeableBase_init(address admin) internal onlyInitializing {
        __AccessControl_init();
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    /// @notice Authorizes an upgrade to a new implementation
    /// @dev Only addresses with UPGRADER_ROLE can authorize upgrades
    /// @param newImplementation Address of the new implementation contract
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        if (newImplementation == address(0)) {
            revert InvalidImplementation(newImplementation);
        }
        
        // Additional validation can be added here
        // For example, checking if the new implementation has the correct interface
        
        emit Upgraded(newImplementation);
    }

    /// @notice Returns the current implementation address
    /// @return The address of the current implementation
    function getImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
    }

    /// @notice Checks if an address has the upgrader role
    /// @param account The address to check
    /// @return True if the address has the upgrader role
    function isUpgrader(address account) external view returns (bool) {
        return hasRole(UPGRADER_ROLE, account);
    }

    /// @dev Storage gap for future upgrades
    /// @notice Reserved storage space to allow for layout changes in future versions
    uint256[50] private __gap;
}
