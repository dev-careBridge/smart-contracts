// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/MedicalCrowdfunding.sol";
import "../../src/MedicalVerifier.sol";

contract Test_MedicalCrowdfunding___Test is Test {
    MedicalCrowdfunding public medicalCrowdfunding;
    MedicalVerifier public medicalVerifier;

    address public daoVerifier;
    address public healthVerifier;
    address public nonVerifier = address(3);
    uint256 public constant INITIAL_FEE = 150;
    uint256 private nonce; // Added nonce counter

    event FeeProposalCreated(uint256 proposalId, uint256 proposedFee);
    event VoteCast(uint256 proposalId, address voter, bool support);
    event ProposalExecuted(uint256 proposalId, bool passed);

    function setUp() public {
        medicalVerifier = new MedicalVerifier();
        medicalCrowdfunding = new MedicalCrowdfunding(address(0), 30, address(medicalVerifier));
        _setupGenesisCommittee();
        daoVerifier = _createVerifiedVerifier(MedicalVerifier.VerifierType.Dao);
        healthVerifier = _createVerifiedVerifier(MedicalVerifier.VerifierType.HealthProfessional);
    }

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        pure
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _setupGenesisCommittee() internal {
        vm.startPrank(address(this));
        medicalVerifier.applyAsGenesis("Genesis", "contact", "govID", "docs");
        medicalVerifier.handleGenesisApplication(address(this), true);
        vm.stopPrank();
    }

    function _createVerifiedVerifier(MedicalVerifier.VerifierType verifierType) internal returns (address) {
        // Generate unique address using nonce
        address newVerifier = address(uint160(uint256(keccak256(abi.encode(verifierType, nonce++)))));

        vm.startPrank(newVerifier);
        if (verifierType == MedicalVerifier.VerifierType.Dao) {
            medicalVerifier.applyAsDaoVerifier("DAO Verifier", "contact", "govID");
        } else {
            medicalVerifier.applyAsHealthProfessional("Health Pro", "contact", "govID", "professionalDocs");
        }
        vm.stopPrank();

        vm.prank(address(this));
        medicalVerifier.voteOnApplication(newVerifier, true);
        vm.warp(block.timestamp + 8 days);
        medicalVerifier.finalizeApplication(newVerifier);
        return newVerifier;
    }

    function _createProposal() internal returns (uint256) {
        vm.prank(daoVerifier);
        medicalCrowdfunding.proposeFeeAdjustment(200);
        return medicalCrowdfunding.currentProposalId();
    }

    /*//////////////////////////////////////////////////////////////
                        PROPOSE FEE ADJUSTMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ProposeFee_RevertIfNotVerifier() public {
        vm.prank(nonVerifier);
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__NotApprovedVerifier.selector);
        medicalCrowdfunding.proposeFeeAdjustment(200);
    }

    function test_ProposeFee_RevertIfInvalidRange() public {
        vm.startPrank(daoVerifier);
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__InvalidFeeRange.selector);
        medicalCrowdfunding.proposeFeeAdjustment(99);

        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__InvalidFeeRange.selector);
        medicalCrowdfunding.proposeFeeAdjustment(301);
        vm.stopPrank();
    }

    function test_ProposeFee_RevertIfCooldownActive() public {
        _createProposal();
        vm.warp(block.timestamp + 89 days);

        vm.prank(daoVerifier);
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__AdjustmentCooldownNotMet.selector);
        medicalCrowdfunding.proposeFeeAdjustment(200);
    }

    function test_ProposeFee_Success() public {
        vm.prank(daoVerifier);
        vm.expectEmit(true, true, false, true);
        emit FeeProposalCreated(1, 200);
        medicalCrowdfunding.proposeFeeAdjustment(200);

        // Use getCurrentProposal() instead of direct mapping access
        MedicalCrowdfunding.Proposal memory p = medicalCrowdfunding.getCurrentProposal();
        assertEq(p.proposedFee, 200);
        assertEq(p.endTime, block.timestamp + 14 days);
    }

    /*//////////////////////////////////////////////////////////////
                            VOTING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Vote_RevertIfNotVerifier() public {
        uint256 pid = _createProposal();
        vm.prank(nonVerifier);
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__NotApprovedVerifier.selector);
        medicalCrowdfunding.voteOnFeeAdjustment(pid, true);
    }

    function test_Vote_RevertIfVotingEnded() public {
        uint256 pid = _createProposal();
        vm.warp(block.timestamp + 15 days);

        vm.prank(daoVerifier);
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__VotingEnded.selector);
        medicalCrowdfunding.voteOnFeeAdjustment(pid, true);
    }

    function test_Vote_RevertIfDoubleVoting() public {
        uint256 pid = _createProposal();

        vm.startPrank(daoVerifier);
        medicalCrowdfunding.voteOnFeeAdjustment(pid, true);

        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__AlreadyVoted.selector);
        medicalCrowdfunding.voteOnFeeAdjustment(pid, true); // Same user attempts second vote
        vm.stopPrank();
    }

    function test_Vote_RecordsCorrectly() public {
        uint256 pid = _createProposal();
        vm.prank(daoVerifier);
        medicalCrowdfunding.voteOnFeeAdjustment(pid, true);

        // Use getCurrentProposal() to retrieve the proposal
        MedicalCrowdfunding.Proposal memory p = medicalCrowdfunding.getCurrentProposal();
        assertEq(p.yesVotes, 1);
        assertTrue(medicalCrowdfunding.hasVoted(pid, daoVerifier));
    }

    /*//////////////////////////////////////////////////////////////
                            FINALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Finalize_RevertIfVotingActive() public {
        uint256 pid = _createProposal();
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__VotingOngoing.selector);
        medicalCrowdfunding.finalizeProposal(pid);
    }

    function test_Finalize_RevertIfAlreadyExecuted() public {
        uint256 pid = _createProposal();
        vm.warp(block.timestamp + 15 days);
        medicalCrowdfunding.finalizeProposal(pid);

        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__AlreadyExecuted.selector);
        medicalCrowdfunding.finalizeProposal(pid);
    }

    function test_Finalize_SuccessfulFeeChange() public {
        uint256 pid = _createProposal();
        vm.prank(daoVerifier);
        medicalCrowdfunding.voteOnFeeAdjustment(pid, true);

        vm.warp(block.timestamp + 15 days);
        vm.expectEmit(true, true, false, true);
        emit ProposalExecuted(pid, true);
        medicalCrowdfunding.finalizeProposal(pid);

        assertEq(medicalCrowdfunding.serviceFeePercentage(), 200);
    }

    function test_Finalize_FailedDueToTurnout() public {
        uint256 pid = _createProposal();
        vm.prank(daoVerifier);
        medicalCrowdfunding.voteOnFeeAdjustment(pid, true);

        // Add two DAO verifiers to reach totalVerifiers = 4
        _createVerifiedVerifier(MedicalVerifier.VerifierType.Dao);
        _createVerifiedVerifier(MedicalVerifier.VerifierType.Dao);
        assertEq(medicalVerifier.totalVerifiers(), 4); // Now 4 verifiers

        vm.warp(block.timestamp + 15 days);
        medicalCrowdfunding.finalizeProposal(pid);
        assertEq(medicalCrowdfunding.serviceFeePercentage(), INITIAL_FEE); // Proposal fails
    }

    function test_Finalize_FailedDueToYesPercentage() public {
        uint256 pid = _createProposal();

        // Add an additional DAO verifier
        address secondDaoVerifier = _createVerifiedVerifier(MedicalVerifier.VerifierType.Dao);

        // DAO verifier votes "yes"
        vm.prank(daoVerifier);
        medicalCrowdfunding.voteOnFeeAdjustment(pid, true);

        // Health verifier votes "no"
        vm.prank(healthVerifier);
        medicalCrowdfunding.voteOnFeeAdjustment(pid, false);

        // Second DAO verifier votes "no"
        vm.prank(secondDaoVerifier);
        medicalCrowdfunding.voteOnFeeAdjustment(pid, false);

        vm.warp(block.timestamp + 15 days);
        medicalCrowdfunding.finalizeProposal(pid);
        assertEq(medicalCrowdfunding.serviceFeePercentage(), INITIAL_FEE);
    }
}

contract MedicalCrowdfunding__Test is Test {
    MedicalCrowdfunding public medicalCrowdfunding;
    MedicalVerifier public medicalVerifier;
    address public mockPriceFeed;

    address owner = address(1);
    address patient = address(2);
    address donor = address(3);
    address verifier1 = address(4);
    address verifier2 = address(5);
    address attacker = address(6);
    address genesisMember = address(7);

    uint256 campaignId;

    receive() external payable {}

    function setUp() public {
        // Setup price feed with 1 ETH = $3000 (3000e8)
        mockPriceFeed = address(new MockPriceFeed());
        MockPriceFeed(mockPriceFeed).setPrice(3000e8);

        medicalVerifier = new MedicalVerifier();
        medicalCrowdfunding = new MedicalCrowdfunding(mockPriceFeed, 7 days, address(medicalVerifier));

        // Setup Genesis committee
        _setupGenesisMember(genesisMember);

        // Setup verifiers through proper governance
        _setupHealthProfessional(verifier1);
        _setupDaoVerifier(verifier2);

        vm.prank(verifier2); 
        medicalVerifier.setDonationHandler(address(medicalCrowdfunding));


        // Create test campaign
        campaignId = _createBaseCampaign();
    }

    function _setupGenesisMember(address addr) private {
        vm.startPrank(addr);
        medicalVerifier.applyAsGenesis("Genesis Leader", "genesis@test.com", "GENESIS-ID-123", "professional-docs-ipfs");
        vm.stopPrank();

        // Approve as contract owner
        vm.prank(address(this)); // Test contract is owner
        medicalVerifier.handleGenesisApplication(addr, true);
    }

    function _setupHealthProfessional(address addr) private {
        vm.startPrank(addr);
        medicalVerifier.applyAsHealthProfessional("Dr. Smith", "contact", "govID", "license");
        vm.stopPrank();

        // Genesis member approves the application
        vm.prank(genesisMember);
        medicalVerifier.voteOnApplication(addr, true);
        vm.warp(block.timestamp + medicalVerifier.VOTING_PERIOD() + 1);
        medicalVerifier.finalizeApplication(addr);
    }

    function _setupDaoVerifier(address addr) private {
        vm.startPrank(addr);
        medicalVerifier.applyAsDaoVerifier("DAO Member", "contact", "govID");
        vm.stopPrank();

        // Genesis member approves the application
        vm.prank(genesisMember);
        medicalVerifier.voteOnApplication(addr, true);
        vm.warp(block.timestamp + medicalVerifier.VOTING_PERIOD() + 1);
        medicalVerifier.finalizeApplication(addr);
    }

    // Helper to create verifiers
    function _setupVerifier(address addr, MedicalVerifier.VerifierType vType) private {
        vm.startPrank(addr);
        if (vType == MedicalVerifier.VerifierType.HealthProfessional) {
            medicalVerifier.applyAsHealthProfessional("Dr. Smith", "contact", "govID", "license");
        } else {
            medicalVerifier.applyAsDaoVerifier("DAO Member", "contact", "govID");
        }
        vm.stopPrank();
        medicalVerifier.handleGenesisApplication(addr, true);
    }

    // Helper to create base campaign
    function _createBaseCampaign() private returns (uint256) {
        MedicalCrowdfunding.PatientDetails memory details =
            MedicalCrowdfunding.PatientDetails("John Doe", "1990-01-01", "contact", "location");
        MedicalCrowdfunding.DocumentConsent memory consent =
            MedicalCrowdfunding.DocumentConsent(true, true, true, true, true, true);
        MedicalCrowdfunding.CampaignDocuments memory docs =
            MedicalCrowdfunding.CampaignDocuments("diag", "doc", "bills", "admit", "gov", "photo");

        vm.startPrank(patient);
        uint256 id = medicalCrowdfunding.createCampaign(
            10000e18, // $10k target
            7 days,
            "Urgent treatment",
            details,
            consent,
            docs,
            MedicalCrowdfunding.GuardianDetails(address(0), "", "", "", "")
        );
        vm.stopPrank();

        // Approve campaign
        _approveCampaign(id);
        return id;
    }

    // Helper to approve a campaign
    function _approveCampaign(uint256 id) private {
        vm.prank(verifier1);
        medicalCrowdfunding.voteOnCampaign(id, true, "Approved");
        vm.prank(verifier2);
        medicalCrowdfunding.voteOnCampaign(id, true, "Approved");
        vm.warp(block.timestamp + medicalCrowdfunding.s_votingPeriod() + 1);
        medicalCrowdfunding.finalizeCampaign(id);
    }

    ////////////////////////////////////////
    // Test appealCampaign Functionality //
    //////////////////////////////////////
    function test_AppealRejectedCampaign() public {
        // Create a new campaign in PENDING state
        uint256 newCampaignId = _createPendingCampaign();

        // Reject the new campaign
        _rejectCampaign(newCampaignId);

        // Attempt appeal from patient
        vm.prank(patient);
        medicalCrowdfunding.appealCampaign(newCampaignId);

        assertEq(medicalCrowdfunding.getAppealCount(newCampaignId), 1);
        assertEq(
            uint256(medicalCrowdfunding.getCampaignStatus(newCampaignId)),
            uint256(MedicalCrowdfunding.CampaignStatus.PENDING)
        );
    }

    function test_RevertIf_AppealNonRejectedCampaign() public {
        vm.prank(patient);
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__OnlyRejectedCampaignsCanBeAppealed.selector);
        medicalCrowdfunding.appealCampaign(campaignId);
    }

    function test_RevertIf_NonPatientAppeals() public {
        // Create a new campaign in PENDING state
        uint256 newCampaignId = _createPendingCampaign();

        // Reject the new campaign
        _rejectCampaign(newCampaignId);

        // Attempt appeal from non-patient
        vm.prank(attacker);
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__OnlyPatientCanAppeal.selector);
        medicalCrowdfunding.appealCampaign(newCampaignId);
    }

    function test_RevertIf_ExceedMaxAppeals() public {
        // Create a new campaign in PENDING state
        uint256 newCampaignId = _createPendingCampaign();

        // First rejection
        _rejectCampaign(newCampaignId);

        // First appeal (now PENDING)
        vm.prank(patient);
        medicalCrowdfunding.appealCampaign(newCampaignId);

        // Second rejection
        _rejectCampaign(newCampaignId);

        // Second appeal (now PENDING)
        vm.prank(patient);
        medicalCrowdfunding.appealCampaign(newCampaignId);

        // Third rejection
        _rejectCampaign(newCampaignId);

        // Third appeal should exceed maximum
        vm.prank(patient);
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__MaxAppealsReached.selector);
        medicalCrowdfunding.appealCampaign(newCampaignId);
    }

    /////////////////////////////////
    // Test donate Functionality //
    ///////////////////////////////
    function test_SuccessfulDonation() public {
        uint256 donation = 1e18; // 1 ETH = $3000
        vm.deal(donor, donation);

        vm.prank(donor);
        medicalCrowdfunding.donate{value: donation}(campaignId);

        (,, uint256 donated,,,,) = medicalCrowdfunding.getCampaign(campaignId);
        assertEq(donated, 3000e18); // $3000 donated
    }

    function test_RevertIf_DonateToInactiveCampaign() public {
        // Create a new campaign and leave it in PENDING
        uint256 rejectedCampaignId = _createPendingCampaign();

        // Reject the campaign through voting
        _rejectCampaign(rejectedCampaignId);

        // Attempt to donate to the rejected campaign
        vm.deal(donor, 1e18);
        vm.prank(donor);
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__CampaignNotActive.selector);
        medicalCrowdfunding.donate{value: 1e18}(rejectedCampaignId);
    }

    // Helper to create a campaign without approving it
    function _createPendingCampaign() private returns (uint256) {
        MedicalCrowdfunding.PatientDetails memory details =
            MedicalCrowdfunding.PatientDetails("John Doe", "1990-01-01", "contact", "location");
        MedicalCrowdfunding.DocumentConsent memory consent =
            MedicalCrowdfunding.DocumentConsent(true, true, true, true, true, true);
        MedicalCrowdfunding.CampaignDocuments memory docs =
            MedicalCrowdfunding.CampaignDocuments("diag", "doc", "bills", "admit", "gov", "photo");

        vm.startPrank(patient);
        uint256 id = medicalCrowdfunding.createCampaign(
            10000e18, // $10k target
            7 days,
            "Urgent treatment",
            details,
            consent,
            docs,
            MedicalCrowdfunding.GuardianDetails(address(0), "", "", "", "")
        );
        vm.stopPrank();

        return id;
    }

    function test_RevertIf_DonateBelowMinimum() public {
        vm.deal(donor, 0.001e18); // 0.001 ETH = $3
        vm.prank(donor);
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__MinimumAmountNotReached.selector);
        medicalCrowdfunding.donate{value: 0.001e18}(campaignId);
    }

    function test_CompleteCampaignWithDonation() public {
        uint256 target = 10000e18;
        uint256 donation = (target * 1e18) / 3000e18 + 1; // 10000/3000 = 3.333... ETH

        vm.deal(donor, donation);
        vm.prank(donor);
        medicalCrowdfunding.donate{value: donation}(campaignId);

        assertEq(
            uint256(medicalCrowdfunding.getCampaignStatus(campaignId)),
            uint256(MedicalCrowdfunding.CampaignStatus.COMPLETED)
        );
    }

    ///////////////////////////////////////
    // Test Fee Distribution & Withdraw //
    //////////////////////////////////////
    function test_FeeDistribution() public {
        uint256 donation = 10e18;
        vm.deal(donor, donation);

        vm.prank(donor);
        medicalCrowdfunding.donate{value: donation}(campaignId);

        // Check verifier fee pools
        assertGt(medicalCrowdfunding.getVerifierBalance(verifier1), 0);
        assertGt(medicalCrowdfunding.getVerifierBalance(verifier2), 0);
    }

    function test_WithdrawFees() public {
        test_FeeDistribution();
        uint256 balance = medicalCrowdfunding.getVerifierBalance(verifier1);

        vm.prank(verifier1);
        medicalCrowdfunding.withdrawVerifierFees(balance);

        assertEq(medicalCrowdfunding.getVerifierBalance(verifier1), 0);
    }

    function test_RevertIf_WithdrawExcessFees() public {
        test_FeeDistribution();
        uint256 balance = medicalCrowdfunding.getVerifierBalance(verifier1);

        vm.prank(verifier1);
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__InvalidWithdrawAmount.selector);
        medicalCrowdfunding.withdrawVerifierFees(balance + 1);
    }

    ////////////////////////////////
    // Test Expiration Handling //
    //////////////////////////////
    function test_FinalizeExpiredCampaign() public {
        vm.warp(block.timestamp + 8 days);
        medicalCrowdfunding.finalizeCampaignIfExpired(campaignId);

        assertEq(
            uint256(medicalCrowdfunding.getCampaignStatus(campaignId)),
            uint256(MedicalCrowdfunding.CampaignStatus.COMPLETED)
        );
    }

    // Helper to reject a campaign
    function _rejectCampaign(uint256 id) private {
        vm.prank(verifier1);
        medicalCrowdfunding.voteOnCampaign(id, false, "Bad docs");
        vm.prank(verifier2);
        medicalCrowdfunding.voteOnCampaign(id, false, "Suspicious");
        vm.warp(block.timestamp + medicalCrowdfunding.s_votingPeriod() + 1);
        medicalCrowdfunding.finalizeCampaign(id);
    }
}

contract MockPriceFeed is AggregatorV3Interface {
    int256 public price;

    function setPrice(int256 _price) external {
        price = _price;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, price, 0, block.timestamp, 0);
    }

    function decimals() external view returns (uint8) {
        return 8;
    }

    function description() external view returns (string memory) {
        return "Mock Price Feed";
    }

    function version() external view returns (uint256) {
        return 1;
    }

    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, 0, 0, 0, 0);
    }
}


contract MedicalCrowdfunding_Test is Test {
    MedicalCrowdfunding public medicalCrowdfunding;
    MedicalVerifier public medicalVerifier;
    address constant PRICE_FEED = address(0x123);
    address patient = address(0x111);
    address healthVerifier = address(0x222);
    address daoVerifier = address(0x333);
    address nonVerifier = address(0x999);
    address genesisMember = address(0x444);
    address public genesisVerifier = address(0x444);

    function setUp() public {
        medicalVerifier = new MedicalVerifier();
        medicalCrowdfunding = new MedicalCrowdfunding(PRICE_FEED, 30, address(medicalVerifier));

        // Setup test verifiers
        _registerGenesisMember(genesisMember);
        _registerVerifier(healthVerifier, MedicalVerifier.VerifierType.HealthProfessional);
        _registerVerifier(daoVerifier, MedicalVerifier.VerifierType.Dao);
    }

    function _createCampaign() internal returns (uint256) {
        MedicalCrowdfunding.PatientDetails memory patientDetails = MedicalCrowdfunding.PatientDetails({
            fullName: "John Doe",
            dateOfBirth: "01/01/1990",
            contactInfo: "john@example.com",
            residenceLocation: "City"
        });

        MedicalCrowdfunding.DocumentConsent memory consent = MedicalCrowdfunding.DocumentConsent({
            shareDiagnosisReport: true,
            shareDoctorsLetter: true,
            shareMedicalBills: true,
            shareAdmissionDoc: true,
            shareGovernmentID: true,
            sharePatientPhoto: true
        });

        MedicalCrowdfunding.CampaignDocuments memory documents = MedicalCrowdfunding.CampaignDocuments({
            diagnosisReportIPFS: "diagnosis",
            doctorsLetterIPFS: "doctor",
            medicalBillsIPFS: "bills",
            admissionDocIPFS: "admission",
            governmentIDIPFS: "govID",
            patientPhotoIPFS: "photo"
        });

        MedicalCrowdfunding.GuardianDetails memory guardian = MedicalCrowdfunding.GuardianDetails({
            guardian: address(0),
            guardianGovernmentID: "guardianID",
            guardianFullName: "Guardian Name",
            guardianMobileNumber: "1234567890",
            guardianResidentialAddress: "Guardian Address"
        });

        vm.prank(patient);
        return medicalCrowdfunding.createCampaign(
            6 * 1e18, 0, "Valid comment", patientDetails, consent, documents, guardian
        );
    }

    function _registerGenesisMember(address member) internal {
        vm.startPrank(member);
        medicalVerifier.applyAsGenesis("Genesis Member", "genesis@example.com", "GEN-123", "Genesis Credentials");
        vm.stopPrank();

        // Approve Genesis application
        vm.prank(medicalVerifier.owner());
        medicalVerifier.handleGenesisApplication(member, true);
    }

    // Update the _registerVerifier function in your test
    function _registerVerifier(address verifier, MedicalVerifier.VerifierType vType) internal {
        // Submit application
        vm.startPrank(verifier);
        if (vType == MedicalVerifier.VerifierType.HealthProfessional) {
            medicalVerifier.applyAsHealthProfessional("Dr. Smith", "dr@hospital.com", "HP-123", "Medical License");
        } else {
            medicalVerifier.applyAsDaoVerifier("DAO Member", "dao@example.com", "DAO-456");
        }
        vm.stopPrank();

        // Vote as Genesis member
        vm.prank(genesisMember);
        medicalVerifier.voteOnApplication(verifier, true);

        // Get voting end time from contract
        uint256 endTime = medicalVerifier.getApplicationProposalEndTime(verifier);

        // Fast-forward to 1 second after voting period ends
        vm.warp(endTime + 1);

        // Finalize the application
        medicalVerifier.finalizeApplication(verifier);
    }

    // Test cases for voteOnCampaign
    function test_RevertWhen_NotVerifier() public {
        uint256 campaignId = _createCampaign();
        vm.prank(nonVerifier);
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__NotApprovedVerifier.selector);
        medicalCrowdfunding.voteOnCampaign(campaignId, true, "");
    }

    function _setupNewVerifier(address verifier) internal {
        // Register as health professional
        vm.startPrank(verifier);
        medicalVerifier.applyAsHealthProfessional("New Doctor", "new@hospital.com", "HP-456", "License");
        vm.stopPrank();

        // Approve the application (using the owner as genesis verifier)
        vm.prank(genesisVerifier);
        medicalVerifier.voteOnApplication(verifier, true);

        // Finalize after voting period
        vm.warp(block.timestamp + 7 days);
        medicalVerifier.finalizeApplication(verifier);
    }

    function test_RevertWhen_CampaignNotPending() public {
        uint256 campaignId = _createCampaign();

        address newVerifier = address(0x123);
        _setupNewVerifier(newVerifier);

        uint256 votingEndTime = medicalCrowdfunding.getVotingEndTime(campaignId);

        // First vote (health verifier)
        vm.prank(healthVerifier);
        medicalCrowdfunding.voteOnCampaign(campaignId, true, "");

        // Second vote (DAO verifier) at votingEndTime to trigger finalization
        vm.warp(votingEndTime); // Adjusted to votingEndTime
        vm.prank(daoVerifier);
        medicalCrowdfunding.voteOnCampaign(campaignId, true, ""); // Auto-finalizes

        // Attempt to vote with new verifier after finalization
        vm.prank(newVerifier);
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__CampaignNotPending.selector);
        medicalCrowdfunding.voteOnCampaign(campaignId, true, "");
    }

    function test_RevertWhen_VotingPeriodEnded() public {
        uint256 campaignId = _createCampaign();
        uint256 votingEndTime = medicalCrowdfunding.getVotingEndTime(campaignId);
        vm.warp(votingEndTime + 1);

        vm.prank(healthVerifier);
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__VotingEnded.selector);
        medicalCrowdfunding.voteOnCampaign(campaignId, true, "");
    }

    function test_RevertWhen_NoCommentForRejection() public {
        uint256 campaignId = _createCampaign();
        vm.prank(healthVerifier);
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__CommentRequired.selector);
        medicalCrowdfunding.voteOnCampaign(campaignId, false, "");
    }

    function test_RevertWhen_CommentTooLong() public {
        uint256 campaignId = _createCampaign();
        string memory longComment = new string(301);
        vm.prank(healthVerifier);
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__CommentTooLong.selector);
        medicalCrowdfunding.voteOnCampaign(campaignId, true, longComment);
    }

    function test_RevertWhen_DoubleVoting() public {
        uint256 campaignId = _createCampaign();
        vm.startPrank(healthVerifier);
        medicalCrowdfunding.voteOnCampaign(campaignId, true, "");
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__AlreadyVoted.selector);
        medicalCrowdfunding.voteOnCampaign(campaignId, true, "");
        vm.stopPrank();
    }

    // Test cases for _checkApproval and _finalizeCampaign
    function test_CampaignApproval() public {
        uint256 campaignId = _createCampaign();

        // Get initial voting end time
        uint256 votingEndTime = medicalCrowdfunding.getVotingEndTime(campaignId);

        // First vote (health verifier) within voting period
        vm.prank(healthVerifier);
        medicalCrowdfunding.voteOnCampaign(campaignId, true, "");

        // Warp to the exact voting end time
        vm.warp(votingEndTime);

        // Second vote (DAO verifier) at votingEndTime - triggers finalization
        vm.prank(daoVerifier);
        medicalCrowdfunding.voteOnCampaign(campaignId, true, "");

        // Verify status transition (finalization happens automatically via vote)
        MedicalCrowdfunding.CampaignStatus status = medicalCrowdfunding.getCampaignStatus(campaignId);
        assertEq(uint256(status), uint256(MedicalCrowdfunding.CampaignStatus.ACTIVE));
    }

    function test_CampaignRejection() public {
        uint256 campaignId = _createCampaign();

        // Get voting end time
        uint256 votingEndTime = medicalCrowdfunding.getVotingEndTime(campaignId);

        // Health verifier rejects
        vm.prank(healthVerifier);
        medicalCrowdfunding.voteOnCampaign(campaignId, false, "Invalid documentation");

        // DAO verifier also rejects
        vm.prank(daoVerifier);
        medicalCrowdfunding.voteOnCampaign(campaignId, false, "Suspicious activity");

        // Warp to voting period end and finalize
        vm.warp(votingEndTime);
        medicalCrowdfunding.finalizeCampaign(campaignId); // Explicit finalization call

        // Verify rejection status
        MedicalCrowdfunding.CampaignStatus status = medicalCrowdfunding.getCampaignStatus(campaignId);
        assertEq(uint256(status), uint256(MedicalCrowdfunding.CampaignStatus.REJECTED));
    }

    // Test cases for getCampaignDocuments
    function test_VerifierSeesAllDocuments() public {
        uint256 campaignId = _createCampaign();
        vm.prank(healthVerifier);
        MedicalCrowdfunding.CampaignDocuments memory docs = medicalCrowdfunding.getCampaignDocuments(campaignId);

        assertEq(docs.doctorsLetterIPFS, "doctor");
        assertEq(docs.medicalBillsIPFS, "bills");
    }

    function test_NonVerifierSeesConsentedDocuments() public {
        uint256 campaignId = _createCampaign();
        vm.prank(nonVerifier);
        MedicalCrowdfunding.CampaignDocuments memory docs = medicalCrowdfunding.getCampaignDocuments(campaignId);

        assertEq(docs.doctorsLetterIPFS, "doctor");
        assertEq(docs.medicalBillsIPFS, "bills");
    }

    // Test cases for getCampaignStatus
    function test_GetValidCampaignStatus() public {
        uint256 campaignId = _createCampaign();
        MedicalCrowdfunding.CampaignStatus status = medicalCrowdfunding.getCampaignStatus(campaignId);
        assertEq(uint256(status), uint256(MedicalCrowdfunding.CampaignStatus.PENDING));
    }

    function test_GetNonExistentCampaignStatus() public {
        MedicalCrowdfunding.CampaignStatus status = medicalCrowdfunding.getCampaignStatus(999);
        assertEq(uint256(status), uint256(MedicalCrowdfunding.CampaignStatus.PENDING));
    }
}

contract MedicalCrowdfundingTest is Test {
    MedicalCrowdfunding public medicalCrowdfunding;
    MedicalVerifier public medicalVerifier;
    MockPriceFeed public priceFeed;

    MedicalCrowdfunding.PatientDetails validPatientDetails;
    MedicalCrowdfunding.DocumentConsent validConsent;
    MedicalCrowdfunding.CampaignDocuments validDocuments;
    MedicalCrowdfunding.GuardianDetails validGuardian;

    function setUp() public {
        priceFeed = new MockPriceFeed();
        medicalVerifier = new MedicalVerifier();
        medicalCrowdfunding = new MedicalCrowdfunding(address(priceFeed), 30, address(medicalVerifier));

        validPatientDetails = MedicalCrowdfunding.PatientDetails({
            fullName: "John Doe",
            dateOfBirth: "01/01/1990",
            contactInfo: "john@example.com",
            residenceLocation: "New York"
        });

        validConsent = MedicalCrowdfunding.DocumentConsent({
            shareDiagnosisReport: true,
            shareDoctorsLetter: true,
            shareMedicalBills: true,
            shareAdmissionDoc: true,
            shareGovernmentID: true,
            sharePatientPhoto: true
        });

        validDocuments = MedicalCrowdfunding.CampaignDocuments({
            diagnosisReportIPFS: "diagnosis_hash",
            doctorsLetterIPFS: "doctor_letter_hash",
            medicalBillsIPFS: "bills_hash",
            admissionDocIPFS: "admission_hash",
            governmentIDIPFS: "gov_id_hash",
            patientPhotoIPFS: "photo_hash"
        });

        validGuardian = MedicalCrowdfunding.GuardianDetails({
            guardian: address(0x123),
            guardianGovernmentID: "guardian_gov_id",
            guardianFullName: "Jane Doe",
            guardianMobileNumber: "1234567890",
            guardianResidentialAddress: "Guardian Address"
        });
    }

    // Test successful campaign creation
    function test_CreateCampaign_Success() public {
        uint256 campaignId = medicalCrowdfunding.createCampaign(
            6e18, // _AmountNeededUSD (greater than MINIMUM_USD)
            0,
            "Valid comment under 300 chars",
            validPatientDetails,
            validConsent,
            validDocuments,
            MedicalCrowdfunding.GuardianDetails(address(0), "", "", "", "")
        );

        MedicalCrowdfunding.CampaignStatus status = medicalCrowdfunding.getCampaignStatus(campaignId);
        assertEq(uint256(status), uint256(MedicalCrowdfunding.CampaignStatus.PENDING));
    }

    // Test invalid target amount (<= MINIMUM_USD)
    function test_CreateCampaign_InvalidTargetAmount() public {
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__InvalidTargetAmount.selector);
        medicalCrowdfunding.createCampaign(
            5e18, // MINIMUM_USD is 5e18
            0,
            "Valid comment",
            validPatientDetails,
            validConsent,
            validDocuments,
            MedicalCrowdfunding.GuardianDetails(address(0), "", "", "", "")
        );
    }

    // Test empty comment
    function test_CreateCampaign_EmptyComment() public {
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__CommentRequired.selector);
        medicalCrowdfunding.createCampaign(
            6e18,
            0,
            "",
            validPatientDetails,
            validConsent,
            validDocuments,
            MedicalCrowdfunding.GuardianDetails(address(0), "", "", "", "")
        );
    }

    // Test comment exceeding max length
    function test_CreateCampaign_CommentTooLong() public {
        // Create a 301-character string without leading/trailing whitespace
        string memory longComment = "a";
        for (uint256 i = 0; i < 300; i++) {
            longComment = string(abi.encodePacked(longComment, "a"));
        }

        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__CommentTooLong.selector);
        medicalCrowdfunding.createCampaign(
            6e18,
            0,
            longComment,
            validPatientDetails,
            validConsent,
            validDocuments,
            MedicalCrowdfunding.GuardianDetails(address(0), "", "", "", "")
        );
    }

    // Test missing patient full name
    function test_CreateCampaign_MissingPatientFullName() public {
        MedicalCrowdfunding.PatientDetails memory invalidPatient = validPatientDetails;
        invalidPatient.fullName = "";
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__Invalid.selector);
        medicalCrowdfunding.createCampaign(
            6e18,
            0,
            "Valid comment",
            invalidPatient,
            validConsent,
            validDocuments,
            MedicalCrowdfunding.GuardianDetails(address(0), "", "", "", "")
        );
    }

    // Test missing diagnosis report
    function test_CreateCampaign_MissingDiagnosisReport() public {
        MedicalCrowdfunding.CampaignDocuments memory invalidDocs = validDocuments;
        invalidDocs.diagnosisReportIPFS = "";
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__DiagnosisReportRequired.selector);
        medicalCrowdfunding.createCampaign(
            6e18,
            0,
            "Valid comment",
            validPatientDetails,
            validConsent,
            invalidDocs,
            MedicalCrowdfunding.GuardianDetails(address(0), "", "", "", "")
        );
    }

    // Test missing doctor's letter
    function test_CreateCampaign_MissingDoctorsLetter() public {
        MedicalCrowdfunding.CampaignDocuments memory invalidDocs = validDocuments;
        invalidDocs.doctorsLetterIPFS = "";
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__DoctorLetterRequired.selector);
        medicalCrowdfunding.createCampaign(
            6e18,
            0,
            "Valid comment",
            validPatientDetails,
            validConsent,
            invalidDocs,
            MedicalCrowdfunding.GuardianDetails(address(0), "", "", "", "")
        );
    }

    // Test missing government ID
    function test_CreateCampaign_MissingGovernmentID() public {
        MedicalCrowdfunding.CampaignDocuments memory invalidDocs = validDocuments;
        invalidDocs.governmentIDIPFS = "";
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__GovernmentIDRequired.selector);
        medicalCrowdfunding.createCampaign(
            6e18,
            0,
            "Valid comment",
            validPatientDetails,
            validConsent,
            invalidDocs,
            MedicalCrowdfunding.GuardianDetails(address(0), "", "", "", "")
        );
    }

    // Test missing patient photo
    function test_CreateCampaign_MissingPatientPhoto() public {
        MedicalCrowdfunding.CampaignDocuments memory invalidDocs = validDocuments;
        invalidDocs.patientPhotoIPFS = "";
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__PatientPhotoRequired.selector);
        medicalCrowdfunding.createCampaign(
            6e18,
            0,
            "Valid comment",
            validPatientDetails,
            validConsent,
            invalidDocs,
            MedicalCrowdfunding.GuardianDetails(address(0), "", "", "", "")
        );
    }

    // Test guardian provided with missing government ID
    function test_CreateCampaign_GuardianMissingGovernmentID() public {
        MedicalCrowdfunding.GuardianDetails memory invalidGuardian = validGuardian;
        invalidGuardian.guardianGovernmentID = "";
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__GuardianIDRequired.selector);
        medicalCrowdfunding.createCampaign(
            6e18, 0, "Valid comment", validPatientDetails, validConsent, validDocuments, invalidGuardian
        );
    }

    // Test guardian provided with missing full name
    function test_CreateCampaign_GuardianMissingFullName() public {
        MedicalCrowdfunding.GuardianDetails memory invalidGuardian = validGuardian;
        invalidGuardian.guardianFullName = "";
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__GuardianFullNameRequired.selector);
        medicalCrowdfunding.createCampaign(
            6e18, 0, "Valid comment", validPatientDetails, validConsent, validDocuments, invalidGuardian
        );
    }

    // Test guardian provided with missing mobile number
    function test_CreateCampaign_GuardianMissingMobileNumber() public {
        MedicalCrowdfunding.GuardianDetails memory invalidGuardian = validGuardian;
        invalidGuardian.guardianMobileNumber = "";
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__MobileNumberRequired.selector);
        medicalCrowdfunding.createCampaign(
            6e18, 0, "Valid comment", validPatientDetails, validConsent, validDocuments, invalidGuardian
        );
    }

    // Test guardian provided with missing address
    function test_CreateCampaign_GuardianMissingAddress() public {
        MedicalCrowdfunding.GuardianDetails memory invalidGuardian = validGuardian;
        invalidGuardian.guardianResidentialAddress = "";
        vm.expectRevert(MedicalCrowdfunding.MedicalCrowdfunding__GuardianAddressRequired.selector);
        medicalCrowdfunding.createCampaign(
            6e18, 0, "Valid comment", validPatientDetails, validConsent, validDocuments, invalidGuardian
        );
    }
}
