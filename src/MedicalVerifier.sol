// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title MedicalVerifier
 * @dev ERC721-based verification system with strict CEI pattern adherence and governance features
 * Includes multi-tier verification system with Health Professionals, DAO members, and Genesis committee
 */
contract MedicalVerifier is ERC721, Ownable, ReentrancyGuard {
    // =============================================
    // Custom Errors
    // =============================================
    error MedicalVerifier__AlreadyApplied();
    error MedicalVerifier__ApprovedLimitReached();
    error MedicalVerifier__NoApplicationFound();
    error MedicalVerifier__NoActiveGenesisVerifiers();
    error MedicalVerifier__ApplicationAlreadyProcessed();
    error MedicalVerifier__NotApprovedVerifier();
    error MedicalVerifier__AlreadyVoted();
    error MedicalVerifier__InvalidProposal();
    error MedicalVerifier__VotingPeriodEnded();
    error MedicalVerifier__InvalidVerifierType();
    error MedicalVerifier__InsufficientDocuments();
    error MedicalVerifier__UnauthorizedRevocation();
    error MedicalVerifier__AlreadyHasNFT();
    error MedicalVerifier__UnauthorizedAccess();
    error MedicalVerifier__InvalidLimit();
    error MedicalVerifier__LimitOutOfBounds();
    error MedicalVerifier__SelfRevocationNotAllowed();
    error MedicalVerifier__ActiveRevocationProposalExists();
    error MedicalVerifier__StringTooLong(uint8 fieldId);
    error MedicalVerifier__EmptyField(uint8 fieldId);

    using Counters for Counters.Counter;

    /// @dev Tracks unique NFT token IDs for verifier credentials
    Counters.Counter private _tokenIds;

    /// @notice Enum defining types of verifiers in the system
    enum VerifierType {
        None, // Default state - not registered
        HealthProfessional, // Licensed medical practitioner
        Dao, // Community-elected DAO member
        AutoDao, // Automatically approved via donations
        Genesis // Initial governance committee

    }

    /// @notice Enum defining possible application states
    enum ApplicationStatus {
        Pending, // Under review
        Approved, // Accepted as verifier
        Rejected, // Application denied
        Revoked, // Membership terminated
        Withdrawn // Application withdrawn

    }

    /// @notice Structure for storing applicant documentation
    struct ApplicationDocs {
        string fullName; // Legal full name
        string contactInfo; // Contact information
        string governmentID; // Government-issued ID
        string professionalDocs; // Professional certifications
    }

    /// @notice Structure tracking verifier status and metadata
    struct Verifier {
        VerifierType verifierType; // Type of verifier
        ApplicationStatus status; // Current membership status
        ApplicationDocs docs; // Submitted documentation
        uint256 nftId; // Associated credential NFT ID
    }

    /// @notice Structure tracking proposal voting state
    struct ApplicationProposal {
        uint256 yesVotes; // Total affirmative votes
        uint256 noVotes; // Total negative votes
        uint256 genesisYesVotes; // Genesis committee approvals
        uint256 endTime; // Voting deadline
        bool exists;
        mapping(address => bool) voted; // Voter participation tracker
    }

    /// @notice Structure tracking revocation proposals
    struct RevocationProposal {
        uint256 yesVotes; // Votes for revocation
        uint256 noVotes; // Votes against revocation
        uint256 endTime; // Voting deadline
        bool exists;
        mapping(address => bool) voted; // Voter participation tracker
    }

    struct EmergencySettings {
        bool paused;
        uint256 pauseDuration;
        uint256 lastPauseTime;
    }

    // =============================================
    // Constants & Configuration
    // =============================================
    uint256 public constant VOTING_PERIOD = 7 days; // Default voting duration
    uint256 public constant APPROVAL_THRESHOLD = 60; // 60% required for approval
    uint256 public constant MIN_PARTICIPATION = 30; // 30% voter turnout required
    uint256 public constant MIN_DONATION = 30 * 10 ** 18; // 30 USD minimum donation
    uint256 public constant MIN_CAMPAIGNS_REQUIRED = 160; // Campaigns needed for AutoDAO
    uint256 public constant REVOCATION_COOLDOWN = 30 days; // Cooldown between revocation attempts
    uint256 public constant MAX_MISSED_VOTES = 10; // Max allowed missed votes
    uint256 public constant GENESIS_TIMEOUT = 90 days; // Maximum Genesis governance period
    uint256 public constant MAX_STRING_LENGTH = 56;

    // =============================================
    // State Variables
    // =============================================
    uint256 public maxHealthProfessionals = 20; // Max Health Professionals
    uint256 public maxManualDaoVerifiers = 20; // Max DAO verifiers
    uint256 public currentHealthProfessionals; // Current Health Professionals
    uint256 public currentManualDaoVerifiers; // Current manual DAO verifiers
    uint256 public currentAutoDaoVerifiers; // Current auto-approved DAO verifiers
    uint256 public genesisStartTime; // Timestamp of Genesis period start;
    bool public genesisActive = true; // Genesis governance active flag

    // Genesis Committee Management
    address[] public genesisMembers; // Genesis committee members
    uint256 public genesisApprovedHealth; // Health pros approved by Genesis
    uint256 public genesisApprovedDao; // DAOs approved by Genesis

    mapping(address => bool) public pendingGenesisApplications; // Pending Genesis apps
    mapping(address => Verifier) public verifiers; // Address -> Verifier data
    mapping(address => ApplicationProposal) public applicationProposals; // Active applications
    mapping(address => RevocationProposal) public revocationProposals; // Active revocations
    mapping(address => mapping(uint256 => bool)) public hasDonatedCampaign; // Donation tracking
    mapping(address => uint256) public donationCount; // Successful donations per address
    mapping(address => bool) public hasNFT; // NFT ownership tracker
    mapping(address => uint256) public lastRevocationAttempt; // Last revocation attempt timestamp
    mapping(address => uint256) public missedVotes; // Missed votes counter
    mapping(uint256 => string) public nftMetadata; // NFT metadata storage
    mapping(address => uint256) public applicationExpiry;

    address public donationHandler; // Authorized donation tracking address
    EmergencySettings public emergency;

    // =============================================
    // Events
    // =============================================
    event NewApplication(address applicant, VerifierType vType);
    event VoteCast(address voter, address target, bool support);
    event MembershipApproved(address applicant);
    event MembershipRevoked(address target);
    event RevocationProposed(address target);
    event NFTMinted(address to, uint256 tokenId);
    event NFTRetired(address from, uint256 tokenId);
    event NewGenesisApplication(address applicant);
    event GenesisApproved(address member);
    event GenesisConverted(address member);
    event GenesisRejected(address applicant);

    // =============================================
    // Modifiers
    // =============================================

    /// @dev Restricts access to authorized donation handler address
    modifier onlyDonationHandler() {
        if (msg.sender != donationHandler) revert MedicalVerifier__UnauthorizedAccess();
        _;
    }

    /// @dev Ensures caller is an active Genesis committee member
    modifier onlyGenesisMember() {
        if (!genesisActive) revert MedicalVerifier__NoActiveGenesisVerifiers();
        Verifier storage v = verifiers[msg.sender];
        if (v.verifierType != VerifierType.Genesis || v.status != ApplicationStatus.Approved) {
            revert MedicalVerifier__NotApprovedVerifier();
        }
        _;
    }

    // Automatic Genesis timeout checks in key functions
    modifier checkGenesis() {
        checkGenesisTimeout();
        _;
    }

    modifier checkEmergency() {
        if (emergency.paused) revert MedicalVerifier__UnauthorizedAccess();
        _;
    }

    /**
     * @dev Initializes contract with ERC721 token and sets Genesis start time
     */
    constructor() ERC721("MedicalVerifier", "MDV") Ownable(msg.sender) {
        genesisStartTime = block.timestamp;
    }

    // =============================================
    // Core Functions (CEI Pattern Implemented)
    // =============================================

    /**
     * @notice Checks and handles Genesis governance period timeout
     * @dev Automatically converts Genesis members to DAO if timeout reached
     */
    function checkGenesisTimeout() public {
        // CHECKS: Validate timeout conditions
        if (!genesisActive || block.timestamp < genesisStartTime + GENESIS_TIMEOUT) return;

        // EFFECTS: Update state before interactions
        genesisActive = false;
        uint256 genesisMemberCount = genesisMembers.length;
        uint256 newDaoCount = currentManualDaoVerifiers + genesisMemberCount;

        if (newDaoCount > maxManualDaoVerifiers) {
            maxManualDaoVerifiers = newDaoCount;
        }
        currentManualDaoVerifiers = newDaoCount;

        // INTERACTIONS: Process conversions
        for (uint256 i = 0; i < genesisMemberCount; i++) {
            address member = genesisMembers[i];
            verifiers[member].verifierType = VerifierType.Dao;
            emit GenesisConverted(member);
        }
    }

    function emergencyUnpause() external onlyOwner {
        require(emergency.paused, "Not paused");
        require(block.timestamp >= emergency.lastPauseTime + emergency.pauseDuration, "Cooldown active");
        emergency.paused = false;
        emergency.pauseDuration = 0;
        emergency.lastPauseTime = 0;
    }

    /**
     * @notice Submits application for Genesis committee membership
     * @dev Requires full documentation set
     * @param fullName Applicant's legal name
     * @param contactInfo Contact information
     * @param governmentID Government-issued ID
     * @param professionalDocs Professional certifications
     */

function applyAsGenesis(
    string memory fullName,
    string memory contactInfo,
    string memory governmentID,
    string memory professionalDocs
) external {
    if (genesisMembers.length >= 5) revert MedicalVerifier__ApprovedLimitReached();
    if (verifiers[msg.sender].verifierType != VerifierType.None) revert MedicalVerifier__AlreadyApplied();

    // Length checks
    if (bytes(fullName).length > MAX_STRING_LENGTH) revert MedicalVerifier__StringTooLong(1);
    if (bytes(contactInfo).length > MAX_STRING_LENGTH) revert MedicalVerifier__StringTooLong(2);
    if (bytes(governmentID).length > MAX_STRING_LENGTH) revert MedicalVerifier__StringTooLong(3);

    // Required fields
    if (bytes(trim(fullName)).length == 0) revert MedicalVerifier__EmptyField(1);
    if (bytes(trim(contactInfo)).length == 0) revert MedicalVerifier__EmptyField(2);
    if (bytes(trim(governmentID)).length == 0) revert MedicalVerifier__EmptyField(3);

    verifiers[msg.sender] = Verifier({
        verifierType: VerifierType.Genesis,
        status: ApplicationStatus.Pending,
        docs: ApplicationDocs(trim(fullName), trim(contactInfo), trim(governmentID), professionalDocs),
        nftId: 0
    });

    pendingGenesisApplications[msg.sender] = true;
    applicationExpiry[msg.sender] = block.timestamp + 30 days;

    emit NewGenesisApplication(msg.sender);
}


    /**
     * @notice Handles Genesis committee applications (Owner only)
     * @dev Processes approval/rejection of Genesis members
     * @param applicant Address of the Genesis applicant
     * @param approveFlag True to approve, False to reject
     */
    function handleGenesisApplication(address applicant, bool approveFlag) external onlyOwner {
        if (!pendingGenesisApplications[applicant]) {
            revert MedicalVerifier__NoApplicationFound();
        }

        if (approveFlag) {
            if (block.timestamp > applicationExpiry[applicant]) {
                revert MedicalVerifier__NoApplicationFound();
            }
            if (genesisMembers.length >= 5) {
                revert MedicalVerifier__ApprovedLimitReached();
            }

            Verifier storage v = verifiers[applicant];
            v.status = ApplicationStatus.Approved;
            genesisMembers.push(applicant);
            _mintVerifierNFT(applicant);
            emit GenesisApproved(applicant);
        } else {
            // Rejection logic
            delete verifiers[applicant];
            emit GenesisRejected(applicant);
        }
        delete pendingGenesisApplications[applicant];
    }

    function emergencyPause(uint256 duration) external onlyOwner {
        emergency.paused = true;
        emergency.pauseDuration = duration;
        emergency.lastPauseTime = block.timestamp;
    }

    function emergencyOverrideLimits(uint256 newHealth, uint256 newDao) external onlyOwner {
        if (!emergency.paused) revert MedicalVerifier__UnauthorizedAccess();
        if (block.timestamp >= emergency.lastPauseTime + emergency.pauseDuration) {
            revert MedicalVerifier__UnauthorizedAccess();
        }

        maxHealthProfessionals = newHealth;
        maxManualDaoVerifiers = newDao;
    }

    /**
     * @notice Submits Health Professional verification application
     * @dev Requires complete professional documentation package
     * @param fullName Legal full name of applicant
     * @param contactInfo Valid contact information
     * @param governmentID Government-issued identification
     * @param professionalDocs Professional certifications/credentials
     */

function _apply(
    string memory fullName,
    string memory contactInfo,
    string memory governmentID,
    string memory professionalDocs,
    VerifierType vType
) internal {
    if (genesisActive && genesisMembers.length == 0) revert MedicalVerifier__NoActiveGenesisVerifiers();
    if (verifiers[msg.sender].verifierType != VerifierType.None) revert MedicalVerifier__AlreadyApplied();

    // Validate length
    if (bytes(fullName).length > MAX_STRING_LENGTH) revert MedicalVerifier__StringTooLong(1);
    if (bytes(contactInfo).length > MAX_STRING_LENGTH) revert MedicalVerifier__StringTooLong(2);
    if (bytes(governmentID).length > MAX_STRING_LENGTH) revert MedicalVerifier__StringTooLong(3);
    if (vType == VerifierType.HealthProfessional && bytes(professionalDocs).length > MAX_STRING_LENGTH) {
        revert MedicalVerifier__StringTooLong(4);
    }

    // Validate non-empty trimmed input
    if (bytes(trim(fullName)).length == 0) revert MedicalVerifier__EmptyField(1);
    if (bytes(trim(contactInfo)).length == 0) revert MedicalVerifier__EmptyField(2);
    if (bytes(trim(governmentID)).length == 0) revert MedicalVerifier__EmptyField(3);
    if (vType == VerifierType.HealthProfessional && bytes(trim(professionalDocs)).length == 0) {
        revert MedicalVerifier__EmptyField(4);
    }

    verifiers[msg.sender] = Verifier({
        verifierType: vType,
        status: ApplicationStatus.Pending,
        docs: ApplicationDocs(
            trim(fullName),
            trim(contactInfo),
            trim(governmentID),
            vType == VerifierType.HealthProfessional ? trim(professionalDocs) : ""
        ),
        nftId: 0
    });

    emit NewApplication(msg.sender, vType);
}

function applyAsHealthProfessional(
    string memory fullName,
    string memory contactInfo,
    string memory governmentID,
    string memory professionalDocs
) external checkEmergency {
    _apply(fullName, contactInfo, governmentID, professionalDocs, VerifierType.HealthProfessional);
}

function applyAsDaoVerifier(
    string memory fullName,
    string memory contactInfo,
    string memory governmentID
) external {
    _apply(fullName, contactInfo, governmentID, "", VerifierType.Dao);
}


    /**
     * @notice Casts vote on a verification application
     * @dev Handles voting logic for both Genesis and regular members
     * @param applicant Address of the verification applicant
     * @param support Boolean indicating approval (true) or rejection (false)
     */
    function voteOnApplication(address applicant, bool support) external checkGenesis checkEmergency {
        // CHECKS
        Verifier storage target = verifiers[applicant];
        if (target.verifierType == VerifierType.None) revert MedicalVerifier__NoApplicationFound();
        if (target.status != ApplicationStatus.Pending) revert MedicalVerifier__ApplicationAlreadyProcessed();

        Verifier storage voter = verifiers[msg.sender];
        if (voter.status != ApplicationStatus.Approved) revert MedicalVerifier__NotApprovedVerifier();

        // Declare effectiveVoterType here before first use
        VerifierType effectiveVoterType = voter.verifierType;
        if (effectiveVoterType == VerifierType.Genesis && !genesisActive) {
            effectiveVoterType = VerifierType.Dao;
        }

        // Add verifier type validation here
        if (target.verifierType == VerifierType.HealthProfessional) {
            if (effectiveVoterType != VerifierType.HealthProfessional && effectiveVoterType != VerifierType.Genesis) {
                revert MedicalVerifier__InvalidVerifierType();
            }
        } else if (target.verifierType == VerifierType.Dao || target.verifierType == VerifierType.AutoDao) {
            if (
                effectiveVoterType != VerifierType.Dao && effectiveVoterType != VerifierType.AutoDao
                    && effectiveVoterType != VerifierType.Genesis
            ) {
                revert MedicalVerifier__InvalidVerifierType();
            }
        }

        ApplicationProposal storage proposal = applicationProposals[applicant];
        if (proposal.endTime == 0) {
            proposal.endTime = block.timestamp + VOTING_PERIOD;
            proposal.exists = true;
        }

        if (proposal.voted[msg.sender]) revert MedicalVerifier__AlreadyVoted();
        if (block.timestamp > proposal.endTime) revert MedicalVerifier__VotingPeriodEnded();

        // EFFECTS
        proposal.voted[msg.sender] = true;
        if (support) {
            proposal.yesVotes++;
            if (effectiveVoterType == VerifierType.Genesis) {
                proposal.genesisYesVotes++;
            }
        } else {
            proposal.noVotes++;
        }

        // INTERACTIONS
        emit VoteCast(msg.sender, applicant, support);

        // Finalize if ready
        if (block.timestamp >= proposal.endTime) {
            _finalizeApplication(applicant);
        }

        missedVotes[msg.sender] = 0;
    }

    function trim(string memory str) public pure returns (string memory) {
        bytes memory strBytes = bytes(str);

        uint256 start;
        while (start < strBytes.length && strBytes[start] == " ") {
            start++;
        }

        uint256 end = strBytes.length;
        while (end > start && strBytes[end - 1] == " ") {
            end--;
        }

        // Copy the trimmed substring
        bytes memory trimmed = new bytes(end - start);
        for (uint256 i = 0; i < trimmed.length; i++) {
            trimmed[i] = strBytes[start + i];
        }

        return string(trimmed);
    }

    /**
     * @notice Finalizes an application after voting period concludes
     * @dev Can only be called when voting has ended and proposal exists
     * @param applicant Address of the applicant to finalize
     */
    function finalizeApplication(address applicant) external {
        ApplicationProposal storage proposal = applicationProposals[applicant];
        require(block.timestamp >= proposal.endTime, "Voting ongoing");
        require(proposal.endTime != 0, "No proposal");
        _finalizeApplication(applicant);
    }

    /**
     * @notice Internal implementation of application finalization
     * @dev Processes voting results and updates system state
     * @param applicant Address of the applicant being processed
     */
    function _finalizeApplication(address applicant) private {
        ApplicationProposal storage proposal = applicationProposals[applicant];
        Verifier storage target = verifiers[applicant];

        // CHECKS
        uint256 totalVotes = proposal.yesVotes + proposal.noVotes;
        uint256 totalVerifiersCount;

        if (genesisActive && proposal.genesisYesVotes > 0) {
            totalVerifiersCount = genesisMembers.length;
        } else if (target.verifierType == VerifierType.HealthProfessional) {
            totalVerifiersCount = currentHealthProfessionals;
        } else {
            totalVerifiersCount = currentManualDaoVerifiers + currentAutoDaoVerifiers;
        }

        require(totalVerifiersCount > 0, "No verifiers");
        bool approved = (totalVotes * 100 >= totalVerifiersCount * MIN_PARTICIPATION)
            && (proposal.yesVotes * 100 >= totalVotes * APPROVAL_THRESHOLD);

        // EFFECTS
        if (approved) {
            _processApproval(target, proposal);
            // INTERACTIONS
            _mintVerifierNFT(applicant);
            emit MembershipApproved(applicant);
        } else {
            target.status = ApplicationStatus.Rejected;
        }

        // Cleanup
        _resetProposal(proposal);
    }

    /// @dev Processes approved application effects
    function _processApproval(Verifier storage target, ApplicationProposal storage proposal) private {
        if (genesisActive && proposal.genesisYesVotes > 0) {
            if (target.verifierType == VerifierType.HealthProfessional) {
                genesisApprovedHealth++;
            } else {
                genesisApprovedDao++;
            }
        }

        if (genesisActive && genesisApprovedHealth >= 5 && genesisApprovedDao >= 5) {
            genesisActive = false;
            uint256 genesisMemberCount = genesisMembers.length;
            for (uint256 i = 0; i < genesisMemberCount; i++) {
                address member = genesisMembers[i];
                verifiers[member].verifierType = VerifierType.Dao;
                emit GenesisConverted(member);
            }
        }

        if (target.verifierType == VerifierType.HealthProfessional) {
            require(++currentHealthProfessionals <= maxHealthProfessionals, "Limit exceeded");
        } else {
            require(++currentManualDaoVerifiers <= maxManualDaoVerifiers, "Limit exceeded");
        }
        target.status = ApplicationStatus.Approved;
    }

    /// @dev Resets proposal state safely
    function _resetProposal(ApplicationProposal storage proposal) private {
        proposal.yesVotes = 0;
        proposal.noVotes = 0;
        proposal.genesisYesVotes = 0;
        proposal.endTime = 0;
        proposal.exists = false;
    }

    /// @dev Resets revocation proposal state safely
    function _resetRevocationProposal(RevocationProposal storage proposal) private {
        proposal.yesVotes = 0;
        proposal.noVotes = 0;
        proposal.endTime = 0;
        proposal.exists = false;
    }

    /**
     * @notice Tracks missed votes and auto-revokes inactive verifiers
     * @dev Internal system maintenance function
     * @param verifier Address of verifier to check
     */
    function trackMissedVotes(address verifier) private {
        missedVotes[verifier]++;
        if (missedVotes[verifier] >= MAX_MISSED_VOTES) {
            verifiers[verifier].status = ApplicationStatus.Revoked;
            emit MembershipRevoked(verifier);
        }
    }

    /**
     * @notice Initiates a revocation proposal against a verifier
     * @dev Enforces cooldown periods and permission checks
     * @param target Address of verifier to revoke
     */
    function proposeRevocation(address target) external {
        // Validate proposal parameters
        if (msg.sender == target) revert MedicalVerifier__SelfRevocationNotAllowed();

        if (lastRevocationAttempt[target] != 0 && block.timestamp < lastRevocationAttempt[target] + REVOCATION_COOLDOWN)
        {
            revert MedicalVerifier__ActiveRevocationProposalExists();
        }

        lastRevocationAttempt[target] = block.timestamp;

        // Verify proposer credentials
        Verifier storage proposer = verifiers[msg.sender];
        if (proposer.status != ApplicationStatus.Approved) {
            revert MedicalVerifier__NotApprovedVerifier();
        }

        // Verify target status
        Verifier storage targetVerifier = verifiers[target];
        if (targetVerifier.status != ApplicationStatus.Approved) {
            revert MedicalVerifier__NotApprovedVerifier();
        }

        // Check verifier type permissions
        if (targetVerifier.verifierType == VerifierType.Dao || targetVerifier.verifierType == VerifierType.AutoDao) {
            if (proposer.verifierType != VerifierType.Dao && proposer.verifierType != VerifierType.AutoDao) {
                revert MedicalVerifier__UnauthorizedRevocation();
            }
        } else {
            if (proposer.verifierType != targetVerifier.verifierType) {
                revert MedicalVerifier__UnauthorizedRevocation();
            }
        }

        // Initialize revocation proposal
        RevocationProposal storage proposal = revocationProposals[target];
        if (proposal.endTime != 0 && block.timestamp < proposal.endTime) {
            revert MedicalVerifier__ActiveRevocationProposalExists();
        }
        proposal.endTime = block.timestamp + VOTING_PERIOD;
        proposal.exists = true;
        emit RevocationProposed(target);
    }

    /**
     * @notice Casts vote on a revocation proposal
     * @dev Handles voting logic and auto-executes revocation if criteria met
     * @param target Address of verifier being revoked
     * @param support Boolean indicating support for revocation
     */
    function voteOnRevocation(address target, bool support) external {
        RevocationProposal storage proposal = revocationProposals[target];
        Verifier storage voter = verifiers[msg.sender];
        Verifier storage targetVerifier = verifiers[target];

        // Validate voter credentials
        if (voter.status != ApplicationStatus.Approved) revert MedicalVerifier__NotApprovedVerifier();

        // Verify voting permissions based on verifier types
        if (targetVerifier.verifierType == VerifierType.Dao || targetVerifier.verifierType == VerifierType.AutoDao) {
            if (voter.verifierType != VerifierType.Dao && voter.verifierType != VerifierType.AutoDao) {
                revert MedicalVerifier__UnauthorizedRevocation();
            }
        } else {
            if (voter.verifierType != targetVerifier.verifierType) {
                revert MedicalVerifier__UnauthorizedRevocation();
            }
        }

        // Check voting period constraints
        if (block.timestamp > proposal.endTime) revert MedicalVerifier__VotingPeriodEnded();
        if (proposal.voted[msg.sender]) revert MedicalVerifier__AlreadyVoted();

        // Record vote
        proposal.voted[msg.sender] = true;
        if (support) proposal.yesVotes++;
        else proposal.noVotes++;

        emit VoteCast(msg.sender, target, support);

        // Auto-execute if voting period ended
        if (block.timestamp >= proposal.endTime) {
            _executeRevocation(target);
        }
    }

    /**
     * @notice Finalizes revocation process after voting period
     * @dev Can be called manually after voting concludes
     * @param target Address of verifier being revoked
     */
    function finalizeRevocation(address target) external {
        RevocationProposal storage proposal = revocationProposals[target];
        if (block.timestamp < proposal.endTime) revert MedicalVerifier__InvalidProposal();
        if (proposal.endTime == 0) revert MedicalVerifier__InvalidProposal();
        _executeRevocation(target);
    }

    /**
     * @notice Executes revocation based on voting results
     * @dev Handles state updates and NFT retirement
     * @param target Address of verifier being revoked
     */
    function _executeRevocation(address target) private {
        RevocationProposal storage proposal = revocationProposals[target];
        if (proposal.endTime == 0) revert MedicalVerifier__InvalidProposal();

        Verifier storage targetVerifier = verifiers[target];

        // Checks
        uint256 totalVotes = proposal.yesVotes + proposal.noVotes;
        uint256 totalVerifiersCount;

        if (targetVerifier.verifierType == VerifierType.HealthProfessional) {
            totalVerifiersCount = currentHealthProfessionals;
        } else if (
            targetVerifier.verifierType == VerifierType.Dao || targetVerifier.verifierType == VerifierType.AutoDao
        ) {
            totalVerifiersCount = currentManualDaoVerifiers + currentAutoDaoVerifiers;
        } else {
            revert MedicalVerifier__InvalidVerifierType();
        }

        if (totalVerifiersCount == 0) revert MedicalVerifier__InvalidProposal();
        bool approved = totalVotes * 100 >= totalVerifiersCount * MIN_PARTICIPATION
            && proposal.yesVotes * 100 >= totalVotes * APPROVAL_THRESHOLD;

        // Effects
        if (approved) {
            targetVerifier.status = ApplicationStatus.Revoked;

            if (targetVerifier.verifierType == VerifierType.HealthProfessional) {
                currentHealthProfessionals--;
            } else if (targetVerifier.verifierType == VerifierType.Dao) {
                currentManualDaoVerifiers--;
            } else {
                currentAutoDaoVerifiers--;
            }
        }

        delete lastRevocationAttempt[target];

        // Reset proposal state
        _resetRevocationProposal(proposal);

        // Interactions
        if (approved) {
            _retireNFT(target);
            emit MembershipRevoked(target);
        }
    }

    /**
     * @notice Mints verifier NFT credential (Internal)
     * @dev Implements non-reentrant protection
     * @param to Recipient address
     */
    function _mintVerifierNFT(address to) private nonReentrant {
        if (hasNFT[to]) revert MedicalVerifier__AlreadyHasNFT();

        _tokenIds.increment();
        uint256 newItemId = _tokenIds.current();

        _safeMint(to, newItemId);
        hasNFT[to] = true;
        verifiers[to].nftId = newItemId;

        nftMetadata[newItemId] = string(
            abi.encodePacked(
                "Verifier: ",
                verifiers[to].docs.fullName,
                " | Type: ",
                _verifierTypeToString(verifiers[to].verifierType)
            )
        );

        emit NFTMinted(to, newItemId);
    }

    /// @dev Converts enum to string for metadata
    function _verifierTypeToString(VerifierType _type) private pure returns (string memory) {
        if (_type == VerifierType.HealthProfessional) return "HealthProfessional";
        if (_type == VerifierType.Dao) return "Dao";
        if (_type == VerifierType.AutoDao) return "AutoDao";
        if (_type == VerifierType.Genesis) return "Genesis";
        return "None";
    }

    // Enhanced NFT transfer prevention
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        // Prevent transfers between non-zero addresses
        if (from != address(0) && to != address(0)) {
            revert MedicalVerifier__UnauthorizedAccess();
        }

        return super._update(to, tokenId, auth);
    }

    // Additional helper for hash validation
    function validateHash(bytes32 hash) private pure returns (bool) {
        return hash != bytes32(0);
    }

    /**
     * @notice Retrieves metadata for verifier NFT
     * @param tokenId NFT identifier
     * @return string Metadata associated with NFT
     */
    function getNFTMetadata(uint256 tokenId) public view returns (string memory) {
        return nftMetadata[tokenId];
    }

    /**
     * @notice Retires/burns verifier NFT (Internal)
     * @dev Handles credential revocation cleanup
     * @param target Address losing verification status
     */
    function _retireNFT(address target) private {
        uint256 tokenId = verifiers[target].nftId;

        // Burn NFT and update state
        _burn(tokenId);
        hasNFT[target] = false;
        delete verifiers[target].nftId;
        emit NFTRetired(target, tokenId);
    }

    /**
     * @notice Records philanthropic donations and tracks DAO eligibility
     * @dev Auto-approves DAO status after meeting donation requirements
     * @param donor Address of the contributor
     * @param campaignId ID of the donation campaign
     * @param amount Donation value in wei
     * @custom:requirements
     * - Caller must be authorized donation handler
     * - Donation must meet minimum threshold
     * - No duplicate campaign contributions
     */
    function recordDonation(address donor, uint256 campaignId, uint256 amount) external onlyDonationHandler {
        // Ignore sub-threshold donations
        if (amount < MIN_DONATION) return;

        // Prevent duplicate campaign counting
        if (hasDonatedCampaign[donor][campaignId]) return;

        // Update donation records
        hasDonatedCampaign[donor][campaignId] = true;
        donationCount[donor]++;

        // Auto-approve DAO status if requirements met
        if (donationCount[donor] >= MIN_CAMPAIGNS_REQUIRED) _autoApproveDao(donor);
    }

    /**
     * @notice Grants AutoDAO status to qualified donors
     * @dev Internal approval mechanism for philanthropic contributors
     * @param donor Address to elevate to AutoDAO status
     */
    function _autoApproveDao(address donor) private {
        // Skip existing verifiers
        if (verifiers[donor].verifierType != VerifierType.None) return;

        // Create AutoDAO verifier record
        verifiers[donor] = Verifier({
            verifierType: VerifierType.AutoDao,
            status: ApplicationStatus.Approved,
            docs: ApplicationDocs("", "", "", ""), // No docs required for AutoDAO
            nftId: 0
        });

        currentAutoDaoVerifiers++;
        _mintVerifierNFT(donor);
    }

    /**
     * @notice Updates system capacity limits (DAO authorized only)
     * @param newHealth New maximum Health Professionals limit
     * @param newDao New maximum Manual DAO Verifiers limit
     */
    function updateVerifierLimits(uint256 newHealth, uint256 newDao) external {
        // Handle Genesis member transition
        Verifier storage v = verifiers[msg.sender];
        VerifierType effectiveType = v.verifierType;
        if (effectiveType == VerifierType.Genesis && genesisActive) {
            effectiveType = VerifierType.Dao;
        }

        if (effectiveType != VerifierType.Dao) revert MedicalVerifier__NotApprovedVerifier();
        requireVerifier(VerifierType.Dao);

        // Validate limit ranges
        if (newHealth < 20 || newHealth > 25 || newDao < 20 || newDao > 25) {
            revert MedicalVerifier__LimitOutOfBounds();
        }

        // Ensure limits can't reduce below current counts
        if (newHealth < currentHealthProfessionals || newDao < currentManualDaoVerifiers) {
            revert MedicalVerifier__InvalidLimit();
        }

        // Update system configuration
        maxHealthProfessionals = newHealth;
        maxManualDaoVerifiers = newDao;
    }

    /**
     * @notice Verifies caller meets authorization requirements
     * @dev Reusable permission check for sensitive operations
     * @param requiredType Minimum verifier type needed for access
     */
    function requireVerifier(VerifierType requiredType) private view {
        Verifier storage v = verifiers[msg.sender];

        // Base approval check
        if (v.status != ApplicationStatus.Approved) revert MedicalVerifier__NotApprovedVerifier();

        // Type-specific validation
        if (requiredType == VerifierType.Dao) {
            if (v.verifierType != VerifierType.Dao && v.verifierType != VerifierType.AutoDao) {
                revert MedicalVerifier__NotApprovedVerifier();
            }
        } else {
            if (v.verifierType != requiredType) revert MedicalVerifier__NotApprovedVerifier();
        }
    }

    /**
     * @notice Updates authorized donation handler address
     * @dev Restricted to DAO-approved verifiers
     * @param _newHandler Address of new donation handler
     */
    function setDonationHandler(address _newHandler) external {
        requireVerifier(VerifierType.Dao);
        donationHandler = _newHandler;
    }

    // ---------- View Functions ---------- //

    /**
     * @notice Checks voting participation status
     * @param applicant Proposal target address
     * @param voter Address to check participation
     * @return bool True if voter has participated
     */
    function hasVotedOnApplication(address applicant, address voter) public view returns (bool) {
        return applicationProposals[applicant].voted[voter];
    }

    /**
     * @notice Checks revocation vote participation
     * @param target Address under revocation
     * @param voter Address to check participation
     * @return bool True if voter has participated
     */
    function hasVotedOnRevocation(address target, address voter) public view returns (bool) {
        return revocationProposals[target].voted[voter];
    }

    /**
     * @notice Returns current verifier counts
     * @return health Number of Health Professionals
     * @return manualDao Number of Manual DAO Verifiers
     * @return autoDao Number of AutoDAO Verifiers
     */
    function getVerifierCounts() public view returns (uint256 health, uint256 manualDao, uint256 autoDao) {
        return (currentHealthProfessionals, currentManualDaoVerifiers, currentAutoDaoVerifiers);
    }

    function isApprovedVerifier(address _address) public view returns (bool) {
        Verifier storage verifier = verifiers[_address];

        // Check if verifier has valid type and approved status
        return verifier.verifierType != VerifierType.None && verifier.status == ApplicationStatus.Approved;
    }

    function currentHealthProfessional() public view returns (uint256) {
        return currentHealthProfessionals;
    }

    function currentManualDaoVerifier() public view returns (uint256) {
        return currentManualDaoVerifiers;
    }

    function currentAutoDaoVerifier() public view returns (uint256) {
        return currentAutoDaoVerifiers;
    }

    /**
     * @notice Returns array of all Genesis committee members
     * @return Array of Genesis member addresses
     */
    function getGenesisMembers() public view returns (address[] memory) {
        return genesisMembers;
    }

    /**
     * @notice Returns detailed application proposal info
     * @param applicant Applicant address
     * @return exists Proposal existence status
     * @return genesisYesVotes Genesis committee approvals
     * @return totalVoters Number of participating voters
     */
    function getApplicationProposalDetails(address applicant)
        public
        view
        returns (bool exists, uint256 genesisYesVotes, uint256 totalVoters)
    {
        ApplicationProposal storage proposal = applicationProposals[applicant];
        return (proposal.exists, proposal.genesisYesVotes, proposal.yesVotes + proposal.noVotes);
    }

    /**
     * @notice Returns last revocation attempt timestamp
     * @param target Verifier address
     * @return Timestamp of last revocation attempt
     */
    function getLastRevocationAttempt(address target) public view returns (uint256) {
        return lastRevocationAttempt[target];
    }

    function totalVerifiers() public view returns (uint256) {
        return currentHealthProfessionals + currentManualDaoVerifiers + currentAutoDaoVerifiers;
    }

    function getApplicationProposalEndTime(address applicant) public view returns (uint256) {
        return applicationProposals[applicant].endTime;
    }

    function getRevocationProposalEndTime(address target) public view returns (uint256) {
        return revocationProposals[target].endTime;
    }

    function getVerifierData(address _address)
        public
        view
        returns (VerifierType verifierType, ApplicationStatus status, ApplicationDocs memory docs, uint256 nftId)
    {
        Verifier storage v = verifiers[_address];
        return (v.verifierType, v.status, v.docs, v.nftId);
    }

    // Add to MedicalVerifier contract
    function getSystemConfig()
        public
        view
        returns (uint256 maxHealth, uint256 maxManualDao, uint256 currentHealth, uint256 currentManualDao)
    {
        return (maxHealthProfessionals, maxManualDaoVerifiers, currentHealthProfessionals, currentManualDaoVerifiers);
    }
}
