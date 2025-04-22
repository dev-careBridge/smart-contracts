// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {MedicalVerifier} from "./MedicalVerifier.sol";
import {PriceConverter} from "./PriceConverter.sol";

/**
 * @title Medical Crowdfunding Platform
 * @dev A secure contract for managing medical crowdfunding campaigns with document verification
 * and governance features.
 */
contract MedicalCrowdfunding is ReentrancyGuard {
    using PriceConverter for uint256;

    // Custom Errors
    error MedicalCrowdfunding__NotOwner();
    error MedicalCrowdfunding__PatientPhotoRequired();
    error MedicalCrowdfunding__InvalidTargetAmount();
    error MedicalCrowdfunding__GuardianIDRequired();
    error MedicalCrowdfunding__DoctorLetterRequired();
    error MedicalCrowdfunding__DiagnosisReportRequired();
    error MedicalCrowdfunding__ProofOfResidenceRequired();
    error MedicalCrowdfunding__GovernmentIDRequired();
    error MedicalCrowdfunding__CampaignNotPending();
    error MedicalCrowdfunding__NotApprovedVerifier();
    error MedicalCrowdfunding__CommentRequired();
    error MedicalCrowdfunding__CommentTooLong();
    error MedicalCrowdfunding__GuardianFullNameRequired();
    error MedicalCrowdfunding__MobileNumberRequired();
    error MedicalCrowdfunding__GuardianAddressRequired();
    error MedicalCrowdfunding__Invalid();
    error MedicalCrowdfunding__AlreadyVoted();
    error MedicalCrowdfunding__VotingEnded();
    error MedicalCrowdfunding__VotingNotEnded();
    error MedicalCrowdfunding__NotEnoughParticipants();
    error MedicalCrowdfunding__ApprovalThresholdNotMet();
    error MedicalCrowdfunding__OnlyRejectedCampaignsCanBeAppealed();
    error MedicalCrowdfunding__OnlyPatientCanAppeal();
    error MedicalCrowdfunding__MaxAppealsReached();
    error MedicalCrowdfunding__TransferFailed();
    error MedicalCrowdfunding__CampaignNotActive();
    error MedicalCrowdfunding__CampaignDurationPass();
    error MedicalCrowdfunding__MinimumAmountNotReached();
    error MedicalCrowdfunding__InvalidWithdrawAmount();
    error MedicalCrowdfunding__InvalidGuardian();
    error MedicalCrowdfunding__InvalidFeeRange();
    error MedicalCrowdfunding__AdjustmentCooldownNotMet();
    error MedicalCrowdfunding__VotingOngoing();
    error MedicalCrowdfunding__AlreadyExecuted();

    /// @notice Enum representing possible campaign states
    enum CampaignStatus {
        PENDING,
        APPROVED,
        REJECTED,
        ACTIVE,
        COMPLETED
    }

    struct Proposal {
        uint256 proposedFee;
        uint256 startTime;
        uint256 endTime;
        uint256 yesVotes;
        uint256 noVotes;
        bool executed;
    }

    /// @notice Structure defining document sharing consent preferences
    struct DocumentConsent {
        bool shareDiagnosisReport;
        bool shareDoctorsLetter;
        bool shareMedicalBills;
        bool shareAdmissionDoc;
        bool shareGovernmentID;
        bool sharePatientPhoto;
    }

    /// @notice Structure storing IPFS hashes for campaign documents
    struct CampaignDocuments {
        string diagnosisReportIPFS;
        string doctorsLetterIPFS;
        string medicalBillsIPFS;
        string admissionDocIPFS;
        string governmentIDIPFS;
        string patientPhotoIPFS;
    }

    /// @notice Structure containing guardian identification details
    struct GuardianDetails {
        address guardian;
        string guardianGovernmentID;
        string guardianFullName;
        string guardianMobileNumber;
        string guardianResidentialAddress;
    }

    /// @notice Structure containing patient personal information
    struct PatientDetails {
        string fullName;
        string dateOfBirth;
        string contactInfo;
        string residenceLocation;
    }

    /**
     * @notice Main campaign structure containing all crowdfunding details
     * @dev Includes nested structures for documents, voting data, and financial tracking
     */
    struct Campaign {
        // Core campaign parameters
        address payable patient;
        address guardian;
        uint256 AmountNeededUSD;
        uint256 duration;
        uint256 startTime;
        // Personal and medical information
        PatientDetails patientDetails;
        address[] donors;
        string comment;
        // Status and permissions
        CampaignStatus status;
        DocumentConsent consent;
        CampaignDocuments documents;
        GuardianDetails patientGuardian;
        // Governance and voting parameters
        uint256 votingEndTime;
        uint256 healthYesVotes;
        uint256 healthNoVotes;
        uint256 daoYesVotes;
        uint256 daoNoVotes;
        uint256 appealCount;
        // Financial tracking
        uint256 donatedAmount;
        uint256 totalFeeCollected;
        uint256 amountReceivedUSD;
        // Reward distribution parameters
        uint256 accHealthRewardPerShare;
        uint256 accDaoRewardPerShare;
        uint256 healthParticipantCount;
        uint256 daoParticipantCount;
        // Verification system state
        uint256 healthVerifierCountAtStart;
        uint256 daoVerifierCountAtStart;
        // Reward claim tracking
        mapping(uint256 => mapping(address => uint256)) healthClaimed;
        mapping(uint256 => mapping(address => uint256)) daoClaimed;
        address[] healthVerifiers;
        address[] daoVerifiers;
        mapping(address => bool) healthRewardCredited;
        mapping(address => bool) daoRewardCredited;
        mapping(address => uint256) healthLastAcc;
        mapping(address => uint256) daoLastAcc;
        bool feesDistributed;
    }

    // Contract state variables
    MedicalVerifier private immutable i_memberDAO;
    address private immutable i_owner;
    AggregatorV3Interface private s_priceFeed;
    uint256 public defaultDuration;
    uint256 public s_campaignCount;
    uint256 public s_votingPeriod = 12 days;
    uint256 public serviceFeePercentage = 150; // 1.5% in basis points
    uint256 public constant MINIMUM_USD = 5 * 10 ** 18;
    uint256 public constant MAX_COMMENT_LENGTH = 300;
    uint256 public lastProposalTime;
    uint256 public currentProposalId;

    mapping(uint256 => Campaign) public s_campaigns;
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public healthVoted;
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public daoVoted;
    mapping(uint256 => mapping(address => bool)) public healthParticipants;
    mapping(uint256 => mapping(address => bool)) public daoParticipants;
    mapping(address => uint256) public verifierFeePool;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    event CampaignCreated(uint256 indexed campaignId, address indexed patient);
    event CampaignStatusChanged(uint256 indexed campaignId, CampaignStatus newStatus);
    event VoteCast(uint256 indexed campaignId, address indexed verifier, bool support, string comment);
    event CampaignAppealed(uint256 indexed campaignId, uint256 appealCount, address indexed appellant);
    event DonationReceived(uint256 indexed campaignId, address donor, uint256 amount, uint256 fee);
    event FeesClaimed(address verifier, uint256 amount);
    event FeeProposalCreated(uint256 proposalId, uint256 proposedFee);
    event VoteCast(uint256 proposalId, address voter, bool support);
    event ProposalExecuted(uint256 proposalId, bool passed);

    modifier onlyOwner() {
        if (msg.sender != i_owner) revert MedicalCrowdfunding__NotOwner();
        _;
    }

    constructor(address priceFeedAddress, uint256 _defaultDurationDays, address daoAddress) {
        i_owner = msg.sender;
        s_priceFeed = AggregatorV3Interface(priceFeedAddress);
        defaultDuration = _defaultDurationDays * 1 days;
        i_memberDAO = MedicalVerifier(daoAddress);
    }

    /// @notice Creates a new medical crowdfunding campaign
    /// @dev Implements strict validation for campaign requirements
    function createCampaign(
        uint256 _AmountNeededUSD,
        uint256 _duration,
        string calldata _comment,
        PatientDetails calldata _patientDetails,
        DocumentConsent calldata _consent,
        CampaignDocuments calldata _documents,
        GuardianDetails calldata _patientGuardian
    ) external nonReentrant returns (uint256) {
        // Validate target amount
        if (_AmountNeededUSD <= MINIMUM_USD) {
            revert MedicalCrowdfunding__InvalidTargetAmount();
        }

        // Validate comment content
        if (bytes(i_memberDAO.trim(_comment)).length == 0) revert MedicalCrowdfunding__CommentRequired();
        if (bytes(i_memberDAO.trim(_comment)).length > MAX_COMMENT_LENGTH) revert MedicalCrowdfunding__CommentTooLong();

        // Validate patient information completeness
        if (bytes(i_memberDAO.trim(_patientDetails.fullName)).length == 0) revert MedicalCrowdfunding__Invalid();
        if (bytes(i_memberDAO.trim(_patientDetails.dateOfBirth)).length == 0) revert MedicalCrowdfunding__Invalid();
        if (bytes(i_memberDAO.trim(_patientDetails.contactInfo)).length == 0) revert MedicalCrowdfunding__Invalid();
        if (bytes(i_memberDAO.trim(_patientDetails.residenceLocation)).length == 0) {
            revert MedicalCrowdfunding__Invalid();
        }

        // Validate required medical documents
        _validateDocument(_documents.diagnosisReportIPFS, MedicalCrowdfunding__DiagnosisReportRequired.selector);
        _validateDocument(_documents.doctorsLetterIPFS, MedicalCrowdfunding__DoctorLetterRequired.selector);
        _validateDocument(_documents.governmentIDIPFS, MedicalCrowdfunding__GovernmentIDRequired.selector);
        _validateDocument(_documents.patientPhotoIPFS, MedicalCrowdfunding__PatientPhotoRequired.selector);

        // Handle guardian validation if provided
        if (_patientGuardian.guardian != address(0)) {
            _validateGuardianDetails(_patientGuardian);
        }

        // Create campaign
        uint256 campaignId = s_campaignCount++;
        Campaign storage campaign = s_campaigns[campaignId];

        // Initialize campaign parameters
        campaign.patient = payable(msg.sender);
        campaign.AmountNeededUSD = _AmountNeededUSD;
        campaign.duration = _duration == 0 ? defaultDuration : _duration;
        campaign.status = CampaignStatus.PENDING;
        campaign.startTime = block.timestamp;

        // Store patient information
        campaign.patientDetails = _patientDetails;
        campaign.documents = _documents;
        campaign.consent = _consent;

        // Store guardian info if applicable
        if (_patientGuardian.guardian != address(0)) {
            campaign.patientGuardian = _patientGuardian;
        }

        // Initialize verification parameters
        campaign.votingEndTime = block.timestamp + s_votingPeriod;
        campaign.healthVerifierCountAtStart = i_memberDAO.currentHealthProfessionals();
        campaign.daoVerifierCountAtStart =
            i_memberDAO.currentManualDaoVerifiers() + i_memberDAO.currentAutoDaoVerifiers();

        emit CampaignCreated(campaignId, msg.sender);
        emit CampaignStatusChanged(campaignId, CampaignStatus.PENDING);
        return campaignId;
    }

    /// @dev Internal validation for document presence
    function _validateDocument(string memory _document, bytes4 errorSelector) private pure {
        if (bytes(_document).length == 0) {
            if (errorSelector == MedicalCrowdfunding__DiagnosisReportRequired.selector) {
                revert MedicalCrowdfunding__DiagnosisReportRequired();
            } else if (errorSelector == MedicalCrowdfunding__DoctorLetterRequired.selector) {
                revert MedicalCrowdfunding__DoctorLetterRequired();
            } else if (errorSelector == MedicalCrowdfunding__GovernmentIDRequired.selector) {
                revert MedicalCrowdfunding__GovernmentIDRequired();
            } else if (errorSelector == MedicalCrowdfunding__PatientPhotoRequired.selector) {
                revert MedicalCrowdfunding__PatientPhotoRequired();
            } else if (errorSelector == MedicalCrowdfunding__GuardianIDRequired.selector) {
                revert MedicalCrowdfunding__GuardianIDRequired();
            } else if (errorSelector == MedicalCrowdfunding__GuardianAddressRequired.selector) {
                revert MedicalCrowdfunding__GuardianAddressRequired();
            } else if (errorSelector == MedicalCrowdfunding__MobileNumberRequired.selector) {
                revert MedicalCrowdfunding__MobileNumberRequired();
            } else {
                revert MedicalCrowdfunding__Invalid(); // Fallback error
            }
        }
    }

    /// @dev Comprehensive guardian detail validation
    function _validateGuardianDetails(GuardianDetails memory _patientGuardian) private view {
        if (_patientGuardian.guardian == msg.sender) revert MedicalCrowdfunding__InvalidGuardian();
        _validateDocument(_patientGuardian.guardianGovernmentID, MedicalCrowdfunding__GuardianIDRequired.selector);
        _validateDocument(
            _patientGuardian.guardianResidentialAddress, MedicalCrowdfunding__GuardianAddressRequired.selector
        );

        if (bytes(i_memberDAO.trim(_patientGuardian.guardianFullName)).length == 0) {
            revert MedicalCrowdfunding__GuardianFullNameRequired();
        }
        if (bytes(i_memberDAO.trim(_patientGuardian.guardianMobileNumber)).length == 0) {
            revert MedicalCrowdfunding__MobileNumberRequired();
        }
    }

    function voteOnCampaign(uint256 campaignId, bool support, string memory comment) external nonReentrant {
        Campaign storage campaign = s_campaigns[campaignId];
        uint256 currentAppeal = campaign.appealCount;

        if (campaign.status != CampaignStatus.PENDING) revert MedicalCrowdfunding__CampaignNotPending();

        if (block.timestamp > campaign.votingEndTime) revert MedicalCrowdfunding__VotingEnded();

        if (!i_memberDAO.isApprovedVerifier(msg.sender)) revert MedicalCrowdfunding__NotApprovedVerifier();

        (MedicalVerifier.VerifierType verifierType, MedicalVerifier.ApplicationStatus status,,) =
            i_memberDAO.verifiers(msg.sender);

        string memory processedComment = i_memberDAO.trim(comment);

        if (!support && bytes(processedComment).length == 0) revert MedicalCrowdfunding__CommentRequired();

        if (bytes(processedComment).length > 300) revert MedicalCrowdfunding__CommentTooLong();

        bool isHealth = verifierType == MedicalVerifier.VerifierType.HealthProfessional;

        bool isDAO =
            verifierType == MedicalVerifier.VerifierType.Dao || verifierType == MedicalVerifier.VerifierType.AutoDao;

        if (isHealth) {
            if (healthVoted[campaignId][currentAppeal][msg.sender]) revert MedicalCrowdfunding__AlreadyVoted();
            healthVoted[campaignId][currentAppeal][msg.sender] = true;

            if (support) campaign.healthYesVotes++;
            else campaign.healthNoVotes++;

            if (!healthParticipants[campaignId][msg.sender]) {
                campaign.healthParticipantCount++;
                healthParticipants[campaignId][msg.sender] = true;
                campaign.healthVerifiers.push(msg.sender);
                campaign.healthLastAcc[msg.sender] = campaign.accHealthRewardPerShare;
            }
        } else if (isDAO) {
            if (daoVoted[campaignId][currentAppeal][msg.sender]) revert MedicalCrowdfunding__AlreadyVoted();
            daoVoted[campaignId][currentAppeal][msg.sender] = true;

            if (support) campaign.daoYesVotes++;
            else campaign.daoNoVotes++;

            if (!daoParticipants[campaignId][msg.sender]) {
                campaign.daoParticipantCount++;
                daoParticipants[campaignId][msg.sender] = true;
                campaign.daoVerifiers.push(msg.sender);
                campaign.daoLastAcc[msg.sender] = campaign.accDaoRewardPerShare;
            }
        } else {
            revert MedicalCrowdfunding__NotApprovedVerifier();
        }

        emit VoteCast(campaignId, msg.sender, support, processedComment);

        // Auto-finalize if voting period has ended
        if (block.timestamp >= campaign.votingEndTime) {
            _finalizeCampaign(campaignId);
        }
    }

    function _ceilPercent(uint256 total, uint256 percent) internal pure returns (uint256) {
        require(percent <= 100, "Invalid percent");
        return (total * percent + 99) / 100;
    }

    function _checkApproval(uint256 yesVotes, uint256 noVotes, uint256 totalVerifiers) private pure returns (bool) {
        uint256 totalParticipants = yesVotes + noVotes;

        if (totalVerifiers == 0) return false;

        uint256 requiredParticipants = _ceilPercent(totalVerifiers, 30);

        if (totalParticipants < requiredParticipants) {
            return false;
        }

        if ((yesVotes * 100) / totalParticipants < 60) {
            return false;
        }

        return true;
    }

    function finalizeCampaign(uint256 campaignId) external {
        Campaign storage campaign = s_campaigns[campaignId];
        if (campaign.status != CampaignStatus.PENDING) {
            revert MedicalCrowdfunding__CampaignNotPending();
        }
        if (block.timestamp < campaign.votingEndTime) {
            revert MedicalCrowdfunding__VotingNotEnded();
        }
        _finalizeCampaign(campaignId);
    }

    /// @dev Internal campaign finalization logic
    function _finalizeCampaign(uint256 campaignId) private {
        Campaign storage campaign = s_campaigns[campaignId];
        uint256 totalHealthVerifiers = campaign.healthVerifierCountAtStart;
        uint256 totalDAOVerifiers = campaign.daoVerifierCountAtStart;

        // Check Health Professional approval
        bool healthApproved = _checkApproval(campaign.healthYesVotes, campaign.healthNoVotes, totalHealthVerifiers);

        // Check DAO approval (Manual + Auto)
        bool daoApproved = _checkApproval(campaign.daoYesVotes, campaign.daoNoVotes, totalDAOVerifiers);

        if (healthApproved && daoApproved) {
            campaign.status = CampaignStatus.ACTIVE;
            campaign.startTime = block.timestamp;
        } else {
            campaign.status = CampaignStatus.REJECTED;
        }
        emit CampaignStatusChanged(campaignId, campaign.status);
    }

    function appealCampaign(uint256 campaignId) external {
        Campaign storage campaign = s_campaigns[campaignId];

        if (campaign.status != CampaignStatus.REJECTED) {
            revert MedicalCrowdfunding__OnlyRejectedCampaignsCanBeAppealed();
        }

        if (msg.sender != campaign.patient) {
            revert MedicalCrowdfunding__OnlyPatientCanAppeal();
        }

        if (campaign.appealCount >= 2) {
            revert MedicalCrowdfunding__MaxAppealsReached();
        }

        campaign.appealCount += 1;
        campaign.status = CampaignStatus.PENDING;

        campaign.votingEndTime = block.timestamp + s_votingPeriod;

        emit CampaignAppealed(campaignId, campaign.appealCount, msg.sender);
    }

    function donate(uint256 campaignId) external payable nonReentrant {
        Campaign storage campaign = s_campaigns[campaignId];
        if (campaign.status != CampaignStatus.ACTIVE) {
            revert MedicalCrowdfunding__CampaignNotActive();
        }
        if (block.timestamp > campaign.startTime + campaign.duration) {
            revert MedicalCrowdfunding__CampaignDurationPass();
        }

        uint256 usdAmount = msg.value.getConversionRate(s_priceFeed);

        i_memberDAO.recordDonation(msg.sender, campaignId, usdAmount);

        if (usdAmount < MINIMUM_USD) {
            revert MedicalCrowdfunding__MinimumAmountNotReached();
        }

        campaign.donatedAmount += usdAmount;
        campaign.donors.push(msg.sender);

        if (campaign.donatedAmount >= campaign.AmountNeededUSD) {
            campaign.status = CampaignStatus.COMPLETED;
            emit CampaignStatusChanged(campaignId, CampaignStatus.COMPLETED);
        }

        uint256 fee = (msg.value * serviceFeePercentage) / 10000;
        uint256 healthFee = (fee * 30) / 100;
        uint256 daoFee = (fee * 40) / 100;
        uint256 ownerShare = fee - healthFee - daoFee;

        if (campaign.healthParticipantCount > 0) {
            uint256 perHealth = healthFee / campaign.healthParticipantCount;
            uint256 healthRemainder = healthFee % campaign.healthParticipantCount;
            campaign.accHealthRewardPerShare += perHealth;
            ownerShare += healthRemainder;
        }

        if (campaign.daoParticipantCount > 0) {
            uint256 perDao = daoFee / campaign.daoParticipantCount;
            uint256 daoRemainder = daoFee % campaign.daoParticipantCount;
            campaign.accDaoRewardPerShare += perDao;
            ownerShare += daoRemainder;
        }

        uint256 netAmount = msg.value - fee;

        (bool success,) = campaign.patient.call{value: netAmount}("");
        if (!success) {
            revert MedicalCrowdfunding__TransferFailed();
        }

        (success,) = i_owner.call{value: ownerShare}("");
        if (!success) {
            revert MedicalCrowdfunding__TransferFailed();
        }

        campaign.totalFeeCollected += fee;
        emit DonationReceived(campaignId, msg.sender, msg.value, fee);

        if (
            campaign.donatedAmount >= campaign.AmountNeededUSD
                || block.timestamp > campaign.startTime + campaign.duration
        ) {
            distributeVerifierFees(campaignId);
            campaign.status = CampaignStatus.COMPLETED;
            emit CampaignStatusChanged(campaignId, CampaignStatus.COMPLETED);
        }
    }

    function distributeVerifierFees(uint256 campaignId) internal {
        Campaign storage campaign = s_campaigns[campaignId];
        if (campaign.feesDistributed) return;
        campaign.feesDistributed = true;

        // Distribute health verifier fees
        for (uint256 i = 0; i < campaign.healthVerifiers.length; i++) {
            address verifier = campaign.healthVerifiers[i];
            uint256 pending = campaign.accHealthRewardPerShare - campaign.healthLastAcc[verifier];
            if (pending > 0) {
                verifierFeePool[verifier] += pending;
                campaign.healthLastAcc[verifier] = campaign.accHealthRewardPerShare;
            }
        }

        // Distribute DAO verifier fees
        for (uint256 i = 0; i < campaign.daoVerifiers.length; i++) {
            address verifier = campaign.daoVerifiers[i];
            uint256 pending = campaign.accDaoRewardPerShare - campaign.daoLastAcc[verifier];
            if (pending > 0) {
                verifierFeePool[verifier] += pending;
                campaign.daoLastAcc[verifier] = campaign.accDaoRewardPerShare;
            }
        }
    }

    function finalizeCampaignIfExpired(uint256 campaignId) external {
        Campaign storage campaign = s_campaigns[campaignId];

        if (campaign.status != CampaignStatus.ACTIVE) return;
        if (block.timestamp <= campaign.startTime + campaign.duration) return;

        distributeVerifierFees(campaignId);
        campaign.status = CampaignStatus.COMPLETED;
        emit CampaignStatusChanged(campaignId, CampaignStatus.COMPLETED);
    }

    function withdrawVerifierFees(uint256 withdrawAmount) external nonReentrant {
        uint256 balance = verifierFeePool[msg.sender];

        if (withdrawAmount == 0 || withdrawAmount > balance) {
            revert MedicalCrowdfunding__InvalidWithdrawAmount();
        }

        verifierFeePool[msg.sender] = balance - withdrawAmount;

        (bool success,) = msg.sender.call{value: withdrawAmount}("");
        if (!success) {
            revert MedicalCrowdfunding__TransferFailed();
        }

        emit FeesClaimed(msg.sender, withdrawAmount);
    }

    function proposeFeeAdjustment(uint256 _proposedFee) external {
        if (!i_memberDAO.isApprovedVerifier(msg.sender)) {
            revert MedicalCrowdfunding__NotApprovedVerifier();
        }
        if (_proposedFee < 100 || _proposedFee > 300) {
            revert MedicalCrowdfunding__InvalidFeeRange();
        }
        // Apply cooldown only if there's been a previous proposal
        if (lastProposalTime != 0 && block.timestamp < lastProposalTime + 90 days) {
            revert MedicalCrowdfunding__AdjustmentCooldownNotMet();
        }

        currentProposalId++;
        proposals[currentProposalId] = Proposal({
            proposedFee: _proposedFee,
            startTime: block.timestamp,
            endTime: block.timestamp + 14 days,
            yesVotes: 0,
            noVotes: 0,
            executed: false
        });

        lastProposalTime = block.timestamp;
        emit FeeProposalCreated(currentProposalId, _proposedFee);
    }

    function voteOnFeeAdjustment(uint256 proposalId, bool support) external {
        Proposal storage proposal = proposals[proposalId];

        if (!i_memberDAO.isApprovedVerifier(msg.sender)) revert MedicalCrowdfunding__NotApprovedVerifier();

        if (block.timestamp > proposal.endTime) {
            revert MedicalCrowdfunding__VotingEnded();
        }

        if (hasVoted[proposalId][msg.sender]) {
            revert MedicalCrowdfunding__AlreadyVoted();
        }

        hasVoted[proposalId][msg.sender] = true;

        if (support) {
            proposal.yesVotes++;
        } else {
            proposal.noVotes++;
        }

        emit VoteCast(proposalId, msg.sender, support);
    }

    function finalizeProposal(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];

        if (block.timestamp <= proposal.endTime) {
            revert MedicalCrowdfunding__VotingOngoing();
        }

        if (proposal.executed) {
            revert MedicalCrowdfunding__AlreadyExecuted();
        }

        proposal.executed = true;
        uint256 totalVerifiers = i_memberDAO.totalVerifiers();
        uint256 totalVotes = proposal.yesVotes + proposal.noVotes;

        bool passed = (totalVotes >= (totalVerifiers * 50) / 100) && (proposal.yesVotes >= (totalVotes * 70) / 100);

        if (passed) {
            serviceFeePercentage = proposal.proposedFee;
        }

        emit ProposalExecuted(proposalId, passed);
    }

    function getVerifierBalance(address verifier) external view returns (uint256) {
        return verifierFeePool[verifier];
    }

    /**
     * @notice Returns filtered campaign documents based on consent and permissions
     * @param _campaignId ID of campaign to query
     * @return filteredDocuments Struct with visible document hashes
     */
    function getCampaignDocuments(uint256 _campaignId)
        external
        view
        returns (CampaignDocuments memory filteredDocuments)
    {
        Campaign storage campaign = s_campaigns[_campaignId];
        bool isVerifier = i_memberDAO.isApprovedVerifier(msg.sender);

        return CampaignDocuments({
            diagnosisReportIPFS: isVerifier || campaign.consent.shareDiagnosisReport
                ? campaign.documents.diagnosisReportIPFS
                : "",
            doctorsLetterIPFS: isVerifier
                ? campaign.documents.doctorsLetterIPFS
                : (campaign.consent.shareDoctorsLetter ? campaign.documents.doctorsLetterIPFS : ""),
            medicalBillsIPFS: isVerifier
                ? campaign.documents.medicalBillsIPFS
                : (campaign.consent.shareMedicalBills ? campaign.documents.medicalBillsIPFS : ""),
            admissionDocIPFS: isVerifier
                ? campaign.documents.admissionDocIPFS
                : (campaign.consent.shareAdmissionDoc ? campaign.documents.admissionDocIPFS : ""),
            governmentIDIPFS: isVerifier
                ? campaign.documents.governmentIDIPFS
                : (campaign.consent.shareGovernmentID ? campaign.documents.governmentIDIPFS : ""),
            patientPhotoIPFS: isVerifier
                ? campaign.documents.patientPhotoIPFS
                : (campaign.consent.sharePatientPhoto ? campaign.documents.patientPhotoIPFS : "")
        });
    }

    function getCampaignStatus(uint256 campaignId) external view returns (CampaignStatus) {
        return s_campaigns[campaignId].status;
    }

    function getVotingEndTime(uint256 campaignId) public view returns (uint256) {
        return s_campaigns[campaignId].votingEndTime;
    }

    function getCurrentProposal() external view returns (Proposal memory) {
        return proposals[currentProposalId];
    }

    function getCampaign(uint256 id)
        public
        view
        returns (
            address patient,
            uint256 amountNeededUSD,
            uint256 donatedAmount,
            CampaignStatus status,
            uint256 healthYesVotes,
            uint256 healthNoVotes,
            bool feesDistributed
        )
    {
        Campaign storage c = s_campaigns[id];
        return (
            c.patient,
            c.AmountNeededUSD,
            c.donatedAmount,
            c.status,
            c.healthYesVotes,
            c.healthNoVotes,
            c.feesDistributed
        );
    }

    function getAppealCount(uint256 campaignId) public view returns (uint256) {
        return s_campaigns[campaignId].appealCount;
    }

    function timeUntilVotingEnd(uint256 proposalId) external view returns (uint256) {
        Proposal memory proposal = proposals[proposalId];
        return block.timestamp < proposal.endTime ? proposal.endTime - block.timestamp : 0;
    }
}
