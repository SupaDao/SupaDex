// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title GovernanceTimelock
/// @notice Timelock contract for governance-controlled operations
/// @dev Implements a timelock mechanism with proposal queue, voting, and execution
contract GovernanceTimelock is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    /// @notice Role for proposers who can create proposals
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    
    /// @notice Role for executors who can execute queued proposals
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    
    /// @notice Role for cancellers who can cancel proposals
    bytes32 public constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    
    /// @notice Role for the guardian who can perform emergency actions
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Role for voters (can be same as proposers or separate)
    bytes32 public constant VOTER_ROLE = keccak256("VOTER_ROLE");

    /// @notice Minimum delay before a proposal can be executed
    uint256 public minDelay;
    
    /// @notice Maximum delay before a proposal expires
    uint256 public constant MAX_DELAY = 30 days;
    
    /// @notice Grace period after which a proposal expires
    uint256 public constant GRACE_PERIOD = 14 days;

    /// @notice Proposal states
    enum ProposalState {
        Pending,
        Queued,
        Executed,
        Cancelled,
        Expired
    }

    /// @notice Proposal structure
    struct Proposal {
        bytes32 id;
        address proposer;
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        string description;
        uint256 timestamp;
        uint256 eta; // Estimated time of execution
        uint256 forVotes;
        uint256 againstVotes;
        ProposalState state;
        mapping(address => bool) hasVoted;
    }

    /// @notice Mapping of proposal ID to proposal
    mapping(bytes32 => Proposal) public proposals;
    
    bytes32[] public proposalIds;

    /// @notice Voting period in seconds
    uint256 public constant VOTING_PERIOD = 3 days;

    event VoteCast(address indexed voter, bytes32 indexed proposalId, bool support, uint256 weight);

    /// @notice Emitted when a proposal is created
    event ProposalCreated(
        bytes32 indexed id,
        address indexed proposer,
        address[] targets,
        uint256[] values,
        bytes[] calldatas,
        string description
    );

    /// @notice Emitted when a proposal is queued
    event ProposalQueued(bytes32 indexed id, uint256 eta);

    /// @notice Emitted when a proposal is executed
    event ProposalExecuted(bytes32 indexed id);

    /// @notice Emitted when a proposal is cancelled
    event ProposalCancelled(bytes32 indexed id);

    /// @notice Emitted when the minimum delay is updated
    event MinDelayUpdated(uint256 oldDelay, uint256 newDelay);

    /// @notice Emitted when a call is executed
    event CallExecuted(bytes32 indexed id, uint256 indexed index, address target, uint256 value, bytes data);

    error InvalidProposalLength();
    error ProposalNotFound(bytes32 id);
    error ProposalAlreadyQueued(bytes32 id);
    error ProposalNotQueued(bytes32 id);
    error ProposalNotReady(bytes32 id, uint256 eta);
    error ProposalExpired(bytes32 id);
    error ProposalAlreadyExecuted(bytes32 id);
    error InvalidDelay(uint256 delay);
    error ExecutionFailed(uint256 index);
    error Unauthorized(address caller);
    error AlreadyVoted(bytes32 id, address voter);
    error VotingClosed(bytes32 id);
    error Defeated(bytes32 id, uint256 forVotes, uint256 againstVotes);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the timelock contract
    /// @param _minDelay Minimum delay in seconds before execution
    /// @param admin Address to be granted admin role
    /// @param proposers Array of addresses to be granted proposer role
    /// @param executors Array of addresses to be granted executor role
    function initialize(
        uint256 _minDelay,
        address admin,
        address[] memory proposers,
        address[] memory executors
    ) external initializer {
        __AccessControl_init();
        
        if (_minDelay > MAX_DELAY) revert InvalidDelay(_minDelay);
        minDelay = _minDelay;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, admin);

        for (uint256 i = 0; i < proposers.length; i++) {
            _grantRole(PROPOSER_ROLE, proposers[i]);
            _grantRole(VOTER_ROLE, proposers[i]); // Proposers are also voters by default for this setup
        }

        for (uint256 i = 0; i < executors.length; i++) {
            _grantRole(EXECUTOR_ROLE, executors[i]);
        }
    }

    /// @notice Creates a new proposal
    /// @param targets Array of target addresses for calls
    /// @param values Array of ETH values for calls
    /// @param calldatas Array of calldata for calls
    /// @param description Human-readable description of the proposal
    /// @return proposalId The ID of the created proposal
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) external onlyRole(PROPOSER_ROLE) returns (bytes32 proposalId) {
        if (targets.length != values.length || targets.length != calldatas.length) {
            revert InvalidProposalLength();
        }
        if (targets.length == 0) revert InvalidProposalLength();

        proposalId = keccak256(abi.encode(targets, values, calldatas, keccak256(bytes(description))));

        if (proposals[proposalId].id != bytes32(0)) {
            revert ProposalAlreadyQueued(proposalId);
        }

        Proposal storage newProposal = proposals[proposalId];
        newProposal.id = proposalId;
        newProposal.proposer = msg.sender;
        newProposal.targets = targets;
        newProposal.values = values;
        newProposal.calldatas = calldatas;
        newProposal.description = description;
        newProposal.timestamp = block.timestamp;
        newProposal.eta = 0;
        newProposal.forVotes = 0;
        newProposal.againstVotes = 0;
        newProposal.state = ProposalState.Pending;

        proposalIds.push(proposalId);

        emit ProposalCreated(proposalId, msg.sender, targets, values, calldatas, description);
    }

    /// @notice Casts a vote on a proposal
    /// @param proposalId The ID of the proposal
    /// @param support using boolean: true = For, false = Against
    function castVote(bytes32 proposalId, bool support) external onlyRole(VOTER_ROLE) {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.id == bytes32(0)) revert ProposalNotFound(proposalId);
        if (proposal.state != ProposalState.Pending) revert ProposalNotQueued(proposalId); // Reusing error or add new one? Pending is correct for voting.
        if (block.timestamp > proposal.timestamp + VOTING_PERIOD) revert VotingClosed(proposalId);
        if (proposal.hasVoted[msg.sender]) revert AlreadyVoted(proposalId, msg.sender);

        proposal.hasVoted[msg.sender] = true;
        
        if (support) {
            proposal.forVotes += 1;
        } else {
            proposal.againstVotes += 1;
        }

        emit VoteCast(msg.sender, proposalId, support, 1);
    }

    /// @notice Queues a proposal for execution
    /// @param proposalId The ID of the proposal to queue
    function queue(bytes32 proposalId) external onlyRole(PROPOSER_ROLE) {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.id == bytes32(0)) revert ProposalNotFound(proposalId);
        if (proposal.state != ProposalState.Pending) revert ProposalAlreadyQueued(proposalId);
        
        // Check governance outcome
        if (block.timestamp <= proposal.timestamp + VOTING_PERIOD) revert VotingClosed(proposalId); // Actually wait for period end
        if (proposal.forVotes <= proposal.againstVotes) revert Defeated(proposalId, proposal.forVotes, proposal.againstVotes);

        uint256 eta = block.timestamp + minDelay;
        proposal.eta = eta;
        proposal.state = ProposalState.Queued;

        emit ProposalQueued(proposalId, eta);
    }

    /// @notice Executes a queued proposal
    /// @param proposalId The ID of the proposal to execute
    function execute(bytes32 proposalId) external payable onlyRole(EXECUTOR_ROLE) {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.id == bytes32(0)) revert ProposalNotFound(proposalId);
        if (proposal.state != ProposalState.Queued) revert ProposalNotQueued(proposalId);
        if (block.timestamp < proposal.eta) revert ProposalNotReady(proposalId, proposal.eta);
        if (block.timestamp > proposal.eta + GRACE_PERIOD) {
            proposal.state = ProposalState.Expired;
            revert ProposalExpired(proposalId);
        }

        proposal.state = ProposalState.Executed;

        for (uint256 i = 0; i < proposal.targets.length; i++) {
            (bool success, ) = proposal.targets[i].call{value: proposal.values[i]}(proposal.calldatas[i]);
            if (!success) revert ExecutionFailed(i);
            
            emit CallExecuted(proposalId, i, proposal.targets[i], proposal.values[i], proposal.calldatas[i]);
        }

        emit ProposalExecuted(proposalId);
    }

    /// @notice Cancels a proposal
    /// @param proposalId The ID of the proposal to cancel
    function cancel(bytes32 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.id == bytes32(0)) revert ProposalNotFound(proposalId);
        if (proposal.state == ProposalState.Executed) revert ProposalAlreadyExecuted(proposalId);
        
        // Only proposer or guardian can cancel
        if (msg.sender != proposal.proposer && !hasRole(GUARDIAN_ROLE, msg.sender)) {
            revert Unauthorized(msg.sender);
        }

        proposal.state = ProposalState.Cancelled;
        emit ProposalCancelled(proposalId);
    }

    /// @notice Updates the minimum delay
    /// @param newDelay The new minimum delay in seconds
    function updateDelay(uint256 newDelay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newDelay > MAX_DELAY) revert InvalidDelay(newDelay);
        
        uint256 oldDelay = minDelay;
        minDelay = newDelay;
        
        emit MinDelayUpdated(oldDelay, newDelay);
    }

    /// @notice Gets the state of a proposal
    /// @param proposalId The ID of the proposal
    /// @return The current state of the proposal
    function getProposalState(bytes32 proposalId) external view returns (ProposalState) {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.id == bytes32(0)) revert ProposalNotFound(proposalId);
        
        // Check if expired
        if (proposal.state == ProposalState.Queued && 
            block.timestamp > proposal.eta + GRACE_PERIOD) {
            return ProposalState.Expired;
        }
        
        return proposal.state;
    }

    /// @notice Gets the total number of proposals
    /// @return The number of proposals
    function getProposalCount() external view returns (uint256) {
        return proposalIds.length;
    }

    struct ProposalView {
        bytes32 id;
        address proposer;
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        string description;
        uint256 timestamp;
        uint256 eta;
        uint256 forVotes;
        uint256 againstVotes;
        ProposalState state;
    }

    /// @notice Gets proposal details
    /// @param proposalId The ID of the proposal
    /// @return The proposal struct (without mapping)
    function getProposal(bytes32 proposalId) external view returns (ProposalView memory) {
        Proposal storage proposal = proposals[proposalId];
        return ProposalView({
            id: proposal.id,
            proposer: proposal.proposer,
            targets: proposal.targets,
            values: proposal.values,
            calldatas: proposal.calldatas,
            description: proposal.description,
            timestamp: proposal.timestamp,
            eta: proposal.eta,
            forVotes: proposal.forVotes,
            againstVotes: proposal.againstVotes,
            state: proposal.state
        });
    }

    /// @notice Allows the contract to receive ETH
    receive() external payable {}

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[50] private __gap;
}
