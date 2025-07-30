// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Token Interface
 * @notice Interface for interacting with the Token contract, defining methods for merchant management and withdrawals.
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
 */
contract Share is ERC20, ReentrancyGuard {

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
     * @dev Initial value is 15%, adjustable via change proposals.
     */
    uint256 public majorityPercentage = 15;

    /**
     * @notice Structure for add merchant proposals.
     * @dev Contains voting status, power, quota, address, name, and deadline.
     */
    struct addProposal {
        bool voting;         // Whether the proposal is active for voting.
        uint256 votingPower; // Accumulated voting power.
        uint256 printQuota;  // Proposed minting quota.
        address merchantAddr;// Proposed merchant address.
        string merchantName; // Proposed merchant name.
        uint256 deadline;    // Proposal expiration timestamp.
    }

    /**
     * @notice Structure for modify merchant proposals.
     * @dev Contains voting status, power, quota, rebate, address, guardian, freeze status, and deadline.
     */
    struct modProposal {
        bool voting;          // Whether the proposal is active for voting.
        uint256 votingPower;  // Accumulated voting power.
        uint256 printQuota;   // Updated minting quota.
        uint256 spendingRebate;// Updated spending rebate rate.
        address merchantAddr; // Merchant address to modify.
        address newGuardian;  // New guardian address.
        bool isFreeze;        // Whether to freeze the merchant.
        uint256 deadline;     // Proposal expiration timestamp.
    }

    /**
     * @notice Structure for change majority percentage proposals.
     * @dev Contains voting status, power, new percentage, and deadline.
     */
    struct changeProposal {
        bool voting;         // Whether the proposal is active for voting.
        uint256 votingPower; // Accumulated voting power.
        uint256 newPercentage;// Proposed new majority percentage.
        uint256 deadline;    // Proposal expiration timestamp.
    }

    /**
     * @notice Structure for withdraw proposals.
     * @dev Contains voting status, power, token address, initiator, and deadline.
     */
    struct withdrawProposal {
        bool voting;         // Whether the proposal is active for voting.
        uint256 votingPower; // Accumulated voting power.
        address tokenAddr;   // Token to withdraw (address(0) for ETH).
        address initiator;   // Address that initiated the proposal.
        uint256 deadline;    // Proposal expiration timestamp.
    }

    /**
     * @notice The most recent add merchant proposal.
     * @dev Public for transparency and querying.
     */
    addProposal public recentAdd;

    /**
     * @notice The most recent modify merchant proposal.
     * @dev Public for transparency and querying.
     */
    modProposal public recentMod;

    /**
     * @notice The most recent change percentage proposal.
     * @dev Public for transparency and querying.
     */
    changeProposal public recentChange;

    /**
     * @notice The most recent withdraw proposal.
     * @dev Public for transparency and querying.
     */
    withdrawProposal public recentWithdraw;

    /**
     * @notice Current ID counter for add proposals.
     * @dev Increments with each new add proposal.
     */
    uint256 public currentAddID;

    /**
     * @notice Current ID counter for mod proposals.
     * @dev Increments with each new mod proposal.
     */
    uint256 public currentModID;

    /**
     * @notice Current ID counter for change proposals.
     * @dev Increments with each new change proposal.
     */
    uint256 public currentChangeID;

    /**
     * @notice Current ID counter for withdraw proposals.
     * @dev Increments with each new withdraw proposal.
     */
    uint256 public currentWithdrawID;

    /**
     * @notice Mapping to track if an address has voted on a specific add proposal ID.
     * @dev Nested mapping for proposal ID to voter address to voted status.
     */
    mapping(uint256 => mapping(address => bool)) public hasVotedAdd;

    /**
     * @notice Mapping to track if an address has voted on a specific mod proposal ID.
     * @dev Nested mapping for proposal ID to voter address to voted status.
     */
    mapping(uint256 => mapping(address => bool)) public hasVotedMod;

    /**
     * @notice Mapping to track if an address has voted on a specific change proposal ID.
     * @dev Nested mapping for proposal ID to voter address to voted status.
     */
    mapping(uint256 => mapping(address => bool)) public hasVotedChange;

    /**
     * @notice Mapping to track if an address has voted on a specific withdraw proposal ID.
     * @dev Nested mapping for proposal ID to voter address to voted status.
     */
    mapping(uint256 => mapping(address => bool)) public hasVotedWithdraw;

    /**
     * @notice Emitted when a new proposal is initiated.
     * @param proposalType The type of proposal (e.g., "Add").
     * @param id The ID of the proposal.
     * @param initiator The address that initiated the proposal.
     */
    event ProposalInitiated(string proposalType, uint256 id, address initiator);

    /**
     * @notice Emitted when a vote is cast on a proposal.
     * @param proposalType The type of proposal (e.g., "Add").
     * @param id The ID of the proposal.
     * @param voter The address of the voter.
     * @param power The voting power contributed by the voter.
     */
    event Voted(string proposalType, uint256 id, address voter, uint256 power);

    /**
     * @notice Emitted when a proposal is successfully executed.
     * @param proposalType The type of proposal (e.g., "Add").
     * @param id The ID of the proposal.
     */
    event ProposalExecuted(string proposalType, uint256 id);

    /**
     * @notice Emitted when a proposal ends (executed or expired).
     * @param proposalType The type of proposal (e.g., "Add").
     * @param id The ID of the proposal.
     * @param executed True if executed, false if expired.
     */
    event ProposalEnded(string proposalType, uint256 id, bool executed);

    /**
     * @notice Initiates a new add merchant proposal.
     * @dev Requires the initiator to hold SHARE tokens and no active proposals. Optionally transfers TOKEN as quota deposit.
     * @param printQuota The proposed minting quota (optional deposit).
     * @param merchantAddr The proposed merchant address.
     * @param merchantName The proposed merchant name.
     */
    function initiateAdd(uint256 printQuota, address merchantAddr, string memory merchantName) external nonReentrant {
        require(balanceOf(_msgSender()) > 0, "Must hold Share tokens to initiate");
        require(!isAnyProposalActive(), "Ongoing proposal and not deadline yet");
        require(!isMerchant(merchantAddr), "Merchant already exists");
        ERC20 token = ERC20(TOKEN_ADDRESS);
        uint256 actualPrintQuota = 0;
        if (printQuota > 0) {
            if (token.allowance(_msgSender(), address(this)) >= printQuota && token.balanceOf(_msgSender()) >= printQuota) {
                token.transferFrom(_msgSender(), address(this), printQuota);
                actualPrintQuota = printQuota;
            }
        }
        if (recentAdd.voting && block.timestamp > recentAdd.deadline) {
            recentAdd.voting = false;
            emit ProposalEnded("Add", currentAddID, false);
        }
        currentAddID++;
        recentAdd.voting = true;
        recentAdd.votingPower = balanceOf(_msgSender());
        recentAdd.printQuota = actualPrintQuota;
        recentAdd.merchantAddr = merchantAddr;
        recentAdd.merchantName = merchantName;
        recentAdd.deadline = block.timestamp + PROPOSAL_DURATION;

        hasVotedAdd[currentAddID][_msgSender()] = true;
        emit ProposalInitiated("Add", currentAddID, _msgSender());
        emit Voted("Add", currentAddID, _msgSender(), balanceOf(_msgSender()));
        _checkAndExecuteAdd();
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
        require(balanceOf(_msgSender()) > 0, "Must hold Share tokens to initiate");
        require(!isAnyProposalActive(), "Ongoing proposal and not deadline yet");
        ERC20 token = ERC20(TOKEN_ADDRESS);
        uint256 actualPrintQuota = 0;
        if (printQuota > 0) {
            if (token.allowance(_msgSender(), address(this)) >= printQuota && token.balanceOf(_msgSender()) >= printQuota) {
                token.transferFrom(_msgSender(), address(this), printQuota);
                actualPrintQuota = printQuota;
            }
        }
        if (recentMod.voting && block.timestamp > recentMod.deadline) {
            recentMod.voting = false;
            emit ProposalEnded("Mod", currentModID, false);
        }
        currentModID++;
        recentMod.voting = true;
        recentMod.votingPower = balanceOf(_msgSender());
        recentMod.printQuota = actualPrintQuota;
        recentMod.spendingRebate = spendingRebate;
        recentMod.merchantAddr = merchantAddr;
        recentMod.newGuardian = newGuardian;
        recentMod.isFreeze = isFreeze;
        recentMod.deadline = block.timestamp + PROPOSAL_DURATION;

        hasVotedMod[currentModID][_msgSender()] = true;
        emit ProposalInitiated("Mod", currentModID, _msgSender());
        emit Voted("Mod", currentModID, _msgSender(), balanceOf(_msgSender()));
        _checkAndExecuteMod();
    }

    /**
     * @notice Initiates a new change majority percentage proposal.
     * @dev Requires the initiator to hold SHARE tokens and no active proposals.
     * @param newPercentage The proposed new majority percentage (1-30).
     */
    function initiateChange(uint256 newPercentage) external nonReentrant {
        require(balanceOf(_msgSender()) > 0, "Must hold Share tokens to initiate");
        require(!isAnyProposalActive(), "Ongoing proposal and not deadline yet");
        require(newPercentage > 0 && newPercentage <= 30, "Percentage must be between 1 and 100");
        if (recentChange.voting && block.timestamp > recentChange.deadline) {
            recentChange.voting = false;
            emit ProposalEnded("Change", currentChangeID, false);
        }
        currentChangeID++;
        recentChange.voting = true;
        recentChange.votingPower = balanceOf(_msgSender());
        recentChange.newPercentage = newPercentage;
        recentChange.deadline = block.timestamp + PROPOSAL_DURATION;

        hasVotedChange[currentChangeID][_msgSender()] = true;
        emit ProposalInitiated("Change", currentChangeID, _msgSender());
        emit Voted("Change", currentChangeID, _msgSender(), balanceOf(_msgSender()));
        _checkAndExecuteChange();
    }

    /**
     * @notice Initiates a new withdraw proposal.
     * @dev Requires the initiator to hold SHARE tokens and no active proposals.
     * @param tokenAddr The token to withdraw (address(0) for ETH).
     */
    function initiateWithdraw(address tokenAddr) external nonReentrant {
        require(balanceOf(_msgSender()) > 0, "Must hold Share tokens to initiate");
        require(!isAnyProposalActive(), "Ongoing proposal and not deadline yet");

        if (recentWithdraw.voting && block.timestamp > recentWithdraw.deadline) {
            recentWithdraw.voting = false;
            emit ProposalEnded("Withdraw", currentWithdrawID, false);
        }

        currentWithdrawID++;
        recentWithdraw.voting = true;
        recentWithdraw.votingPower = balanceOf(_msgSender());
        recentWithdraw.tokenAddr = tokenAddr;
        recentWithdraw.initiator = _msgSender();
        recentWithdraw.deadline = block.timestamp + PROPOSAL_DURATION;

        hasVotedWithdraw[currentWithdrawID][_msgSender()] = true;
        emit ProposalInitiated("Withdraw", currentWithdrawID, _msgSender());
        emit Voted("Withdraw", currentWithdrawID, _msgSender(), balanceOf(_msgSender()));
        _checkAndExecuteWithdraw();
    }

    /**
     * @notice Votes on the current add merchant proposal.
     * @dev Requires an active proposal, valid deadline, holder of SHARE tokens, and not already voted.
     */
    function voteAdd() external nonReentrant {
        require(recentAdd.voting, "No ongoing add proposal");
        require(block.timestamp <= recentAdd.deadline, "Proposal expired");
        require(balanceOf(_msgSender()) > 0, "Must hold Share tokens to vote");
        require(!hasVotedAdd[currentAddID][_msgSender()], "Already voted in this proposal");

        hasVotedAdd[currentAddID][_msgSender()] = true;
        recentAdd.votingPower += balanceOf(_msgSender());
        emit Voted("Add", currentAddID, _msgSender(), balanceOf(_msgSender()));
        _checkAndExecuteAdd();
    }

    /**
     * @notice Votes on the current modify merchant proposal.
     * @dev Requires an active proposal, valid deadline, holder of SHARE tokens, and not already voted.
     */
    function voteMod() external nonReentrant {
        require(recentMod.voting, "No ongoing mod proposal");
        require(block.timestamp <= recentMod.deadline, "Proposal expired");
        require(balanceOf(_msgSender()) > 0, "Must hold Share tokens to vote");
        require(!hasVotedMod[currentModID][_msgSender()], "Already voted in this proposal");

        hasVotedMod[currentModID][_msgSender()] = true;
        recentMod.votingPower += balanceOf(_msgSender());
        emit Voted("Mod", currentModID, _msgSender(), balanceOf(_msgSender()));
        _checkAndExecuteMod();
    }

    /**
     * @notice Votes on the current change percentage proposal.
     * @dev Requires an active proposal, valid deadline, holder of SHARE tokens, and not already voted.
     */
    function voteChange() external nonReentrant {
        require(recentChange.voting, "No ongoing change proposal");
        require(block.timestamp <= recentChange.deadline, "Proposal expired");
        require(balanceOf(_msgSender()) > 0, "Must hold Share tokens to vote");
        require(!hasVotedChange[currentChangeID][_msgSender()], "Already voted in this proposal");

        hasVotedChange[currentChangeID][_msgSender()] = true;
        recentChange.votingPower += balanceOf(_msgSender());
        emit Voted("Change", currentChangeID, _msgSender(), balanceOf(_msgSender()));
        _checkAndExecuteChange();
    }

    /**
     * @notice Votes on the current withdraw proposal.
     * @dev Requires an active proposal, valid deadline, holder of SHARE tokens, and not already voted.
     */
    function voteWithdraw() external nonReentrant {
        require(recentWithdraw.voting, "No ongoing withdraw proposal");
        require(block.timestamp <= recentWithdraw.deadline, "Proposal expired");
        require(balanceOf(_msgSender()) > 0, "Must hold Share tokens to vote");
        require(!hasVotedWithdraw[currentWithdrawID][_msgSender()], "Already voted in this proposal");

        hasVotedWithdraw[currentWithdrawID][_msgSender()] = true;
        recentWithdraw.votingPower += balanceOf(_msgSender());
        emit Voted("Withdraw", currentWithdrawID, _msgSender(), balanceOf(_msgSender()));
        _checkAndExecuteWithdraw();
    }

    /**
     * @notice Internal function to check and execute the add merchant proposal if threshold met.
     * @dev Called after votes; mints 0.1% SHARE to new merchant if passed.
     */
    function _checkAndExecuteAdd() internal {
        require(totalSupply() > 0, "Total supply zero");
        if (block.timestamp > recentAdd.deadline) {
            return; // Prevent execution if expired
        }
        uint256 threshold = (totalSupply() * majorityPercentage) / 100;
        if (recentAdd.votingPower >= threshold) {
            addMerchant(recentAdd.printQuota, recentAdd.merchantAddr, recentAdd.merchantName);
            recentAdd.voting = false;
            _mint(recentAdd.merchantAddr, totalSupply() / 1000); // mint 0.1% $share of the totalsupply to new merchant
            emit ProposalExecuted("Add", currentAddID);
            emit ProposalEnded("Add", currentAddID, true);
        }
    }

    /**
     * @notice Internal function to check and execute the modify merchant proposal if threshold met.
     * @dev Called after votes.
     */
    function _checkAndExecuteMod() internal {
        require(totalSupply() > 0, "Total supply zero");
        if (block.timestamp > recentMod.deadline) {
            return; // Prevent execution if expired
        }
        uint256 threshold = (totalSupply() * majorityPercentage) / 100;
        if (recentMod.votingPower >= threshold) {
            modMerchant(recentMod.merchantAddr, recentMod.newGuardian, recentMod.isFreeze, recentMod.printQuota, recentMod.spendingRebate);
            recentMod.voting = false;
            emit ProposalExecuted("Mod", currentModID);
            emit ProposalEnded("Mod", currentModID, true);
        }
    }

    /**
     * @notice Internal function to check and execute the change percentage proposal if threshold met.
     * @dev Called after votes; updates majorityPercentage.
     */
    function _checkAndExecuteChange() internal {
        require(totalSupply() > 0, "Total supply zero");
        if (block.timestamp > recentChange.deadline) {
            return; // Prevent execution if expired
        }
        uint256 threshold = (totalSupply() * majorityPercentage) / 100;
        if (recentChange.votingPower >= threshold) {
            majorityPercentage = recentChange.newPercentage;
            recentChange.voting = false;
            emit ProposalExecuted("Change", currentChangeID);
            emit ProposalEnded("Change", currentChangeID, true);
        }
    }

    /**
     * @notice Internal function to check and execute the withdraw proposal if threshold met.
     * @dev Called after votes; withdraws tokens/ETH to initiator.
     */
    function _checkAndExecuteWithdraw() internal {
        require(totalSupply() > 0, "Total supply zero");
        if (block.timestamp > recentWithdraw.deadline) {
            return; // Prevent execution if expired
        }
        uint256 threshold = (totalSupply() * majorityPercentage) / 100;
        if (recentWithdraw.votingPower >= threshold) {
            address token = recentWithdraw.tokenAddr;
            address initiator = recentWithdraw.initiator;
            IToken(TOKEN_ADDRESS).withdrawTokensAndETH(token);
            if (token == address(0)) {
                if (address(this).balance > 0) {
                    payable(initiator).transfer(address(this).balance);
                }
            } else {
                uint256 balance = IERC20(token).balanceOf(address(this));
                if (balance > 0) {
                    IERC20(token).transfer(initiator, balance);
                }
            }
            recentWithdraw.voting = false;
            emit ProposalExecuted("Withdraw", currentWithdrawID);
            emit ProposalEnded("Withdraw", currentWithdrawID, true);
        }
    }

    /**
     * @notice Internal function to call addMerchant on the Token contract.
     * @dev Delegates the call to the Token interface.
     * @param printQuota The minting quota.
     * @param merchantAddr The merchant address.
     * @param merchantName The merchant name.
     */
    function addMerchant(uint256 printQuota, address merchantAddr, string memory merchantName) internal {
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
    function modMerchant(address merchantAddr, address newGuardian, bool isFreeze, uint256 printQuota, uint256 spendingRebate) internal {
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
     * @dev View function checking all proposal types.
     * @return True if any active, false otherwise.
     */
    function isAnyProposalActive() public view returns (bool) {
        return (recentAdd.voting && block.timestamp <= recentAdd.deadline) ||
               (recentMod.voting && block.timestamp <= recentMod.deadline) ||
               (recentChange.voting && block.timestamp <= recentChange.deadline) ||
               (recentWithdraw.voting && block.timestamp <= recentWithdraw.deadline);
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
            require(!isAnyProposalActive(), "Transfers locked during active proposals");
        }
        super._update(from, to, value);
    }
}