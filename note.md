// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract MedicalVerifier is ERC721, Ownable, ReentrancyGuard {
    // Custom Errors
    error InvalidRequest();
    error LimitReached();
    error Unauthorized();
    error InvalidInput();
    
    // Constants
    uint256 private constant MAX_LENGTH = 56;
    uint256 private constant VOTING_PERIOD = 7 days;
    uint256 private constant GENESIS_TIMEOUT = 90 days;
    
    // State
    uint256 private _tokenId;
    uint256 public maxHealth = 20;
    uint256 public maxDAO = 20;
    uint256 public currentHealth;
    uint256 public currentDAO;
    bool public genesisActive = true;
    uint256 public genesisStart = block.timestamp;
    
    struct Docs {
        string name;
        string contact;
        string govID;
        string proof;
    }
    
    struct Verifier {
        uint8 vType; // 1-4
        uint8 status; // 0-4
        Docs docs;
        uint256 tokenId;
    }
    
    mapping(address => Verifier) public verifiers;
    mapping(address => bool) public hasNFT;
    mapping(address => mapping(address => bool)) public votes;
    
    event Applied(address applicant, uint8 vType);
    event Approved(address applicant);
    event Minted(address to, uint256 id);

    constructor() ERC721("MedVerify", "MDV") Ownable(msg.sender) {}

    // Main Application
    function apply(
        uint8 vType,
        string memory name,
        string memory contact,
        string memory govID,
        string memory proof
    ) external {
        _checkGenesis();
        _validateStrings(name, contact, govID, proof);
        
        Verifier storage v = verifiers[msg.sender];
        if (v.vType != 0) revert InvalidRequest();
        
        verifiers[msg.sender] = Verifier({
            vType: vType,
            status: 0,
            docs: Docs(_trim(name), _trim(contact), _trim(govID), _trim(proof)),
            tokenId: 0
        });
        
        emit Applied(msg.sender, vType);
    }

    // Voting System
    function vote(address applicant, bool support) external nonReentrant {
        _checkGenesis();
        Verifier storage voter = verifiers[msg.sender];
        Verifier storage target = verifiers[applicant];
        
        if (voter.status != 1 || target.status != 0) revert Unauthorized();
        if (votes[msg.sender][applicant]) revert InvalidRequest();
        
        votes[msg.sender][applicant] = true;
        _processVote(applicant, support);
    }

    // Internal Helpers
    function _processVote(address applicant, bool support) private {
        Verifier storage target = verifiers[applicant];
        uint256 threshold = target.vType == 1 ? currentHealth : currentDAO;
        
        if (support) {
            if (target.vType == 1 && currentHealth++ >= maxHealth) revert LimitReached();
            if (target.vType == 2 && currentDAO++ >= maxDAO) revert LimitReached();
            
            target.status = 1;
            _mintNFT(applicant);
            emit Approved(applicant);
        }
    }

    function _mintNFT(address to) private {
        _tokenId++;
        _safeMint(to, _tokenId);
        hasNFT[to] = true;
        verifiers[to].tokenId = _tokenId;
        emit Minted(to, _tokenId);
    }

    function _checkGenesis() private {
        if (genesisActive && block.timestamp > genesisStart + GENESIS_TIMEOUT) {
            genesisActive = false;
        }
    }

    function _validateStrings(
        string memory name,
        string memory contact,
        string memory govID,
        string memory proof
    ) private pure {
        if (bytes(name).length == 0 || bytes(name).length > MAX_LENGTH) revert InvalidInput();
        if (bytes(contact).length == 0 || bytes(contact).length > MAX_LENGTH) revert InvalidInput();
        if (bytes(govID).length == 0 || bytes(govID).length > MAX_LENGTH) revert InvalidInput();
        if (bytes(proof).length == 0 || bytes(proof).length > MAX_LENGTH) revert InvalidInput();
    }

    function _trim(string memory str) private pure returns (string memory) {
        bytes memory b = bytes(str);
        uint256 start;
        uint256 end = b.length;
        while (start < end && b[start] == ' ') start++;
        while (end > start && b[end-1] == ' ') end--;
        return string(b[start:end]);
    }

    // Security Overrides
    function _update(address to, uint256 id, address auth)
        internal
        override
        returns (address)
    {
        address from = _ownerOf(id);
        if (from != address(0)) revert Unauthorized();
        return super._update(to, id, auth);
    }

    // Views
    function isVerified(address _addr) public view returns (bool) {
        Verifier storage v = verifiers[_addr];
        return v.status == 1;
    }
}