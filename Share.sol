// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title Token Interface
 * @notice Interface for interacting with the Token contract, defining methods for merchant management and withdrawals.
 * @custom:security-contact hopeallgood.unadvised619@passinbox.com
 */
interface IToken {
    /**
     * @notice Adds a new merchant to the Token contract.
     * @param printQuota The initial minting quota for the merchant.
     * @param merchantAddr The address of the merchant.
     * @param merchantName The name of the merchant.
     */
    function addMerchant(uint256 printQuota, address merchantAddr, string memory merchantName) external;

    /**
     * @notice Modifies the state of an existing merchant.
     * @param merchantAddr The address of the merchant to modify.
     * @param newGuardian The new guardian address for the merchant.
     * @param isFreeze Whether to freeze the merchant.
     * @param printQuota The updated minting quota.
     * @param spendingRebate The updated spending rebate rate.
     */
    function modMerchantState(address merchantAddr, address newGuardian, bool isFreeze, uint256 printQuota, uint256 spendingRebate) external;

    /**
     * @notice Checks if an address is a registered merchant.
     * @param merchant The address to check.
     * @return True if the address is a merchant, false otherwise.
     */
    function isMerchant(address merchant) external view returns (bool);

    /**
     * @notice Withdraws tokens or ETH from the Token contract.
     * @param token The token address to withdraw (address(0) for ETH).
     */
    function withdrawTokensAndETH(address token) external;
}

/**
 * @title Share Governance Contract
 * @notice This contract implements a governance system using SHARE tokens for voting on proposals related to merchant management in the Token contract.
 * @dev Extends ERC20 for token functionality and ReentrancyGuard for security against reentrancy attacks. Proposals include adding/modifying merchants, changing majority percentage, and withdrawing funds.
 * @custom:security-contact hopeallgood.unadvised619@passinbox.com
 */
contract Share is ERC20, ReentrancyGuard {

    /**
     * @notice Custom error for when the caller must hold SHARE tokens.
     */
    error MustHoldShareTokens();

    /**
     * @notice Custom error for when there is an ongoing proposal not yet at deadline.
     */
    error OngoingProposal();

    /**
     * @notice Custom error for when the merchant already exists.
     */
    error MerchantAlreadyExists();

    /**
     * @notice Custom error for when the percentage is out of bounds.
     */
    error InvalidPercentage();

    /**
     * @notice Custom error for when there is no ongoing proposal of the specified type.
     */
    error NoOngoingProposal(string proposalType);

    /**
     * @notice Custom error for when the proposal has expired.
     */
    error ProposalExpired();

    /**
     * @notice Custom error for when the caller has already voted.
     */
    error AlreadyVoted();

    /**
     * @notice Custom error for when the total supply is zero.
     */
    error TotalSupplyZero();

    /**
     * @notice Custom error for transfers during active proposals.
     */
    error TransfersLocked();

    /**
     * @notice Custom error for when the proposal type does not match the requested data.
     */
    error WrongProposalType();

    /**
     * @notice Constructor to initialize the SHARE token.
     * @dev Mints 100,000,000 SHARE tokens to the deployer with the standard 18 decimals.
     */
    constructor() ERC20("Share", "SHARE") {
        _mint(_msgSender(), 100000000 * 10 ** decimals());
    }

    /**
     * @notice The fixed address of the Token contract.
     * @dev Hardcoded for security and simplicity.
     */
    address public constant TOKEN_ADDRESS = 0xa1B68A58B1943Ba90703645027a10F069770ED39;

    /**
     * @notice The duration for which a proposal remains active for voting.
     * @dev Set to 7 days.
     */
    uint256 public constant PROPOSAL_DURATION = 7 days;

    /**
     * @notice The percentage of total supply required for a proposal to pass.
     * @dev Initial value is 15%, adjustable via change proposals. Uses uint8 since value does not exceed 100.
     */
    uint8 public majorityPercentage = 15;

    /**
     * @notice Enum representing the type of a proposal.
     * @dev Used to identify the type of proposals: 0=None, 1=Add, 2=Mod, 3=Change, 4=Withdraw.
     */
    enum ProposalType { None, Add, Mod, Change, Withdraw }

    /**
     * @notice Mapping from proposal ID to its details (stored as bytes to hold serialized data).
     * @dev Allows storage of proposal details for historical queries. Data is serialized based on type.
     */
    mapping(uint256 => bytes) public proposalDetails;

    /**
     * @notice The ID of the currently active proposal (0 if none).
     * @dev Used to track the single active proposal at a time.
     */
    uint256 public currentProposalId;

    /**
     * @notice Indicates if there is currently an active proposal (false = none, true = ongoing).
     * @dev Tracks the status of the active proposal to prevent concurrent proposals.
     */
    bool public activeProposal;

    /**
     * @notice Mapping from proposal ID to its type.
     * @dev Allows quick identification of a proposal's type for historical queries.
     */
    mapping(uint256 => ProposalType) public proposalTypes;

    /**
     * @notice Mapping to track if an address has voted on a specific proposal ID.
     * @dev Nested mapping for proposal ID to voter address to voted status.
     */
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    /**
     * @notice Emitted when a new proposal is initiated.
     * @param proposalType The type of proposal (e.g., "Add").
     * @param id The ID of the proposal.
     * @param initiator The address that initiated the proposal.
     */
    event ProposalInitiated(string indexed proposalType, uint256 indexed id, address indexed initiator);

    /**
     * @notice Emitted when a vote is cast on a proposal.
     * @param proposalType The type of proposal (e.g., "Add").
     * @param id The ID of the proposal.
     * @param voter The address of the voter.
     * @param power The voting power contributed by the voter.
     */
    event Voted(string indexed proposalType, uint256 indexed id, address indexed voter, uint256 power);

    /**
     * @notice Emitted when a proposal is successfully executed.
     * @param proposalType The type of proposal (e.g., "Add").
     * @param id The ID of the proposal.
     */
    event ProposalExecuted(string indexed proposalType, uint256 indexed id);

    /**
     * @notice Emitted when a proposal ends (executed or expired).
     * @param proposalType The type of proposal (e.g., "Add").
     * @param id The ID of the proposal.
     * @param executed True if executed, false if expired.
     */
    event ProposalEnded(string indexed proposalType, uint256 indexed id, bool executed);

    /**
     * @notice Initiates a new add merchant proposal.
     * @dev Requires the initiator to hold SHARE tokens and no active proposals. Optionally transfers TOKEN as quota deposit.
     * @param printQuota The proposed minting quota (optional deposit).
     * @param merchantAddr The proposed merchant address.
     * @param merchantName The proposed merchant name.
     */
    function initiateAdd(uint256 printQuota, address merchantAddr, string memory merchantName) external nonReentrant {
        if (balanceOf(_msgSender()) == 0) revert MustHoldShareTokens();
        if (isAnyProposalActive()) revert OngoingProposal();
        if (isMerchant(merchantAddr)) revert MerchantAlreadyExists();
        ERC20 token = ERC20(TOKEN_ADDRESS);
        uint256 actualPrintQuota;
        if (printQuota > 0) {
            if (token.allowance(_msgSender(), address(this)) >= printQuota && token.balanceOf(_msgSender()) >= printQuota) {
                token.transferFrom(_msgSender(), address(this), printQuota);
                actualPrintQuota = printQuota;
            }
        }
        currentProposalId++;
        activeProposal = true;
        proposalDetails[currentProposalId] = abi.encode(true, balanceOf(_msgSender()), actualPrintQuota, merchantAddr, merchantName, block.timestamp + PROPOSAL_DURATION);
        proposalTypes[currentProposalId] = ProposalType.Add;
        hasVoted[currentProposalId][_msgSender()] = true;
        emit ProposalInitiated("Add", currentProposalId, _msgSender());
        emit Voted("Add", currentProposalId, _msgSender(), balanceOf(_msgSender()));
        _checkAndExecuteAdd(currentProposalId);
    }

    /**
     * @notice Initiates a new modify merchant proposal.
     * @dev Requires the initiator to hold SHARE tokens and no active proposals. Optionally transfers TOKEN as quota deposit.
     * @param merchantAddr The merchant address to modify.
     * @param newGuardian The new guardian address.
     * @param isFreeze Whether to freeze the merchant.
     * @param printQuota The updated minting quota (optional deposit).
     * @param spendingRebate The updated spending rebate rate.
     */
    function initiateMod(address merchantAddr, address newGuardian, bool isFreeze, uint256 printQuota, uint256 spendingRebate) external nonReentrant {
        if (balanceOf(_msgSender()) == 0) revert MustHoldShareTokens();
        if (isAnyProposalActive()) revert OngoingProposal();
        ERC20 token = ERC20(TOKEN_ADDRESS);
        uint256 actualPrintQuota;
        if (printQuota > 0) {
            if (token.allowance(_msgSender(), address(this)) >= printQuota && token.balanceOf(_msgSender()) >= printQuota) {
                token.transferFrom(_msgSender(), address(this), printQuota);
                actualPrintQuota = printQuota;
            }
        }
        currentProposalId++;
        activeProposal = true;
        proposalDetails[currentProposalId] = abi.encode(true, balanceOf(_msgSender()), actualPrintQuota, spendingRebate, merchantAddr, newGuardian, isFreeze, block.timestamp + PROPOSAL_DURATION);
        proposalTypes[currentProposalId] = ProposalType.Mod;
        hasVoted[currentProposalId][_msgSender()] = true;
        emit ProposalInitiated("Mod", currentProposalId, _msgSender());
        emit Voted("Mod", currentProposalId, _msgSender(), balanceOf(_msgSender()));
        _checkAndExecuteMod(currentProposalId);
    }

    /**
     * @notice Initiates a new change majority percentage proposal.
     * @dev Requires the initiator to hold SHARE tokens and no active proposals.
     * @param newPercentage The proposed new majority percentage (1-30). Uses uint8 since value does not exceed 100.
     */
    function initiateChange(uint8 newPercentage) external nonReentrant {
        if (balanceOf(_msgSender()) == 0) revert MustHoldShareTokens();
        if (isAnyProposalActive()) revert OngoingProposal();
        if (!(newPercentage > 0 && newPercentage <= 30)) revert InvalidPercentage();
        currentProposalId++;
        activeProposal = true;
        proposalDetails[currentProposalId] = abi.encode(true, block.timestamp + PROPOSAL_DURATION, balanceOf(_msgSender()), newPercentage);
        proposalTypes[currentProposalId] = ProposalType.Change;
        hasVoted[currentProposalId][_msgSender()] = true;
        emit ProposalInitiated("Change", currentProposalId, _msgSender());
        emit Voted("Change", currentProposalId, _msgSender(), balanceOf(_msgSender()));
        _checkAndExecuteChange(currentProposalId);
    }

    /**
     * @notice Initiates a new withdraw proposal.
     * @dev Requires the initiator to hold SHARE tokens and no active proposals.
     * @param tokenAddr The token to withdraw (address(0) for ETH).
     */
    function initiateWithdraw(address tokenAddr) external nonReentrant {
        if (balanceOf(_msgSender()) == 0) revert MustHoldShareTokens();
        if (isAnyProposalActive()) revert OngoingProposal();
        currentProposalId++;
        activeProposal = true;
        proposalDetails[currentProposalId] = abi.encode(true, balanceOf(_msgSender()), tokenAddr, _msgSender(), block.timestamp + PROPOSAL_DURATION);
        proposalTypes[currentProposalId] = ProposalType.Withdraw;
        hasVoted[currentProposalId][_msgSender()] = true;
        emit ProposalInitiated("Withdraw", currentProposalId, _msgSender());
        emit Voted("Withdraw", currentProposalId, _msgSender(), balanceOf(_msgSender()));
        _checkAndExecuteWithdraw(currentProposalId);
    }

    /**
     * @notice Votes on the current add merchant proposal.
     * @dev Requires an active proposal, valid deadline, holder of SHARE tokens, and not already voted.
     */
    function voteAdd() external nonReentrant {
        uint256 id = currentProposalId;
        if (proposalTypes[id] != ProposalType.Add) revert NoOngoingProposal("Add");
        bytes memory data = proposalDetails[id];
        (bool voting, uint256 votingPower, uint256 printQuota, address merchantAddr, string memory merchantName, uint256 deadline) = abi.decode(data, (bool, uint256, uint256, address, string, uint256));
        if (!voting) revert NoOngoingProposal("Add");
        if (block.timestamp > deadline) revert ProposalExpired();
        if (balanceOf(_msgSender()) == 0) revert MustHoldShareTokens();
        if (hasVoted[id][_msgSender()]) revert AlreadyVoted();
        hasVoted[id][_msgSender()] = true;
        votingPower += balanceOf(_msgSender());
        proposalDetails[id] = abi.encode(voting, votingPower, printQuota, merchantAddr, merchantName, deadline);
        emit Voted("Add", id, _msgSender(), balanceOf(_msgSender()));
        _checkAndExecuteAdd(id);
    }

    /**
     * @notice Votes on the current modify merchant proposal.
     * @dev Requires an active proposal, valid deadline, holder of SHARE tokens, and not already voted.
     */
    function voteMod() external nonReentrant {
        uint256 id = currentProposalId;
        if (proposalTypes[id] != ProposalType.Mod) revert NoOngoingProposal("Mod");
        bytes memory data = proposalDetails[id];
        (bool voting, uint256 votingPower, uint256 printQuota, uint256 spendingRebate, address merchantAddr, address newGuardian, bool isFreeze, uint256 deadline) = abi.decode(data, (bool, uint256, uint256, uint256, address, address, bool, uint256));
        if (!voting) revert NoOngoingProposal("Mod");
        if (block.timestamp > deadline) revert ProposalExpired();
        if (balanceOf(_msgSender()) == 0) revert MustHoldShareTokens();
        if (hasVoted[id][_msgSender()]) revert AlreadyVoted();
        hasVoted[id][_msgSender()] = true;
        votingPower += balanceOf(_msgSender());
        proposalDetails[id] = abi.encode(voting, votingPower, printQuota, spendingRebate, merchantAddr, newGuardian, isFreeze, deadline);
        emit Voted("Mod", id, _msgSender(), balanceOf(_msgSender()));
        _checkAndExecuteMod(id);
    }

    /**
     * @notice Votes on the current change percentage proposal.
     * @dev Requires an active proposal, valid deadline, holder of SHARE tokens, and not already voted.
     */
    function voteChange() external nonReentrant {
        uint256 id = currentProposalId;
        if (proposalTypes[id] != ProposalType.Change) revert NoOngoingProposal("Change");
        bytes memory data = proposalDetails[id];
        (bool voting, uint256 deadline, uint256 votingPower, uint8 newPercentage) = abi.decode(data, (bool, uint256, uint256, uint8));
        if (!voting) revert NoOngoingProposal("Change");
        if (block.timestamp > deadline) revert ProposalExpired();
        if (balanceOf(_msgSender()) == 0) revert MustHoldShareTokens();
        if (hasVoted[id][_msgSender()]) revert AlreadyVoted();
        hasVoted[id][_msgSender()] = true;
        votingPower += balanceOf(_msgSender());
        proposalDetails[id] = abi.encode(voting, deadline, votingPower, newPercentage);
        emit Voted("Change", id, _msgSender(), balanceOf(_msgSender()));
        _checkAndExecuteChange(id);
    }

    /**
     * @notice Votes on the current withdraw proposal.
     * @dev Requires an active proposal, valid deadline, holder of SHARE tokens, and not already voted.
     */
    function voteWithdraw() external nonReentrant {
        uint256 id = currentProposalId;
        if (proposalTypes[id] != ProposalType.Withdraw) revert NoOngoingProposal("Withdraw");
        bytes memory data = proposalDetails[id];
        (bool voting, uint256 votingPower, address tokenAddr, address initiator, uint256 deadline) = abi.decode(data, (bool, uint256, address, address, uint256));
        if (!voting) revert NoOngoingProposal("Withdraw");
        if (block.timestamp > deadline) revert ProposalExpired();
        if (balanceOf(_msgSender()) == 0) revert MustHoldShareTokens();
        if (hasVoted[id][_msgSender()]) revert AlreadyVoted();
        hasVoted[id][_msgSender()] = true;
        votingPower += balanceOf(_msgSender());
        proposalDetails[id] = abi.encode(voting, votingPower, tokenAddr, initiator, deadline);
        emit Voted("Withdraw", id, _msgSender(), balanceOf(_msgSender()));
        _checkAndExecuteWithdraw(id);
    }

    /**
     * @notice Internal function to check and execute the add merchant proposal if threshold met.
     * @dev Called after votes; mints 0.n% SHARE to new merchant if passed, where n is the current multiplier.
     * @param id The proposal ID.
     */
    function _checkAndExecuteAdd(uint256 id) private {
        if (totalSupply() == 0) revert TotalSupplyZero();
        bytes memory data = proposalDetails[id];
        (, uint256 votingPower, uint256 printQuota, address merchantAddr, string memory merchantName, uint256 deadline) = abi.decode(data, (bool, uint256, uint256, address, string, uint256));
        if (block.timestamp > deadline) {
            return; // Prevent execution if expired
        }
        uint256 threshold = (totalSupply() * majorityPercentage) / 100;
        if (votingPower >= threshold) {
            addMerchant(printQuota, merchantAddr, merchantName);
            proposalDetails[id] = abi.encode(false, votingPower, printQuota, merchantAddr, merchantName, deadline);
            activeProposal = false;
            emit ProposalExecuted("Add", id);
            emit ProposalEnded("Add", id, true);
        }
    }

    /**
     * @notice Internal function to check and execute the modify merchant proposal if threshold met.
     * @dev Called after votes.
     * @param id The proposal ID.
     */
    function _checkAndExecuteMod(uint256 id) private {
        if (totalSupply() == 0) revert TotalSupplyZero();
        bytes memory data = proposalDetails[id];
        (, uint256 votingPower, uint256 printQuota, uint256 spendingRebate, address merchantAddr, address newGuardian, bool isFreeze, uint256 deadline) = abi.decode(data, (bool, uint256, uint256, uint256, address, address, bool, uint256));
        if (block.timestamp > deadline) {
            return; // Prevent execution if expired
        }
        uint256 threshold = (totalSupply() * majorityPercentage) / 100;
        if (votingPower >= threshold) {
            modMerchant(merchantAddr, newGuardian, isFreeze, printQuota, spendingRebate);
            proposalDetails[id] = abi.encode(false, votingPower, printQuota, spendingRebate, merchantAddr, newGuardian, isFreeze, deadline);
            activeProposal = false;
            emit ProposalExecuted("Mod", id);
            emit ProposalEnded("Mod", id, true);
        }
    }

    /**
     * @notice Internal function to check and execute the change percentage proposal if threshold met.
     * @dev Called after votes; updates majorityPercentage and n if the proposal passes.
     * @param id The proposal ID.
     */
    function _checkAndExecuteChange(uint256 id) private {
        if (totalSupply() == 0) revert TotalSupplyZero();
        bytes memory data = proposalDetails[id];
        (, uint256 deadline, uint256 votingPower, uint8 newPercentage) = abi.decode(data, (bool, uint256, uint256, uint8));
        if (block.timestamp > deadline) {
            return; // Prevent execution if expired
        }
        uint256 threshold = (totalSupply() * majorityPercentage) / 100;
        if (votingPower >= threshold) {
            majorityPercentage = newPercentage;
            proposalDetails[id] = abi.encode(false, deadline, votingPower, newPercentage);
            activeProposal = false;
            emit ProposalExecuted("Change", id);
            emit ProposalEnded("Change", id, true);
        }
    }

    /**
     * @notice Internal function to check and execute the withdraw proposal if threshold met.
     * @dev Called after votes; withdraws tokens/ETH to initiator.
     * @param id The proposal ID.
     */
    function _checkAndExecuteWithdraw(uint256 id) private {
        if (totalSupply() == 0) revert TotalSupplyZero();
        bytes memory data = proposalDetails[id];
        (, uint256 votingPower, address tokenAddr, address initiator, uint256 deadline) = abi.decode(data, (bool, uint256, address, address, uint256));
        if (block.timestamp > deadline) {
            return; // Prevent execution if expired
        }
        uint256 threshold = (totalSupply() * majorityPercentage) / 100;
        if (votingPower >= threshold) {
            IToken(TOKEN_ADDRESS).withdrawTokensAndETH(tokenAddr);
            if (tokenAddr == address(0)) {
                if (address(this).balance > 0) {
                    Address.sendValue(payable(initiator), address(this).balance);
                }
            } else {
                uint256 balance = IERC20(tokenAddr).balanceOf(address(this));
                if (balance > 0) {
                    IERC20(tokenAddr).transfer(initiator, balance);
                }
            }
            proposalDetails[id] = abi.encode(false, votingPower, tokenAddr, initiator, deadline);
            activeProposal = false;
            emit ProposalExecuted("Withdraw", id);
            emit ProposalEnded("Withdraw", id, true);
        }
    }

    /**
     * @notice Internal function to call addMerchant on the Token contract.
     * @dev Delegates the call to the Token interface.
     * @param printQuota The minting quota.
     * @param merchantAddr The merchant address.
     * @param merchantName The merchant name.
     */
    function addMerchant(uint256 printQuota, address merchantAddr, string memory merchantName) private {
        IToken(TOKEN_ADDRESS).addMerchant(printQuota, merchantAddr, merchantName);
    }

    /**
     * @notice Internal function to call modMerchantState on the Token contract.
     * @dev Delegates the call to the Token interface.
     * @param merchantAddr The merchant address.
     * @param newGuardian The new guardian.
     * @param isFreeze Freeze status.
     * @param printQuota Updated quota.
     * @param spendingRebate Updated rebate.
     */
    function modMerchant(address merchantAddr, address newGuardian, bool isFreeze, uint256 printQuota, uint256 spendingRebate) private {
        IToken(TOKEN_ADDRESS).modMerchantState(merchantAddr, newGuardian, isFreeze, printQuota, spendingRebate);
    }

    /**
     * @notice Checks if an address is a merchant via the Token contract.
     * @dev View function delegating to Token interface.
     * @param merchant The address to check.
     * @return True if merchant, false otherwise.
     */
    function isMerchant(address merchant) public view returns (bool) {
        return IToken(TOKEN_ADDRESS).isMerchant(merchant);
    }

    /**
     * @notice Checks if any proposal is currently active.
     * @dev View function checking the active proposal's status.
     * @return True if active and not expired, false otherwise.
     */
    function isAnyProposalActive() public view returns (bool) {
        if (currentProposalId == 0) return false;
        bytes memory data = proposalDetails[currentProposalId];
        if (data.length == 0) return false;
        ProposalType pt = proposalTypes[currentProposalId];
        if (pt == ProposalType.Add) {
            (bool voting, , , , , uint256 deadline) = abi.decode(data, (bool, uint256, uint256, address, string, uint256));
            return voting && block.timestamp <= deadline;
        } else if (pt == ProposalType.Mod) {
            (bool voting, , , , , , , uint256 deadline) = abi.decode(data, (bool, uint256, uint256, uint256, address, address, bool, uint256));
            return voting && block.timestamp <= deadline;
        } else if (pt == ProposalType.Change) {
            (bool voting, uint256 deadline, ,) = abi.decode(data, (bool, uint256, uint256, uint8));
            return voting && block.timestamp <= deadline;
        } else if (pt == ProposalType.Withdraw) {
            (bool voting, , , , uint256 deadline) = abi.decode(data, (bool, uint256, address, address, uint256));
            return voting && block.timestamp <= deadline;
        }
        return false;
    }

    /**
     * @notice Returns the type of a proposal by ID.
     * @param id The proposal ID.
     * @return The ProposalType enum value.
     */
    function getProposalType(uint256 id) external view returns (ProposalType) {
        return proposalTypes[id];
    }

    /**
     * @notice Returns the add proposal data for a given ID.
     * @dev Reverts if the proposal is not of Add type.
     * @param id The proposal ID.
     * @return voting Whether active, votingPower Accumulated votes, printQuota Quota, merchantAddr Address, merchantName Name, deadline Expiration.
     */
    function getAddProposal(uint256 id) external view returns (bool voting, uint256 votingPower, uint256 printQuota, address merchantAddr, string memory merchantName, uint256 deadline) {
        if (proposalTypes[id] != ProposalType.Add) revert WrongProposalType();
        bytes memory data = proposalDetails[id];
        return abi.decode(data, (bool, uint256, uint256, address, string, uint256));
    }

    /**
     * @notice Returns the mod proposal data for a given ID.
     * @dev Reverts if the proposal is not of Mod type.
     * @param id The proposal ID.
     * @return voting Whether active, votingPower Accumulated votes, printQuota Quota, spendingRebate Rebate, merchantAddr Address, newGuardian Guardian, isFreeze Freeze status, deadline Expiration.
     */
    function getModProposal(uint256 id) external view returns (bool voting, uint256 votingPower, uint256 printQuota, uint256 spendingRebate, address merchantAddr, address newGuardian, bool isFreeze, uint256 deadline) {
        if (proposalTypes[id] != ProposalType.Mod) revert WrongProposalType();
        bytes memory data = proposalDetails[id];
        return abi.decode(data, (bool, uint256, uint256, uint256, address, address, bool, uint256));
    }

    /**
     * @notice Returns the change proposal data for a given ID.
     * @dev Reverts if the proposal is not of Change type.
     * @param id The proposal ID.
     * @return voting Whether active, deadline Expiration, votingPower Accumulated votes, newPercentage New percentage, newN New multiplier.
     */
    function getChangeProposal(uint256 id) external view returns (bool voting, uint256 deadline, uint256 votingPower, uint8 newPercentage) {
        if (proposalTypes[id] != ProposalType.Change) revert WrongProposalType();
        bytes memory data = proposalDetails[id];
        return abi.decode(data, (bool, uint256, uint256, uint8));
    }

    /**
     * @notice Returns the withdraw proposal data for a given ID.
     * @dev Reverts if the proposal is not of Withdraw type.
     * @param id The proposal ID.
     * @return voting Whether active, votingPower Accumulated votes, tokenAddr Token address, initiator Initiator, deadline Expiration.
     */
    function getWithdrawProposal(uint256 id) external view returns (bool voting, uint256 votingPower, address tokenAddr, address initiator, uint256 deadline) {
        if (proposalTypes[id] != ProposalType.Withdraw) revert WrongProposalType();
        bytes memory data = proposalDetails[id];
        return abi.decode(data, (bool, uint256, address, address, uint256));
    }

    /**
     * @notice Internal override for token transfers, locking during active proposals.
     * @dev Extends ERC20 _update to add transfer restrictions.
     * @param from Sender address.
     * @param to Recipient address.
     * @param value Amount to transfer.
     */
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            if (isAnyProposalActive()) revert TransfersLocked();
        }
        super._update(from, to, value);
    }
}
