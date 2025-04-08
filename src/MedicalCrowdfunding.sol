// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {MedicalVerifier} from "./MedicalVerifier.sol";
import {PriceConverter} from "./PriceConverter.sol";

contract MedicalCrowdfunding is ReentrancyGuard {
    error MedicalCrowdfunding__NotOwner();
    error MedicalCrowdfunding__SelfieVerificationRequired();
    error MedicalCrowdfunding__InvalidTargetAmount();
    error MedicalCrowdfunding__HospitalConfirmationRequired();
    error MedicalCrowdfunding__GuardianIDRequired();
    error MedicalCrowdfunding__GuardianRelationProofRequired();
    error MedicalCrowdfunding__DoctorLetterRequired();
    error MedicalCrowdfunding__MedicalReportRequired();
    error MedicalCrowdfunding__ProofOfResidenceRequired();
    error MedicalCrowdfunding__GovernmentIDRequired();
    error MedicalCrowdfunding__CampaignNotPending();
    error MedicalCrowdfunding__NotApprovedVerifier();
    error MedicalCrowdfunding__CommentRequired();
    error MedicalCrowdfunding__VotingNotEnded();
    error MedicalCrowdfunding__CampaignNotActive();
    error MedicalCrowdfunding__NoParticipants();
    error MedicalCrowdfunding__NotAParticipant();
    error MedicalCrowdfunding__AlreadyClaimed();
    error MedicalCrowdfunding__InvalidPrice();
    error MedicalCrowdfunding__InvalidDonationAmount();
    error MedicalCrowdfunding__CampaignCompleted();
    error MedicalCrowdfunding__NotPatient();
    error MedicalCrowdfunding__AppealExceeded();
    error MedicalCrowdfunding__CampaignNotRejected();
    error MedicalCrowdfunding__MinimumAmountNotReached();
    error MedicalCrowdfunding__CampaignDurationPass();
    error MedicalCrowdfunding__TransferFailed();
    error MedicalCrowdfunding__NothingToClaim();
    error MedicalCrowdfunding__NotAValidVerifier();
    error MedicalCrowdfunding__InvalidFeePercentage();
    error MedicalCrowdfunding__FeeProposalNotAllowed();
    error MedicalCrowdfunding__AlreadyVoted();
    error MedicalCrowdfunding__VotingEnded();
    error MedicalCrowdfunding__FeeProposalAlreadyFinalized();
    error MedicalCrowdfunding__EmptyField();
    error MedicalCrowdfunding__CommentTooLong();

    using PriceConverter for uint256;
    using SafeERC20 for IERC20;

    // Campaign lifecycle states
    enum CampaignStatus {
        PENDING, // Waiting for verification
        APPROVED, // Approved but not yet active
        REJECTED, // Failed verification
        ACTIVE, // Accepting donations
        COMPLETED // Funding target met

    }

    struct FeeProposal {
        uint256 proposedFee; // New fee percentage (must be between 1 and 5)
        uint256 yesVotes;
        uint256 noVotes;
        uint256 votingEndTime; // Deadline for fee proposal voting
        bool executed;
    }

    // Patient-controlled data sharing permissions
    struct DocumentConsent {
        bool shareMedicalReport;
        bool shareDoctorsLetter;
        bool shareMedicalBills;
        bool shareAdmissionPapers;
        bool shareGovernmentID;
        bool shareSelfieVerification;
    }

    // Main campaign storage structure
    struct Campaign {
        // Core parameters
        address payable patient; // Beneficiary address
        address guardian; // Optional legal guardian
        uint256 AmountNeededUSD; // Target amount in USD (18 decimals)
        uint256 duration; // Campaign duration in seconds
        uint256 startTime; // Activation timestamp
        CampaignStatus status; // Current state
        DocumentConsent consent; // Data sharing permissions
        // Patient identification
        string fullName;
        string dateOfBirth;
        string contactInfo;
        string residenceLocation;
        // Donation tracking
        address[] donors; // List of contributor addresses
        string comment; // Required for negative votes
        // Medical documentation
        string medicalReport;
        string doctorsLetter;
        string medicalBills;
        string admissionPapers;
        // KYC documentation
        string governmentID;
        string proofOfResidence;
        string selfieVerification;
        // Guardian verification
        string guardianRelationProof;
        string guardianID;
        string hospitalConfirmation;
        // Voting system
        uint256 votingEndTime; // Deadline for verification votes
        uint256 healthYesVotes; // Votes from medical professionals
        uint256 healthNoVotes;
        uint256 daoYesVotes; // Votes from DAO members
        uint256 daoNoVotes;
        uint256 appealCount; // Number of times appealed (max 2)
        // Financial tracking
        uint256 donatedAmount; // Total ETH received
        uint256 totalFeeCollected; // Total platform fees
        uint256 healthFeePool; // Fee allocation for medical verifiers
        uint256 daoFeePool; // Fee allocation for DAO verifiers
        // Fee distribution tracking
        uint256 healthFeePerVerifier; // Cumulative fee per health verifier
        uint256 daoFeePerVerifier; // Cumulative fee per DAO verifier
        // Funding progress
        uint256 amountReceivedUSD; // USD value of donations received
        uint256 healthParticipantCount; // Unique health verifiers participated
        uint256 daoParticipantCount; // Unique DAO verifiers participated
        // Verifier tracking
        address[] healthVerifierAddresses; // Health professionals who voted
        address[] daoVerifierAddresses; // DAO members who voted
    }

    // System dependencies
    MedicalVerifier private immutable i_memberDAO; // Verifier registry
    address private immutable i_owner; // Contract owner
    AggregatorV3Interface private s_priceFeed; // Chainlink price feed

    // System configuration
    uint256 public defaultDuration; // Default campaign duration
    uint256 public s_campaignCount; // Total campaigns created
    uint256 public s_votingPeriod = 12 days; // Verification voting period
    uint256 public serviceFeePercentage = 3; // 3% fee on donations
    uint256 public constant MINIMUM_USD = 5 * 10 ** 18; // $5 minimum

    // --- State Variables for Fee Proposal Mechanism ---
    uint256 public constant FEE_PROPOSAL_INTERVAL = 120 days; // Proposal can be made only once every 4 months
    uint256 public feeVotingPeriod = 7 days; // Duration for fee proposal voting
    uint256 public feeProposalCount;
    uint256 public lastFeeProposalTimestamp; // Timestamp of the last fee proposal

    // Storage mappings
    mapping(uint256 => Campaign) public s_campaigns;
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public healthVoted; // [campaignId][appealCount][verifier]
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public daoVoted;
    mapping(uint256 => mapping(address => bool)) public healthParticipants; // Health verifiers eligible for fees
    mapping(uint256 => mapping(address => bool)) public daoParticipants; // DAO verifiers eligible for fees
    mapping(uint256 => mapping(address => uint256)) public healthClaimable;
    mapping(uint256 => mapping(address => uint256)) public healthClaimed;
    mapping(uint256 => mapping(address => uint256)) public daoClaimable;
    mapping(uint256 => mapping(address => uint256)) public daoClaimed;
    mapping(uint256 => FeeProposal) public feeProposals;
    mapping(uint256 => mapping(address => bool)) public feeProposalVoted;

    event CampaignCreated(uint256 indexed campaignId, address indexed patient);
    event CampaignStatusChanged(uint256 indexed campaignId, CampaignStatus newStatus);
    event VoteCast(uint256 campaignId, address voter, bool support, string comment);
    event AppealStarted(uint256 indexed campaignId, uint256 appealCount);
    event DonationReceived(uint256 indexed campaignId, address indexed donor, uint256 amountETH, uint256 feeETH);
    event FeeDistributed(address indexed receiver, uint256 indexed campaignId, uint256 amount);
    event ServiceFeeUpdated(uint256 newPercentage);
    event FeeProposalCreated(uint256 indexed proposalId, uint256 proposedFee, uint256 votingEndTime);
    event FeeProposalVoteCast(uint256 indexed proposalId, address indexed voter, bool support);
    event FeeProposalFinalized(uint256 indexed proposalId, uint256 newFee, bool approved);

    modifier onlyOwner() {
        if (msg.sender != i_owner) revert MedicalCrowdfunding__NotOwner();
        _;
    }

    constructor(address priceFeedAddress, uint256 _defaultDurationDays, address daoAddress) {
        i_owner = msg.sender;
        s_priceFeed = AggregatorV3Interface(priceFeedAddress);
        defaultDuration = _defaultDurationDays * 1 days;
        i_memberDAO = MedicalVerifier(daoAddress); // Verifier management contract
    }

    /// @notice Creates a new medical crowdfunding campaign
    /// @dev Enforces document requirements based on guardian presence
    function createCampaign(
    uint256 _AmountNeededUSD,
    uint256 _duration,
    string memory _comment,
    string memory _fullName,
    string memory _dateOfBirth,
    string memory _contactInfo,
    string memory _residenceLocation,
    string memory _medicalReport,
    string memory _doctorsLetter,
    string memory _medicalBills,
    string memory _admissionPapers,
    string memory _governmentID,
    string memory _proofOfResidence,
    string memory _selfieVerification,
    address _guardian,
    string memory _guardianRelationProof,
    string memory _guardianID,
    string memory _hospitalConfirmation,
    DocumentConsent memory _consent
) external nonReentrant returns (uint256) {
    // 1. Perform ALL external calls first (trim operations)
    string memory trimmedGovID = i_memberDAO.trim(_governmentID);
    string memory trimmedResidence = i_memberDAO.trim(_proofOfResidence);
    string memory trimmedMedicalReport = i_memberDAO.trim(_medicalReport);
    string memory trimmedDoctorLetter = i_memberDAO.trim(_doctorsLetter);
    string memory trimmedSelfie = i_memberDAO.trim(_selfieVerification);
    string memory trimmedGuardianProof = i_memberDAO.trim(_guardianRelationProof);
    string memory trimmedGuardianID = i_memberDAO.trim(_guardianID);
    string memory trimmedHospitalConfirm = i_memberDAO.trim(_hospitalConfirmation);
    string memory trimmedFullName = i_memberDAO.trim(_fullName);
    string memory trimmedDOB = i_memberDAO.trim(_dateOfBirth);
    string memory trimmedContact = i_memberDAO.trim(_contactInfo);
    string memory trimmedResidenceLoc = i_memberDAO.trim(_residenceLocation);
    string memory trimmedComment = i_memberDAO.trim(_comment);
    string memory trimmedMedicalBills = i_memberDAO.trim(_medicalBills);
    string memory trimmedAdmissionPapers = i_memberDAO.trim(_admissionPapers);

    // 2. Validate all inputs using pre-trimmed values
    if (_AmountNeededUSD == 0) revert MedicalCrowdfunding__InvalidTargetAmount();

    // Mandatory document checks
    if (bytes(trimmedGovID).length == 0) revert MedicalCrowdfunding__GovernmentIDRequired();
    if (bytes(trimmedResidence).length == 0) revert MedicalCrowdfunding__ProofOfResidenceRequired();
    if (bytes(trimmedMedicalReport).length == 0) revert MedicalCrowdfunding__MedicalReportRequired();
    if (bytes(trimmedDoctorLetter).length == 0) revert MedicalCrowdfunding__DoctorLetterRequired();

    // Guardian-dependent validations
    if (_guardian != address(0)) {
        if (bytes(trimmedGuardianProof).length == 0) revert MedicalCrowdfunding__GuardianRelationProofRequired();
        if (bytes(trimmedGuardianID).length == 0) revert MedicalCrowdfunding__GuardianIDRequired();
        if (bytes(trimmedHospitalConfirm).length == 0) revert MedicalCrowdfunding__HospitalConfirmationRequired();
    } else {
        if (bytes(trimmedSelfie).length == 0) revert MedicalCrowdfunding__SelfieVerificationRequired();
    }

    // Patient information validation
    if (bytes(trimmedFullName).length == 0) revert MedicalCrowdfunding__EmptyField();
    if (bytes(trimmedDOB).length == 0) revert MedicalCrowdfunding__EmptyField();
    if (bytes(trimmedContact).length == 0) revert MedicalCrowdfunding__EmptyField();
    if (bytes(trimmedResidenceLoc).length == 0) revert MedicalCrowdfunding__EmptyField();
    if (bytes(trimmedComment).length > 300) revert MedicalCrowdfunding__CommentTooLong();

    // 3. State changes AFTER all external calls and validations
    uint256 campaignId = s_campaignCount++;
    s_campaigns[campaignId] = Campaign({
        patient: payable(msg.sender),
        guardian: _guardian,
        AmountNeededUSD: _AmountNeededUSD * 1e18,
        duration: _duration == 0 ? defaultDuration : _duration * 1 days,
        startTime: 0,
        status: CampaignStatus.PENDING,
        consent: _consent,
        fullName: trimmedFullName,
        dateOfBirth: trimmedDOB,
        contactInfo: trimmedContact,
        residenceLocation: trimmedResidenceLoc,
        donors: new address[](0),
        comment: trimmedComment,
        medicalReport: trimmedMedicalReport,
        doctorsLetter: trimmedDoctorLetter,
        medicalBills: trimmedMedicalBills,
        admissionPapers: trimmedAdmissionPapers,
        governmentID: trimmedGovID,
        proofOfResidence: trimmedResidence,
        selfieVerification: trimmedSelfie,
        guardianRelationProof: trimmedGuardianProof,
        guardianID: trimmedGuardianID,
        hospitalConfirmation: trimmedHospitalConfirm,
        votingEndTime: block.timestamp + s_votingPeriod,
        healthYesVotes: 0,
        healthNoVotes: 0,
        daoYesVotes: 0,
        daoNoVotes: 0,
        appealCount: 0,
        donatedAmount: 0,
        totalFeeCollected: 0,
        healthFeePool: 0,
        daoFeePool: 0,
        healthFeePerVerifier: 0,
        daoFeePerVerifier: 0,
        amountReceivedUSD: 0,
        healthParticipantCount: 0,
        daoParticipantCount: 0,
        healthVerifierAddresses: new address[](0),
        daoVerifierAddresses: new address[](0)
    });

    emit CampaignCreated(campaignId, msg.sender);
    emit CampaignStatusChanged(campaignId, CampaignStatus.PENDING);

    return campaignId;
}

    /// @notice Allows verified participants to vote on campaign validity
    /// @dev Votes are tracked per appeal count to prevent double voting
// In MedicalCrowdfunding contract
function voteOnCampaign(uint256 campaignId, bool support, string memory comment) external nonReentrant {
    Campaign storage campaign = s_campaigns[campaignId];
    uint256 currentAppeal = campaign.appealCount;

    // 1. Perform all checks first
    if (campaign.status != CampaignStatus.PENDING) revert MedicalCrowdfunding__CampaignNotPending();
    if (block.timestamp > campaign.votingEndTime) revert MedicalCrowdfunding__VotingEnded();

    // 2. Make external calls upfront
    (MedicalVerifier.VerifierType verifierType, MedicalVerifier.ApplicationStatus status,,) =
        i_memberDAO.verifiers(msg.sender);
    string memory processedComment = i_memberDAO.trim(comment);

    // 3. Validate after external calls
    if (status != MedicalVerifier.ApplicationStatus.Approved) revert MedicalCrowdfunding__NotApprovedVerifier();
    if (!support) {
        if (bytes(processedComment).length == 0) revert MedicalCrowdfunding__CommentRequired();
        if (bytes(processedComment).length > 300) revert MedicalCrowdfunding__CommentTooLong();
    }

    //  State changes AFTER external interactions
    bool isHealth = verifierType == MedicalVerifier.VerifierType.HealthProfessional;
    bool isDAO = verifierType == MedicalVerifier.VerifierType.Dao ||
                verifierType == MedicalVerifier.VerifierType.AutoDao;

    if (isHealth) {
        if (healthVoted[campaignId][currentAppeal][msg.sender]) revert MedicalCrowdfunding__AlreadyVoted();
        healthVoted[campaignId][currentAppeal][msg.sender] = true;

        if (support) campaign.healthYesVotes++;
        else campaign.healthNoVotes++;

        if (!healthParticipants[campaignId][msg.sender]) {
            healthParticipants[campaignId][msg.sender] = true;
            campaign.healthParticipantCount++;
            campaign.healthVerifierAddresses.push(msg.sender);
        }
    } else if (isDAO) {
        if (daoVoted[campaignId][currentAppeal][msg.sender]) revert MedicalCrowdfunding__AlreadyVoted();
        daoVoted[campaignId][currentAppeal][msg.sender] = true;

        if (support) campaign.daoYesVotes++;
        else campaign.daoNoVotes++;

        if (!daoParticipants[campaignId][msg.sender]) {
            daoParticipants[campaignId][msg.sender] = true;
            campaign.daoParticipantCount++;
            campaign.daoVerifierAddresses.push(msg.sender);
        }
    } else {
        revert MedicalCrowdfunding__NotAValidVerifier();
    }

    emit VoteCast(campaignId, msg.sender, support, processedComment);

    // 5. Finalize if needed (still safe as votingEndTime check already passed)
    if (block.timestamp >= campaign.votingEndTime) {
        _finalizeCampaign(campaignId);
    }
}

    /// @notice Finalizes campaign status after voting period
    function finalizeCampaign(uint256 campaignId) external nonReentrant {
        Campaign storage campaign = s_campaigns[campaignId];
        if (block.timestamp < campaign.votingEndTime) revert MedicalCrowdfunding__VotingNotEnded();
        if (campaign.status != CampaignStatus.PENDING) revert MedicalCrowdfunding__CampaignNotPending();
        _finalizeCampaign(campaignId);
    }

    /// @dev Internal campaign finalization logic
    function _finalizeCampaign(uint256 campaignId) private {
        Campaign storage campaign = s_campaigns[campaignId];
        uint256 totalHealthVerifiers = i_memberDAO.currentHealthProfessionals();
        uint256 totalDAOVerifiers = i_memberDAO.currentManualDaoVerifiers() + i_memberDAO.currentAutoDaoVerifiers();

        // Approval requires:
        // - Minimum 30% verifier participation
        // - At least 60% approval from participants
        bool healthApproved = _checkApproval(campaign.healthYesVotes, campaign.healthNoVotes, totalHealthVerifiers);
        bool daoApproved = _checkApproval(campaign.daoYesVotes, campaign.daoNoVotes, totalDAOVerifiers);

        if (healthApproved && daoApproved) {
            campaign.status = CampaignStatus.ACTIVE;
            campaign.startTime = block.timestamp;
        } else {
            campaign.status = CampaignStatus.REJECTED;
        }
        emit CampaignStatusChanged(campaignId, campaign.status);
    }

    /// @dev Checks if voting results meet approval criteria
    function _checkApproval(uint256 yesVotes, uint256 noVotes, uint256 totalVerifiers) private pure returns (bool) {
        if (totalVerifiers == 0) return false;
        uint256 totalVotes = yesVotes + noVotes;
        uint256 participation = (totalVotes * 100) / totalVerifiers;
        uint256 approval = (yesVotes * 100) / totalVotes;
        return participation >= 30 && approval >= 60; // 30% participation, 60% approval
    }

    /// @notice Allows patient to appeal rejected campaigns (max 2 appeals)
    function appealCampaign(uint256 campaignId) external nonReentrant {
        Campaign storage campaign = s_campaigns[campaignId];
        if (msg.sender != campaign.patient) revert MedicalCrowdfunding__NotPatient();
        if (campaign.status != CampaignStatus.REJECTED) revert MedicalCrowdfunding__CampaignNotRejected();
        if (campaign.appealCount >= 2) revert MedicalCrowdfunding__AppealExceeded();

        campaign.appealCount++;
        // Reset vote counts for new appeal round
        campaign.healthYesVotes = 0;
        campaign.healthNoVotes = 0;
        campaign.daoYesVotes = 0;
        campaign.daoNoVotes = 0;
        campaign.status = CampaignStatus.PENDING;
        campaign.votingEndTime = block.timestamp + s_votingPeriod;

        emit AppealStarted(campaignId, campaign.appealCount);
        emit CampaignStatusChanged(campaignId, CampaignStatus.PENDING);
    }

    /// @notice Processes donations with fee distribution
    /// @dev Converts ETH to USD using Chainlink price feed
function donate(uint256 campaignId) external payable nonReentrant {
    Campaign storage campaign = s_campaigns[campaignId];
    if (campaign.status != CampaignStatus.ACTIVE) revert MedicalCrowdfunding__CampaignNotActive();

    // Validate donation amount
    uint256 usdAmount = msg.value.getConversionRate(s_priceFeed);
    if (usdAmount < MINIMUM_USD) revert MedicalCrowdfunding__MinimumAmountNotReached();
    if (campaign.amountReceivedUSD >= campaign.AmountNeededUSD) revert MedicalCrowdfunding__CampaignCompleted();
    if (block.timestamp >= campaign.startTime + campaign.duration) revert MedicalCrowdfunding__CampaignDurationPass();

    // Update campaign state
    campaign.amountReceivedUSD += usdAmount;
    campaign.donors.push(msg.sender);

    // Calculate fees using multiplication-first approach
    uint256 fee = (msg.value * serviceFeePercentage) / 100;

    // Distribute fees with combined multiplication/division
    uint256 healthFee = (msg.value * serviceFeePercentage * 30) / 10000; // 30% of 3% fee
    uint256 daoFee = (msg.value * serviceFeePercentage * 40) / 10000;    // 40% of 3% fee
    uint256 residual = fee - healthFee - daoFee;                         // Remaining 30%

    // Transfer net amount to patient
    uint256 netAmount = msg.value - fee;
    (bool patientSent,) = campaign.patient.call{value: netAmount}("");
    if (!patientSent) revert MedicalCrowdfunding__TransferFailed();

    // Send platform share
    (bool residualSent,) = i_owner.call{value: residual}("");
    if (!residualSent) revert MedicalCrowdfunding__TransferFailed();
    emit FeeDistributed(i_owner, campaignId, residual);

    // Update fee pools with precise calculations
    campaign.healthFeePool += healthFee;
    campaign.daoFeePool += daoFee;

    // Calculate per-verifier allocations using precise division
    if (campaign.healthParticipantCount > 0) {
        campaign.healthFeePerVerifier += healthFee / campaign.healthParticipantCount;
    }
    if (campaign.daoParticipantCount > 0) {
        campaign.daoFeePerVerifier += daoFee / campaign.daoParticipantCount;
    }

    campaign.totalFeeCollected += fee;
    emit DonationReceived(campaignId, msg.sender, msg.value, fee);
}

    /// @notice Allows health verifiers to claim accumulated fees
    function claimHealthFee(uint256 campaignId) external nonReentrant {
        Campaign storage campaign = s_campaigns[campaignId];
        if (!healthParticipants[campaignId][msg.sender]) revert MedicalCrowdfunding__NotAValidVerifier();

        // Calculate claimable amount based on cumulative fees and previous claims
        uint256 totalOwed = campaign.healthFeePerVerifier;
        uint256 alreadyClaimed = healthClaimed[campaignId][msg.sender];
        uint256 claimable = totalOwed - alreadyClaimed;

        if (claimable <= 0) revert MedicalCrowdfunding__NothingToClaim();

        // Update claimed amount and transfer
        healthClaimed[campaignId][msg.sender] = totalOwed;
        (bool sent,) = payable(msg.sender).call{value: claimable}("");
        if (!sent) revert MedicalCrowdfunding__TransferFailed();

        emit FeeDistributed(msg.sender, campaignId, claimable);
    }

    /// @notice Allows DAO verifiers to claim accumulated fees
    function claimDaoFee(uint256 campaignId) external nonReentrant {
        Campaign storage campaign = s_campaigns[campaignId];
        if (!daoParticipants[campaignId][msg.sender]) revert MedicalCrowdfunding__NotAValidVerifier();

        uint256 totalOwed = campaign.daoFeePerVerifier;
        uint256 alreadyClaimed = daoClaimed[campaignId][msg.sender];
        uint256 claimable = totalOwed - alreadyClaimed;

        if (claimable <= 0) revert MedicalCrowdfunding__NothingToClaim();

        daoClaimed[campaignId][msg.sender] = totalOwed;
        (bool sent,) = payable(msg.sender).call{value: claimable}("");
        if (!sent) revert MedicalCrowdfunding__TransferFailed();

        emit FeeDistributed(msg.sender, campaignId, claimable);
    }

    /// @notice Allows an approved verifier to propose a new service fee percentage.
    /// @dev The proposed fee must be between 1% and 5%, and proposals can only be made once every 4 months.
function proposeServiceFeeAdjustment(uint256 _proposedFee) external nonReentrant {
    // 1. Cache verification data FIRST
    (MedicalVerifier.VerifierType verifierType,
     MedicalVerifier.ApplicationStatus status,,) = i_memberDAO.verifiers(msg.sender);

    // 2. Validate using cached data
    bool isValidVerifier = (status == MedicalVerifier.ApplicationStatus.Approved) &&
        (verifierType == MedicalVerifier.VerifierType.HealthProfessional ||
         verifierType == MedicalVerifier.VerifierType.Dao ||
         verifierType == MedicalVerifier.VerifierType.AutoDao);

    if (!isValidVerifier) revert MedicalCrowdfunding__NotAValidVerifier();
    if (_proposedFee < 1 || _proposedFee > 5) revert MedicalCrowdfunding__InvalidFeePercentage();
    if (block.timestamp < lastFeeProposalTimestamp + FEE_PROPOSAL_INTERVAL) {
        revert MedicalCrowdfunding__FeeProposalNotAllowed();
    }

    // 3. Update state AFTER all external calls and validations
    lastFeeProposalTimestamp = block.timestamp; // Prevent reentrancy first

    feeProposals[feeProposalCount] = FeeProposal({
        proposedFee: _proposedFee,
        yesVotes: 0,
        noVotes: 0,
        votingEndTime: block.timestamp + feeVotingPeriod,
        executed: false
    });

    emit FeeProposalCreated(feeProposalCount, _proposedFee, block.timestamp + feeVotingPeriod);
    feeProposalCount++;
}

    /// @notice Allows an approved verifier to vote on an active fee proposal.
    /// @dev If the proposal’s voting period has ended, it is automatically finalized before accepting any vote.
function voteOnFeeProposal(uint256 proposalId, bool support) external nonReentrant {
    // 1. Make all external calls FIRST
    (MedicalVerifier.VerifierType verifierType,
     MedicalVerifier.ApplicationStatus status,,) = i_memberDAO.verifiers(msg.sender);

    // 2. Validate using cached data
    bool isValidVerifier = (status == MedicalVerifier.ApplicationStatus.Approved) &&
        (verifierType == MedicalVerifier.VerifierType.HealthProfessional ||
         verifierType == MedicalVerifier.VerifierType.Dao ||
         verifierType == MedicalVerifier.VerifierType.AutoDao);

    if (!isValidVerifier) revert MedicalCrowdfunding__NotAValidVerifier();

    FeeProposal storage proposal = feeProposals[proposalId];

    // 3. Check proposal state BEFORE any modifications
    if (block.timestamp >= proposal.votingEndTime && !proposal.executed) {
        _autoFinalizeFeeProposal(proposalId);
        revert MedicalCrowdfunding__VotingEnded();
    }

    // 4. Validate voting status
    if (feeProposalVoted[proposalId][msg.sender]) {
        revert MedicalCrowdfunding__AlreadyVoted();
    }

    // 5. State changes AFTER all external calls and validations
    feeProposalVoted[proposalId][msg.sender] = true; // Mark voted first

    if (support) {
        proposal.yesVotes++;
    } else {
        proposal.noVotes++;
    }

    emit FeeProposalVoteCast(proposalId, msg.sender, support);

    // 6. Final check after state changes
    if (block.timestamp >= proposal.votingEndTime && !proposal.executed) {
        _autoFinalizeFeeProposal(proposalId);
    }
}

    /// @dev Internal function to automatically finalize a fee proposal.
    function _autoFinalizeFeeProposal(uint256 proposalId) internal {
        FeeProposal storage proposal = feeProposals[proposalId];
        // Protect against multiple executions.
        if (proposal.executed) {
            revert MedicalCrowdfunding__FeeProposalAlreadyFinalized();
        }
        proposal.executed = true;
        bool approved = proposal.yesVotes > proposal.noVotes;
        // If approved, update the global service fee.
        if (approved) {
            serviceFeePercentage = proposal.proposedFee;
        }
        emit FeeProposalFinalized(proposalId, serviceFeePercentage, approved);
    }

    function getCampaignStatus(uint256 campaignId) public view returns (CampaignStatus) {
        return s_campaigns[campaignId].status;
    }

    // Add to MedicalCrowdfunding contract
    function getCampaignFinancials(uint256 campaignId)
        public
        view
        returns (uint256 donatedAmount, uint256 amountReceivedUSD)
    {
        Campaign storage campaign = s_campaigns[campaignId];
        return (campaign.donatedAmount, campaign.amountReceivedUSD);
    }

    function getAppealCount(uint256 campaignId) public view returns (uint256) {
        return s_campaigns[campaignId].appealCount;
    }

    function getFeeProposal(uint256 proposalId)
        public
        view
        returns (uint256 proposedFee, uint256 yesVotes, uint256 noVotes, uint256 votingEndTime, bool executed)
    {
        FeeProposal storage proposal = feeProposals[proposalId];
        return (proposal.proposedFee, proposal.yesVotes, proposal.noVotes, proposal.votingEndTime, proposal.executed);
    }
}
