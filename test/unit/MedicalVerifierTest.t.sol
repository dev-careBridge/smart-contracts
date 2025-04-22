// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "../../src/MedicalVerifier.sol";

contract Test_RevocationFunctions is Test, IERC721Receiver {
    MedicalVerifier mv;
    address constant GENESIS_APPROVER = address(9999);

    // Implement ERC721 receiver
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function setUp() public {
        mv = new MedicalVerifier(); // Test contract becomes owner

        // Setup genesis approver
        vm.startPrank(GENESIS_APPROVER);
        mv.applyAsGenesis("Genesis Approver", "contact", "govId", "docs");
        vm.stopPrank();

        // Test contract (owner) approves the genesis application
        mv.handleGenesisApplication(GENESIS_APPROVER, true);
    }

    // Updated helper functions
    function _setupGenesisMember(address member) internal {
        vm.startPrank(member);
        mv.applyAsGenesis("Genesis", "contact", "govId", "docs");
        vm.stopPrank();

        // Test contract (owner) approves the member
        mv.handleGenesisApplication(member, true);
    }

    function _createDaoMember(address user) internal {
        vm.startPrank(user);
        mv.applyAsDaoVerifier("DAO Member", "contact", "govId");
        vm.stopPrank();

        vm.prank(GENESIS_APPROVER);
        mv.voteOnApplication(user, true);

        vm.warp(block.timestamp + mv.VOTING_PERIOD());
        mv.finalizeApplication(user);
    }

    function _createHealthProfessional(address user) internal {
        vm.startPrank(user);
        mv.applyAsHealthProfessional("Dr. Alice", "contact", "govId", "medicalLicense");
        vm.stopPrank();

        vm.prank(GENESIS_APPROVER);
        mv.voteOnApplication(user, true);

        vm.warp(block.timestamp + mv.VOTING_PERIOD());
        mv.finalizeApplication(user);
    }

    // Test proposeRevocation reverts when targeting self
    function test_ProposeRevocation_SelfRevert() public {
        address daoMember = address(1);
        _createDaoMember(daoMember);
        vm.prank(daoMember);
        vm.expectRevert(MedicalVerifier.MedicalVerifier__SelfRevocationNotAllowed.selector);
        mv.proposeRevocation(daoMember);
    }

    // Test proposeRevocation reverts when proposer is not approved
    function test_ProposeRevocation_NotApprovedProposer() public {
        address target = address(1);
        _createDaoMember(target);
        address unapproved = address(2);
        vm.prank(unapproved);
        vm.expectRevert(MedicalVerifier.MedicalVerifier__NotApprovedVerifier.selector);
        mv.proposeRevocation(target);
    }

    // Test proposeRevocation reverts when target is not approved
    function test_ProposeRevocation_TargetNotApproved() public {
        address proposer = address(1);
        _createDaoMember(proposer);
        address target = address(2);
        vm.prank(proposer);
        vm.expectRevert(MedicalVerifier.MedicalVerifier__NotApprovedVerifier.selector);
        mv.proposeRevocation(target);
    }

    // Test proposeRevocation reverts during cooldown
    function test_ProposeRevocation_ActiveProposalExists() public {
        address proposer = address(1);
        address target = address(2);
        _createDaoMember(proposer);
        _createDaoMember(target);
        vm.prank(proposer);
        mv.proposeRevocation(target);
        vm.prank(proposer);
        vm.expectRevert(MedicalVerifier.MedicalVerifier__ActiveRevocationProposalExists.selector);
        mv.proposeRevocation(target);
    }

    // Test proposeRevocation reverts with wrong verifier type
    function test_ProposeRevocation_UnauthorizedVerifierType() public {
        address healthPro = address(1);
        _createHealthProfessional(healthPro);
        address daoMember = address(2);
        _createDaoMember(daoMember);
        vm.prank(healthPro);
        vm.expectRevert(MedicalVerifier.MedicalVerifier__UnauthorizedRevocation.selector);
        mv.proposeRevocation(daoMember);
    }

    // Test successful revocation proposal
    function test_ProposeRevocation_Success() public {
        address proposer = address(1);
        address target = address(2);
        _createDaoMember(proposer);
        _createDaoMember(target);
        vm.prank(proposer);
        mv.proposeRevocation(target);
        uint256 endTime = mv.getRevocationProposalEndTime(target);
        assertGt(endTime, 0);
    }

    // Test voteOnRevocation reverts when voter not approved
    function test_VoteOnRevocation_NotApprovedVoter() public {
        address target = address(1);
        address voter = address(2);
        _createDaoMember(target);
        _createDaoMember(address(3)); // Proposer
        vm.prank(address(3));
        mv.proposeRevocation(target);
        vm.prank(voter);
        vm.expectRevert(MedicalVerifier.MedicalVerifier__NotApprovedVerifier.selector);
        mv.voteOnRevocation(target, true);
    }

    // Test voteOnRevocation reverts after voting period
    function test_VoteOnRevocation_PeriodEnded() public {
        address target = address(1);
        address proposer = address(2);
        _createDaoMember(target);
        _createDaoMember(proposer);
        vm.prank(proposer);
        mv.proposeRevocation(target);
        vm.warp(block.timestamp + mv.VOTING_PERIOD() + 1);
        vm.prank(proposer);
        vm.expectRevert(MedicalVerifier.MedicalVerifier__VotingPeriodEnded.selector);
        mv.voteOnRevocation(target, true);
    }

    // Test voteOnRevocation reverts on double voting
    function test_VoteOnRevocation_AlreadyVoted() public {
        address target = address(1);
        address voter = address(2);
        _createDaoMember(target);
        _createDaoMember(voter);
        vm.prank(voter);
        mv.proposeRevocation(target);
        vm.prank(voter);
        mv.voteOnRevocation(target, true);
        vm.prank(voter);
        vm.expectRevert(MedicalVerifier.MedicalVerifier__AlreadyVoted.selector);
        mv.voteOnRevocation(target, true);
    }

    // Test voteOnRevocation reverts with wrong verifier type
    function test_VoteOnRevocation_WrongVerifierType() public {
        address healthPro = address(1);
        address daoMember = address(2);
        _createHealthProfessional(healthPro);
        _createDaoMember(daoMember);
        _createDaoMember(address(3)); // Proposer
        vm.prank(address(3));
        mv.proposeRevocation(daoMember);
        vm.prank(healthPro);
        vm.expectRevert(MedicalVerifier.MedicalVerifier__UnauthorizedRevocation.selector);
        mv.voteOnRevocation(daoMember, true);
    }

    // Test successful revocation execution
    function test_Revocation_Successful() public {
        address target = address(1);
        address voter1 = address(2);
        address voter2 = address(3);
        _createDaoMember(target);
        _createDaoMember(voter1);
        _createDaoMember(voter2);
        vm.prank(voter1);
        mv.proposeRevocation(target);
        vm.prank(voter1);
        mv.voteOnRevocation(target, true);
        vm.prank(voter2);
        mv.voteOnRevocation(target, true);
        vm.warp(block.timestamp + mv.VOTING_PERIOD());
        mv.finalizeRevocation(target);
        (, MedicalVerifier.ApplicationStatus status,,) = mv.getVerifierData(target);
        assertEq(uint256(status), uint256(MedicalVerifier.ApplicationStatus.Revoked));
        assertEq(mv.hasNFT(target), false);
    }

    // Test failed revocation due to insufficient votes
    function test_Revocation_Failed() public {
        address target = address(1);
        address voter1 = address(2);
        address voter2 = address(3);
        _createDaoMember(target);
        _createDaoMember(voter1);
        _createDaoMember(voter2);
        vm.prank(voter1);
        mv.proposeRevocation(target);
        vm.prank(voter1);
        mv.voteOnRevocation(target, true);
        vm.prank(voter2);
        mv.voteOnRevocation(target, false);
        vm.warp(block.timestamp + mv.VOTING_PERIOD());
        mv.finalizeRevocation(target);
        (, MedicalVerifier.ApplicationStatus status,,) = mv.getVerifierData(target); // Corrected destructuring
        assertEq(uint256(status), uint256(MedicalVerifier.ApplicationStatus.Approved));
    }

    // Test NFT retirement on revocation
    function test_Revocation_NFTBurned() public {
        address target = address(1);
        address proposer = address(2);
        _createDaoMember(target);
        _createDaoMember(proposer);
        vm.prank(proposer);
        mv.proposeRevocation(target);
        vm.prank(proposer);
        mv.voteOnRevocation(target, true);
        vm.warp(block.timestamp + mv.VOTING_PERIOD());
        mv.finalizeRevocation(target);
        assertEq(mv.balanceOf(target), 0);
        assertEq(mv.hasNFT(target), false);
    }
}

contract MedicalVerifier_Test is Test {
    MedicalVerifier mv;
    address owner = address(1);
    address applicant1 = address(2);
    address applicant2 = address(3);
    address genesis1 = address(4);
    address genesis2 = address(5);
    address dao1 = address(6);
    address dao2 = address(7);

    function setUp() public {
        // Deploy contract as owner
        vm.prank(owner);
        mv = new MedicalVerifier();

        // Setup genesis members
        address[] memory genesis = new address[](2);
        genesis[0] = genesis1;
        genesis[1] = genesis2;

        for (uint256 i = 0; i < genesis.length; i++) {
            // 1. Apply as genesis member
            vm.prank(genesis[i]);
            mv.applyAsGenesis("Genesis Member", "contact", "govId", "docs");

            // 2. Approve as owner
            vm.prank(owner);
            mv.handleGenesisApplication(genesis[i], true);
        }
    }

    // Helper to create valid application
    function applyAsHealthProfessional(address applicant) internal {
        vm.prank(applicant);
        mv.applyAsHealthProfessional("Dr. Alice", "alice@hospital.com", "ID123456", "MedicalLicense123");
    }

    function applyAsDaoVerifier(address applicant) internal {
        vm.prank(applicant);
        mv.applyAsDaoVerifier("Bob Smith", "bob@dao.org", "ID789012");
    }

    // Tests for applyAsHealthProfessional
    function test_ApplyHP_Success() public {
        applyAsHealthProfessional(applicant1);
        (MedicalVerifier.VerifierType vType,,,) = mv.getVerifierData(applicant1);
        assertEq(uint256(vType), uint256(MedicalVerifier.VerifierType.HealthProfessional));
    }

    function test_ApplyHP_EmptyFields() public {
        vm.expectRevert(abi.encodeWithSelector(
        MedicalVerifier.MedicalVerifier__EmptyField.selector,
        1
        ));
        vm.prank(applicant1);
        mv.applyAsHealthProfessional("", "contact", "gov", "docs");

        vm.expectRevert(abi.encodeWithSelector(
        MedicalVerifier.MedicalVerifier__EmptyField.selector,
        3
        ));
        vm.prank(applicant1);
        mv.applyAsHealthProfessional("Name", "contact", "", "docs");
    }

    function test_ApplyHP_DuplicateApplication() public {
        applyAsHealthProfessional(applicant1);
        vm.expectRevert(MedicalVerifier.MedicalVerifier__AlreadyApplied.selector);
        applyAsHealthProfessional(applicant1);
    }

    // Tests for applyAsDaoVerifier
    function test_ApplyDao_Success() public {
        applyAsDaoVerifier(applicant1);
        (MedicalVerifier.VerifierType vType,,,) = mv.getVerifierData(applicant1);
        assertEq(uint256(vType), uint256(MedicalVerifier.VerifierType.Dao));
    }

    function test_ApplyDao_WhitespaceTrim() public {
        vm.prank(applicant1);
        mv.applyAsDaoVerifier("  Bob  ", "  contact  ", "  gov  ");
        (,, MedicalVerifier.ApplicationDocs memory docs,) = mv.getVerifierData(applicant1);
        assertEq(docs.fullName, "Bob");
        assertEq(docs.governmentID, "gov");
    }

    // Tests for voteOnApplication and finalization
    function test_VoteAndApprove() public {
        // Apply and vote
        applyAsHealthProfessional(applicant1);

        // Genesis members vote
        vm.prank(genesis1);
        mv.voteOnApplication(applicant1, true);
        vm.prank(genesis2);
        mv.voteOnApplication(applicant1, true);

        // Finalize
        vm.warp(block.timestamp + mv.VOTING_PERIOD());
        mv.finalizeApplication(applicant1);

        (, MedicalVerifier.ApplicationStatus status,,) = mv.getVerifierData(applicant1);
        assertEq(uint256(status), uint256(MedicalVerifier.ApplicationStatus.Approved));
    }

    function test_VoteInvalidVerifierType() public {
        // 1. Create and approve a Health Professional
        applyAsHealthProfessional(applicant1);
        vm.prank(genesis1);
        mv.voteOnApplication(applicant1, true);
        vm.prank(genesis2);
        mv.voteOnApplication(applicant1, true);
        vm.warp(block.timestamp + mv.VOTING_PERIOD());
        mv.finalizeApplication(applicant1);

        // 2. Create DAO application
        applyAsDaoVerifier(applicant2);

        // 3. Health Professional tries to vote on DAO application
        vm.expectRevert(MedicalVerifier.MedicalVerifier__InvalidVerifierType.selector);
        vm.prank(applicant1); // Health Pro voting on DAO app
        mv.voteOnApplication(applicant2, true);
    }

    function test_VoteAfterPeriodEnd() public {
        // Setup: Create application and start voting period
        applyAsHealthProfessional(applicant1);

        // 1. Initial vote to start the voting period
        vm.prank(genesis1);
        mv.voteOnApplication(applicant1, true);

        // 2. Fast-forward past the voting period
        vm.warp(block.timestamp + mv.VOTING_PERIOD() + 1);

        // 3. Attempt to vote after period ended
        vm.expectRevert(MedicalVerifier.MedicalVerifier__VotingPeriodEnded.selector);
        vm.prank(genesis2);
        mv.voteOnApplication(applicant1, true);
    }

    function test_AutoFinalization() public {
        applyAsHealthProfessional(applicant1);
        // Votes within period
        vm.prank(genesis1);
        mv.voteOnApplication(applicant1, true);
        vm.prank(genesis2);
        mv.voteOnApplication(applicant1, true);
        // Finalize after period
        vm.warp(block.timestamp + mv.VOTING_PERIOD());
        mv.finalizeApplication(applicant1);
        // Check status
        (, MedicalVerifier.ApplicationStatus status,,) = mv.getVerifierData(applicant1);
        assertEq(uint256(status), uint256(MedicalVerifier.ApplicationStatus.Approved));
    }

    function test_ThresholdCalculations() public {
        // Create 5 genesis members
        address[] memory newGenesis = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            newGenesis[i] = address(uint160(100 + i));
            vm.prank(newGenesis[i]);
            mv.applyAsGenesis("Gen", "contact", "id", "docs");
            vm.prank(owner);
            mv.handleGenesisApplication(newGenesis[i], true);
        }

        applyAsHealthProfessional(applicant1);

        // Use the newly created genesis members for voting
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(newGenesis[i]); // Use local array reference
            mv.voteOnApplication(applicant1, true);
        }

        vm.warp(block.timestamp + mv.VOTING_PERIOD());
        mv.finalizeApplication(applicant1);

        (, MedicalVerifier.ApplicationStatus status,,) = mv.getVerifierData(applicant1);
        assertEq(uint256(status), uint256(MedicalVerifier.ApplicationStatus.Approved));
    }

    function test_GenesisConversion() public {
        // Create 3 Genesis members (setup already has 2, making total 5)
        address[] memory genesisMembers = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            genesisMembers[i] = address(uint160(100 + i));
            vm.prank(genesisMembers[i]);
            mv.applyAsGenesis("Gen", "contact", "id", "docs");
            vm.prank(owner);
            mv.handleGenesisApplication(genesisMembers[i], true);
        }

        // Approve 5 Health Professionals via Genesis votes
        for (uint256 i = 0; i < 5; i++) {
            address applicant = address(uint160(200 + i));
            applyAsHealthProfessional(applicant);
            for (uint256 j = 0; j < genesisMembers.length; j++) {
                // Fixed: Use actual array length
                vm.prank(genesisMembers[j]);
                mv.voteOnApplication(applicant, true);
            }
            vm.warp(block.timestamp + mv.VOTING_PERIOD());
            mv.finalizeApplication(applicant);
        }

        // Approve 5 DAO members via Genesis votes
        for (uint256 i = 0; i < 5; i++) {
            address applicant = address(uint160(300 + i));
            applyAsDaoVerifier(applicant);
            for (uint256 j = 0; j < genesisMembers.length; j++) {
                // Fixed: Use actual array length
                vm.prank(genesisMembers[j]);
                mv.voteOnApplication(applicant, true);
            }
            vm.warp(block.timestamp + mv.VOTING_PERIOD());
            mv.finalizeApplication(applicant);
        }

        // Verify Genesis conversion
        assertFalse(mv.genesisActive());
        for (uint256 i = 0; i < genesisMembers.length; i++) {
            // Fixed: Use actual array length
            (MedicalVerifier.VerifierType vType,,,) = mv.getVerifierData(genesisMembers[i]);
            assertEq(uint256(vType), uint256(MedicalVerifier.VerifierType.Dao));
        }
    }

    function test_MaxStringLength() public {
        string memory longString = new string(mv.MAX_STRING_LENGTH() + 1);
        vm.expectRevert(abi.encodeWithSelector(
        MedicalVerifier.MedicalVerifier__StringTooLong.selector,
        1
        ));
        vm.prank(applicant1);
        mv.applyAsDaoVerifier(longString, "contact", "gov");
    }
}

contract MedicalVerifierTest is StdCheats, Test {
    MedicalVerifier verifier;
    address constant TEST_USER = address(1);
    address constant OWNER = address(999);

    function setUp() public {
        vm.startPrank(OWNER);
        verifier = new MedicalVerifier();
        vm.stopPrank();
    }

    // Test helper - Approve genesis members
    function _approveGenesisMembers(uint256 count) internal {
        for (uint256 i = 0; i < count; i++) {
            address member = address(uint160(1000 + i));
            vm.prank(member);
            verifier.applyAsGenesis("Valid Name", "contact", "govID", "docs");

            vm.prank(OWNER);
            verifier.handleGenesisApplication(member, true);
        }
    }

    // Test 1: Successful application
    function test_applyAsGenesis_Success() public {
        vm.prank(TEST_USER);
        verifier.applyAsGenesis("Alice", "alice@email.com", "ID123", "MD-Certificate");

        (MedicalVerifier.VerifierType vType,,,) = verifier.getVerifierData(TEST_USER);
        assertEq(uint256(vType), uint256(MedicalVerifier.VerifierType.Genesis));
    }

    // Test 2: Committee full rejection
    function test_applyAsGenesis_RevertWhenCommitteeFull() public {
        _approveGenesisMembers(5);

        vm.prank(TEST_USER);
        vm.expectRevert(abi.encodeWithSignature("MedicalVerifier__ApprovedLimitReached()"));
        verifier.applyAsGenesis("Bob", "bob@email.com", "ID456", "PhD-Cert");
    }

    // Test 3: Duplicate application
    function test_applyAsGenesis_RevertWhenDuplicateApplication() public {
        vm.prank(TEST_USER);
        verifier.applyAsGenesis("Carol", "carol@email.com", "ID789", "RN-License");

        vm.prank(TEST_USER);
        vm.expectRevert(abi.encodeWithSignature("MedicalVerifier__AlreadyApplied()"));
        verifier.applyAsGenesis("Carol", "carol@email.com", "ID789", "RN-License");
    }

    // Test 4: Whitespace-only inputs
    function test_applyAsGenesis_RevertWhenWhitespaceInputs() public {
        string[4] memory inputs = [
            "   ", // fullName
            "  ", // contactInfo
            "\t\t", // governmentID
            " \n " // professionalDocs
        ];

        vm.prank(TEST_USER);
        vm.expectRevert(
        abi.encodeWithSelector(
            MedicalVerifier.MedicalVerifier__EmptyField.selector,
            1 // First validation failure is fullName field
        )
        );
        verifier.applyAsGenesis(inputs[0], inputs[1], inputs[2], inputs[3]);
    }

    // Test 5: Valid after trimming
    function test_applyAsGenesis_AcceptsTrimmedInputs() public {
        vm.prank(TEST_USER);
        verifier.applyAsGenesis("  Dave  ", "  dave@email.com  ", "  ID000  ", "  ");

        (,, MedicalVerifier.ApplicationDocs memory docs,) = verifier.getVerifierData(TEST_USER);
        assertEq(docs.fullName, "Dave");
        assertEq(docs.contactInfo, "dave@email.com");
    }

    // Test 6: Expired application handling
    function test_applyAsGenesis_ExpiresAfter30Days() public {
        vm.prank(TEST_USER);
        verifier.applyAsGenesis("Eve", "eve@email.com", "ID987", "");

        // Warp 31 days into future
        vm.warp(block.timestamp + 31 days);

        // Should reject approval
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSignature("MedicalVerifier__NoApplicationFound()"));
        verifier.handleGenesisApplication(TEST_USER, true);
    }

    function test_applyAsGenesis_RevokedMemberCanReapply() public {
        address genesisApplicant = address(2);
        address contractOwner = verifier.owner();

        // 1. Setup Genesis Committee
        vm.startPrank(contractOwner);
        verifier.applyAsGenesis("Genesis Member", "genesis@email.com", "GENESIS-ID", "Docs");
        vm.stopPrank();

        // 2. Approve Genesis Member (must be owner)
        vm.prank(contractOwner);
        verifier.handleGenesisApplication(contractOwner, true);

        // 3. Apply & approve test Genesis member
        vm.startPrank(genesisApplicant);
        verifier.applyAsGenesis("Alice", "alice@email.com", "ID123", "Docs");
        vm.stopPrank();

        // Corrected Step 4: Owner approves the genesisApplicant's Genesis application
        vm.prank(contractOwner);
        verifier.handleGenesisApplication(genesisApplicant, true);

        // 5. Convert Genesis to DAO members (simulate Genesis period ending)
        vm.warp(block.timestamp + verifier.GENESIS_TIMEOUT() + 1);
        verifier.checkGenesisTimeout();

        // 6. Verify conversion to DAO
        (MedicalVerifier.VerifierType vType,,,) = verifier.getVerifierData(contractOwner);
        assertEq(uint256(vType), uint256(MedicalVerifier.VerifierType.Dao));

        // 7. Propose revocation using converted DAO member
        vm.prank(contractOwner);
        verifier.proposeRevocation(genesisApplicant);

        // 8. Vote and finalize revocation
        vm.prank(contractOwner);
        verifier.voteOnRevocation(genesisApplicant, true);
        vm.warp(block.timestamp + verifier.VOTING_PERIOD());
        verifier.finalizeRevocation(genesisApplicant);

        // 9. Verify revocation prevents reapplication
        vm.startPrank(genesisApplicant);
        vm.expectRevert(abi.encodeWithSignature("MedicalVerifier__AlreadyApplied()"));
        verifier.applyAsGenesis("New Alice", "new@email.com", "ID456", "NewDocs");
        vm.stopPrank();
    }

    // Test 8: Mixed verifier types rejection
    function test_applyAsGenesis_RevertWhenExistingVerifierType() public {
        // Setup Genesis member (OWNER)
        vm.startPrank(OWNER);
        verifier.applyAsGenesis("Owner Genesis", "owner@email.com", "OWNER-ID", "Docs");
        verifier.handleGenesisApplication(OWNER, true);
        vm.stopPrank();

        // TEST_USER applies as HealthProfessional
        vm.prank(TEST_USER);
        verifier.applyAsHealthProfessional("Grace", "grace@email.com", "HID123", "NP-Cert");

        // OWNER (Genesis) votes to approve
        vm.prank(OWNER);
        verifier.voteOnApplication(TEST_USER, true);

        // Fast-forward and finalize
        vm.warp(block.timestamp + 8 days);
        verifier.finalizeApplication(TEST_USER);

        // Attempt Genesis application
        vm.prank(TEST_USER);
        vm.expectRevert(abi.encodeWithSignature("MedicalVerifier__AlreadyApplied()"));
        verifier.applyAsGenesis("Grace", "grace@email.com", "HID123", "");
    }

    // Test 9: Event emission check
    function test_applyAsGenesis_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        // Add contract reference for the event
        emit MedicalVerifier.NewGenesisApplication(TEST_USER);

        vm.prank(TEST_USER);
        verifier.applyAsGenesis("Hank", "hank@email.com", "ID321", "PA-Cert");
    }
}

contract MedicalVerifierEmergencyTest is Test {
    MedicalVerifier mv;
    address owner = address(999);
    address genesisMember = address(888);
    address applicant = address(1);

    function setUp() public {
        // Deploy contract
        vm.prank(owner);
        mv = new MedicalVerifier();

        // Setup genesis member
        vm.startPrank(genesisMember);
        mv.applyAsGenesis("Genesis", "contact", "govID", "docs");
        vm.stopPrank();

        vm.prank(owner);
        mv.handleGenesisApplication(genesisMember, true);
    }

    function test_EmergencyPause_OnlyOwner() public {
        address nonOwner = address(666);
        vm.prank(nonOwner);

        // Use correct error name from Ownable
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));

        mv.emergencyPause(1 days);
    }

    function test_EmergencyPause_PausesContract() public {
        // Create a valid applicant first
        vm.prank(applicant);
        mv.applyAsHealthProfessional("Dr. Test", "contact", "govID", "docs");

        // Genesis member votes to approve
        vm.prank(genesisMember);
        mv.voteOnApplication(applicant, true);

        // Finalize application
        vm.warp(block.timestamp + mv.VOTING_PERIOD());
        mv.finalizeApplication(applicant);

        // Test pause functionality
        vm.prank(owner);
        mv.emergencyPause(1 days);

        (bool paused,,) = mv.emergency();
        assertTrue(paused);

        // Verify contract is paused
        vm.prank(applicant);
        vm.expectRevert(MedicalVerifier.MedicalVerifier__UnauthorizedAccess.selector);
        mv.applyAsHealthProfessional("Dr. Test2", "contact", "govID", "docs");
    }

    function test_EmergencyOverrideLimits_DuringEmergency() public {
        vm.prank(owner);
        mv.emergencyPause(1 days);

        vm.prank(owner);
        mv.emergencyOverrideLimits(25, 25);

        assertEq(mv.maxHealthProfessionals(), 25);
        assertEq(mv.maxManualDaoVerifiers(), 25);
    }

    function test_EmergencyOverrideLimits_AfterExpiryFails() public {
        vm.prank(owner);
        mv.emergencyPause(1 days);

        vm.warp(block.timestamp + 2 days);

        vm.prank(owner);
        vm.expectRevert(MedicalVerifier.MedicalVerifier__UnauthorizedAccess.selector);
        mv.emergencyOverrideLimits(25, 25);
    }
}

contract DonationTests is Test {
    MedicalVerifier mv;
    address owner = address(999);
    address genesisMember = address(888);
    address daoMember = address(777);
    address donationHandler = address(666);
    address donor = address(1);

    function setUp() public {
        // Deploy contract
        vm.prank(owner);
        mv = new MedicalVerifier();

        // Setup Genesis committee
        vm.prank(genesisMember);
        mv.applyAsGenesis("Genesis", "contact", "govID", "docs");
        vm.prank(owner);
        mv.handleGenesisApplication(genesisMember, true);

        // Create and approve DAO member
        vm.startPrank(daoMember);
        mv.applyAsDaoVerifier("DAO Member", "contact", "govID");
        vm.stopPrank();

        vm.prank(genesisMember);
        mv.voteOnApplication(daoMember, true);

        vm.warp(block.timestamp + mv.VOTING_PERIOD());
        mv.finalizeApplication(daoMember);

        // Verify DAO approval
        (, MedicalVerifier.ApplicationStatus status,,) = mv.getVerifierData(daoMember);
        require(status == MedicalVerifier.ApplicationStatus.Approved, "DAO member not approved");

        // Set donation handler with verified DAO member
        vm.prank(daoMember);
        mv.setDonationHandler(donationHandler);

        // Confirm handler setup
        assertEq(mv.donationHandler(), donationHandler, "Donation handler not configured");
    }

    function test_RecordDonation_AutoDAOApproval() public {
        // Destructure emergency settings tuple
        (bool paused,,) = mv.emergency();
        assertFalse(paused, "Contract should not be paused");

        uint256 campaignId = 1;

        vm.startPrank(mv.donationHandler());
        for (uint256 i = 0; i < mv.MIN_CAMPAIGNS_REQUIRED(); i++) {
            mv.recordDonation(donor, campaignId + i, mv.MIN_DONATION() + 1);
        }
        vm.stopPrank();

        (MedicalVerifier.VerifierType vType,,,) = mv.getVerifierData(donor);
        assertEq(uint256(vType), uint256(MedicalVerifier.VerifierType.AutoDao));
        assertTrue(mv.hasNFT(donor));
    }
}

contract StringValidationTests is Test {
    MedicalVerifier mv;
    address owner = address(999);
    address genesisMember = address(888);
    address applicant1 = address(1);
    address applicant2 = address(2);

    function setUp() public {
        // Deploy contract
        vm.prank(owner);
        mv = new MedicalVerifier();

        // Setup and approve genesis member
        vm.prank(genesisMember);
        mv.applyAsGenesis("Genesis", "contact", "govID", "docs");
        vm.prank(owner);
        mv.handleGenesisApplication(genesisMember, true);

        // End genesis period by fast-forwarding time
        vm.warp(block.timestamp + mv.GENESIS_TIMEOUT() + 1);
        mv.checkGenesisTimeout();
    }

    function test_TrimFunction_MaxLengthAndWhitespace() public {
        // Test max allowed length
        string memory maxLenStr = string(new bytes(mv.MAX_STRING_LENGTH()));
        vm.prank(applicant1);
        mv.applyAsDaoVerifier(maxLenStr, "contact", "govId");

        // Test exceeding max length
        string memory tooLong = string(new bytes(mv.MAX_STRING_LENGTH() + 1));
        vm.prank(applicant2);
        vm.expectRevert(abi.encodeWithSelector(
            MedicalVerifier.MedicalVerifier__StringTooLong.selector,
            1
        ));
        mv.applyAsDaoVerifier(tooLong, "contact", "govId");
    }
}

contract RevocationTests is Test {
    MedicalVerifier mv;
    address owner = address(999);
    address genesisMember = address(888);

    function setUp() public {
        vm.prank(owner);
        mv = new MedicalVerifier();

        // Setup genesis member
        vm.prank(genesisMember);
        mv.applyAsGenesis("Genesis", "contact", "govID", "docs");
        vm.prank(owner);
        mv.handleGenesisApplication(genesisMember, true);

        // End Genesis period and convert to DAO
        vm.warp(block.timestamp + mv.GENESIS_TIMEOUT() + 1 days);

        mv.checkGenesisTimeout();

        // Update limits through DAO governance
        vm.prank(genesisMember); // Now converted to DAO
        mv.updateVerifierLimits(25, 25); // Increase DAO limit
    }

    function _createApprovedDaoMember(address user) internal {
        // Create and approve DAO member
        vm.prank(user);
        mv.applyAsDaoVerifier("DAO Member", "contact", "govID");

        vm.prank(genesisMember);
        mv.voteOnApplication(user, true);

        vm.warp(block.timestamp + mv.VOTING_PERIOD());
        mv.finalizeApplication(user);
    }

    function test_FinalizeRevocation_InvalidProposal() public {
        address nonExistent = address(999);
        vm.expectRevert(MedicalVerifier.MedicalVerifier__InvalidProposal.selector);
        mv.finalizeRevocation(nonExistent);
    }

    // function test_AutoRevoke_MissedVotes() public {
    //     address daoMember = address(111);
    //     _createApprovedDaoMember(daoMember);

    //     // Create MAX_MISSED_VOTES proposals that daoMember is required to vote on
    //     for (uint i = 0; i < mv.MAX_MISSED_VOTES(); i++) {
    //         address target = address(uint160(1000 + i));
    //         _createApprovedDaoMember(target);

    //         // Create a new proposal that daoMember needs to vote on
    //         address proposer = address(uint160(2000 + i));
    //         _createApprovedDaoMember(proposer);

    //         vm.prank(proposer);
    //         mv.proposeRevocation(target);

    //         // Fast-forward to end of voting period without daoMember voting
    //         vm.warp(block.timestamp + mv.VOTING_PERIOD());
    //         mv.finalizeRevocation(target);
    //     }

    //     // Check if daoMember was auto-revoked
    //     (, MedicalVerifier.ApplicationStatus status,,) = mv.getVerifierData(daoMember);
    //     assertEq(
    //         uint256(status),
    //         uint256(MedicalVerifier.ApplicationStatus.Revoked),
    //         "Should auto-revoke after missing votes"
    //     );
    // }
}

contract ProposeRevocationTests is Test {
    MedicalVerifier mv;
    address owner = address(999);
    address genesisMember = address(888);
    address healthPro = address(1);
    address daoMember = address(2);

    function setUp() public {
        // Deploy contract
        vm.prank(owner);
        mv = new MedicalVerifier();

        // Setup Genesis committee
        vm.prank(genesisMember);
        mv.applyAsGenesis("Genesis", "contact", "govID", "docs");
        vm.prank(owner);
        mv.handleGenesisApplication(genesisMember, true);

        // Create and approve health professional
        vm.prank(healthPro);
        mv.applyAsHealthProfessional("Dr. Alice", "contact", "govID", "docs");
        vm.prank(genesisMember);
        mv.voteOnApplication(healthPro, true);
        vm.warp(block.timestamp + mv.VOTING_PERIOD());
        mv.finalizeApplication(healthPro);

        // Create and approve DAO member
        vm.prank(daoMember);
        mv.applyAsDaoVerifier("Bob", "contact", "govID");
        vm.prank(genesisMember);
        mv.voteOnApplication(daoMember, true);
        vm.warp(block.timestamp + mv.VOTING_PERIOD());
        mv.finalizeApplication(daoMember);
    }

    function test_ProposeRevocation_UnauthorizedVerifierType() public {
        vm.prank(healthPro);
        vm.expectRevert(MedicalVerifier.MedicalVerifier__UnauthorizedRevocation.selector);
        mv.proposeRevocation(daoMember);
    }
}

contract GenesisTimeoutTests is Test {
    MedicalVerifier mv;
    address genesis1 = address(1);

    function setUp() public {
        mv = new MedicalVerifier();

        // Setup genesis member
        vm.prank(genesis1);
        mv.applyAsGenesis("Genesis", "contact", "govID", "docs");
        vm.prank(mv.owner());
        mv.handleGenesisApplication(genesis1, true);
    }

    function test_GenesisTimeout_ConvertsToDAO() public {
        assertTrue(mv.genesisActive());
        vm.warp(block.timestamp + mv.GENESIS_TIMEOUT() + 1);
        mv.checkGenesisTimeout();
        assertFalse(mv.genesisActive());

        (MedicalVerifier.VerifierType vType,,,) = mv.getVerifierData(genesis1);
        assertEq(uint256(vType), uint256(MedicalVerifier.VerifierType.Dao));
    }

    function test_GenesisTimeout_NotReached() public {
        vm.warp(block.timestamp + mv.GENESIS_TIMEOUT() - 1);
        mv.checkGenesisTimeout();
        assertTrue(mv.genesisActive(), "Genesis should still be active");
    }

    function test_GenesisTimeout_ExactTimeout() public {
        vm.warp(block.timestamp + mv.GENESIS_TIMEOUT());
        mv.checkGenesisTimeout();
        assertFalse(mv.genesisActive(), "Genesis should be inactive");
    }
}

contract SystemConfigTests is Test {
    MedicalVerifier mv;

    function setUp() public {
        mv = new MedicalVerifier();
    }

    function test_GetSystemConfig_ReturnsCorrectValues() public {
        (uint256 maxHP, uint256 maxDao,,) = mv.getSystemConfig();
        assertEq(maxHP, mv.maxHealthProfessionals());
        assertEq(maxDao, mv.maxManualDaoVerifiers());
    }
}

contract VerifierCountTests is Test {
    MedicalVerifier mv;
    address owner = address(999);
    address genesisMember = address(888);
    address applicant1 = address(1);
    address applicant2 = address(2);

    function setUp() public {
        // Deploy contract
        vm.prank(owner);
        mv = new MedicalVerifier();

        // Setup Genesis committee
        vm.prank(genesisMember);
        mv.applyAsGenesis("Genesis", "contact", "govID", "docs");
        vm.prank(owner);
        mv.handleGenesisApplication(genesisMember, true);

        // Create and approve health professional
        vm.prank(applicant1);
        mv.applyAsHealthProfessional("Dr. Alice", "contact", "govID", "docs");
        vm.prank(genesisMember);
        mv.voteOnApplication(applicant1, true);
        vm.warp(block.timestamp + mv.VOTING_PERIOD());
        mv.finalizeApplication(applicant1);

        // Create and approve DAO member
        vm.prank(applicant2);
        mv.applyAsDaoVerifier("Bob", "contact", "govID");
        vm.prank(genesisMember);
        mv.voteOnApplication(applicant2, true);
        vm.warp(block.timestamp + mv.VOTING_PERIOD());
        mv.finalizeApplication(applicant2);
    }

    function test_GetVerifierCounts_AfterApprovals() public {
        (uint256 hp, uint256 manualDao, uint256 autoDao) = mv.getVerifierCounts();
        assertEq(hp, 1, "Health professional count mismatch");
        assertEq(manualDao, 1, "DAO member count mismatch");
        assertEq(autoDao, 0, "AutoDAO count should be zero");
    }
}

contract NFTTransferTests is Test {
    MedicalVerifier mv;
    address holder = address(1);
    address genesisMember = address(999);
    address owner = address(888);

    function setUp() public {
        // Deploy contract
        vm.prank(owner);
        mv = new MedicalVerifier();

        // Setup Genesis committee
        vm.prank(genesisMember);
        mv.applyAsGenesis("Genesis Member", "contact", "govID", "docs");
        vm.prank(owner);
        mv.handleGenesisApplication(genesisMember, true);

        // Create DAO member through proper process
        vm.prank(holder);
        mv.applyAsDaoVerifier("DAO Holder", "contact", "govID");

        // Genesis member approves the DAO application
        vm.prank(genesisMember);
        mv.voteOnApplication(holder, true);

        // Finalize application
        vm.warp(block.timestamp + mv.VOTING_PERIOD());
        mv.finalizeApplication(holder);
    }

    function test_NFT_TransferReverts() public {
        (,,, uint256 tokenId) = mv.getVerifierData(holder);

        vm.prank(holder);
        vm.expectRevert(MedicalVerifier.MedicalVerifier__UnauthorizedAccess.selector);
        mv.safeTransferFrom(holder, address(2), tokenId);
    }
}

contract ApplicationTests is Test {
    MedicalVerifier mv;
    address applicant1 = address(1);
    address genesisMember = address(999);
    address owner = address(888);

    function setUp() public {
        vm.prank(owner);
        mv = new MedicalVerifier();

        // Setup genesis committee
        vm.prank(genesisMember);
        mv.applyAsGenesis("Genesis", "contact", "govID", "docs");

        vm.prank(owner);
        mv.handleGenesisApplication(genesisMember, true);
    }

    function test_ApplyHealthPro_InsufficientDocuments() public {
        vm.prank(applicant1);
        vm.expectRevert(
            abi.encodeWithSelector(
            MedicalVerifier.MedicalVerifier__EmptyField.selector,
            4
            )
        );
        mv.applyAsHealthProfessional("Dr. NoDocs", "contact", "govID", "");
    }
}
