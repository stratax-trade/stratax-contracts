// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {
    ERC721EnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Stratax} from "./Stratax.sol";

contract StrataxPositionNft is Initializable, ERC721Upgradeable, ERC721EnumerableUpgradeable, OwnableUpgradeable {
    /*//////////////////////////////////////////////////////////////
                            TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Struct for StrataxPositionNft initialization parameters
    struct StrataxPositionNftInitParams {
        /// @notice Address of the Stratax beacon for deploying proxies
        address strataxBeacon;
        /// @notice Address of the Aave pool
        address aavePool;
        /// @notice Address of the Aave data provider
        address aaveDataProvider;
        /// @notice Address of the 1inch router
        address oneInchRouter;
        /// @notice Address of the Stratax oracle
        address strataxOracle;
        address feeCollector;
        /// @notice Address of the contract owner
        address owner;
        /// @notice Base URI for token metadata
        string uri;
    }

    /// @notice Struct representing a leveraged position
    struct Position {
        /// @notice Address of the collateral token
        address collateralToken;
        /// @notice Address of the borrowed token
        address borrowToken;
        /// @notice Address of the deployed Stratax proxy contract for this position
        address strataxProxy;
        /// @notice Timestamp when the position was created
        uint256 createdAt;
        /// @notice Timestamp when the position was last modified
        uint256 lastModifiedAt;
        /// @notice Whether this position is currently active
        bool isActive;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice precision for the defaultBorrowSafetyMargin
    uint256 public constant BORROW_SAFETY_PRECISION = 1e4;

    /// @notice Address of the Stratax Beacon for deploying proxy contracts
    address public strataxBeacon;

    /// @notice Address of the Aave pool for initializing Stratax proxies
    address public aavePool;

    /// @notice Address of the Aave data provider for initializing Stratax proxies
    address public aaveDataProvider;

    /// @notice Address of the 1inch router for initializing Stratax proxies
    address public oneInchRouter;

    /// @notice Address of the Stratax oracle for initializing Stratax proxies
    address public strataxOracle;

    /// @notice Address of the fee collector for opening and closing positions
    address public feeCollector;

    /// @notice the default value which can be changed by the NFT owner
    uint256 public defaultBorrowSafetyMargin;

    /// @notice Counter for token IDs (position types)
    uint256 private _nextTokenId;

    /// @notice Mapping from token ID to position details
    mapping(uint256 => Position) public positions;

    /// @notice Base URI for token metadata
    string private _baseTokenUri;

    /// @notice Storage gap for future upgrades
    uint256[50] private __gap;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new position NFT is minted
    /// @param tokenId The ID of the position
    /// @param owner The owner receiving the NFT
    /// @param strataxProxy Address of the deployed Stratax proxy contract
    /// @param collateralToken Address of the collateral token
    /// @param borrowToken Address of the borrowed token
    event PositionMinted(
        uint256 indexed tokenId,
        address indexed owner,
        address strataxProxy,
        address collateralToken,
        address borrowToken
    );

    /// @notice Emitted when a position NFT is burned
    /// @param tokenId The ID of the position
    /// @param owner The owner whose NFT was burned
    event PositionBurned(uint256 indexed tokenId, address indexed owner);

    /// @notice Emitted when the Stratax Beacon address is updated
    /// @param oldBeacon Previous Stratax beacon address
    /// @param newBeacon New Stratax beacon address
    event StrataxBeaconUpdated(address indexed oldBeacon, address indexed newBeacon);

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts function access to deployed Stratax proxy contracts only
    modifier onlyStrataxProxy(uint256 tokenId) {
        require(positions[tokenId].strataxProxy == msg.sender, "Caller must be Stratax proxy");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the StrataxPositionNft contract
    /// @dev Can only be called once due to initializer modifier
    /// @param params Initialization parameters struct
    function initialize(StrataxPositionNftInitParams calldata params) external initializer {
        require(params.strataxBeacon != address(0), "Invalid Stratax beacon address");
        require(params.aavePool != address(0), "Invalid Aave pool address");
        require(params.aaveDataProvider != address(0), "Invalid Aave data provider address");
        require(params.oneInchRouter != address(0), "Invalid 1inch router address");
        require(params.strataxOracle != address(0), "Invalid Stratax oracle address");
        require(params.owner != address(0), "Invalid owner address");

        __ERC721_init("Stratax Position NFT", "STRX-POS");
        __ERC721Enumerable_init();
        __Ownable_init(params.owner);

        _baseTokenUri = params.uri;

        strataxBeacon = params.strataxBeacon;
        aavePool = params.aavePool;
        aaveDataProvider = params.aaveDataProvider;
        oneInchRouter = params.oneInchRouter;
        strataxOracle = params.strataxOracle;
        feeCollector = params.feeCollector;
        defaultBorrowSafetyMargin = 9900; // Default to 99% of max LTV
        _nextTokenId = 1; // Start token IDs at 1
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Mints a new position NFT and deploys a dedicated Stratax proxy contract
     * @dev Deploys a new BeaconProxy for each position to hold position data
     * @param to Address to mint the tokens to
     * @param collateralToken Address of the collateral token
     * @param borrowToken Address of the borrowed token
     * @return tokenId The ID of the newly created position type
     * @return strataxProxy Address of the deployed Stratax proxy contract
     */
    function mintPositionNft(address to, address collateralToken, address borrowToken)
        external
        returns (uint256 tokenId, address strataxProxy)
    {
        require(to != address(0), "Cannot mint to zero address");

        tokenId = _nextTokenId++;

        // Prepare initialization parameters
        Stratax.StrataxInitParams memory initParams = Stratax.StrataxInitParams({
            aavePool: aavePool,
            aaveDataProvider: aaveDataProvider,
            oneInchRouter: oneInchRouter,
            strataxPositionNft: address(this),
            tokenId: tokenId,
            collateralToken: collateralToken,
            borrowToken: borrowToken,
            strataxOracle: strataxOracle,
            feeCollector: feeCollector,
            borrowSafetyMargin: defaultBorrowSafetyMargin
        });

        // Deploy a new Stratax proxy contract for this position
        bytes memory initData = abi.encodeWithSignature(
            "initialize((address,address,address,address,uint256,address,address,address,address,uint256))", initParams
        );

        strataxProxy = address(new BeaconProxy(strataxBeacon, initData));

        // Create position data
        positions[tokenId] = Position({
            collateralToken: collateralToken,
            borrowToken: borrowToken,
            strataxProxy: strataxProxy,
            createdAt: block.timestamp,
            lastModifiedAt: block.timestamp,
            isActive: true
        });

        // Mint the NFT
        _safeMint(to, tokenId);

        emit PositionMinted(tokenId, to, strataxProxy, collateralToken, borrowToken);

        return (tokenId, strataxProxy);
    }

    /**
     * @notice Burns a position NFT
     * @dev Can only be called by the position's Stratax proxy contract
     * @param tokenId The ID of the position
     */
    function burn(uint256 tokenId) external onlyStrataxProxy(tokenId) {
        address owner = ownerOf(tokenId);

        // Update position state
        positions[tokenId].isActive = false;
        positions[tokenId].lastModifiedAt = block.timestamp;

        _burn(tokenId);

        emit PositionBurned(tokenId, owner);
    }

    /**
     * @notice Sets the base URI for token metadata
     * n     * @dev Can only be called by the contract owner
     * @param baseUri The new base URI
     */
    function setBaseURI(string memory baseUri) external onlyOwner {
        _baseTokenUri = baseUri;
    }

    function setDefaultBorrowSafetyMargin(uint256 _borrowSafetyMargin) public onlyOwner {
        require(_borrowSafetyMargin < BORROW_SAFETY_PRECISION, "Invlaid borrowSafetMargin");
        defaultBorrowSafetyMargin = _borrowSafetyMargin;
    }

    /*//////////////////////////////////////////////////////////////
                        PUBLIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the position details for a given token ID
     * @param tokenId The ID of the position
     * @return position The position struct
     */
    function getPosition(uint256 tokenId) public view returns (Position memory position) {
        require(_ownerOf(tokenId) != address(0), "Position does not exist");
        return positions[tokenId];
    }

    /**
     * @notice Returns the Stratax proxy address for a given token ID
     * @param tokenId The ID of the position
     * @return strataxProxy The address of the deployed Stratax proxy contract
     */
    function getStrataxProxy(uint256 tokenId) public view returns (address strataxProxy) {
        require(_ownerOf(tokenId) != address(0), "Position does not exist");
        return positions[tokenId].strataxProxy;
    }

    /**
     * @notice Returns all positions owned by an address
     * @param owner The address to query
     * @return tokenIds Array of token IDs owned by the address
     * @return positionList Array of position structs
     */
    function getPositionsByOwner(address owner)
        public
        view
        returns (uint256[] memory tokenIds, Position[] memory positionList)
    {
        uint256 balance = balanceOf(owner);
        tokenIds = new uint256[](balance);
        positionList = new Position[](balance);

        for (uint256 i = 0; i < balance; i++) {
            uint256 tokenId = tokenOfOwnerByIndex(owner, i);
            tokenIds[i] = tokenId;
            positionList[i] = positions[tokenId];
        }

        return (tokenIds, positionList);
    }

    /**
     * @notice Returns the total number of position types ever created
     * @return count The total count of position types
     */
    function getTotalPositionsCreated() public view returns (uint256 count) {
        return _nextTokenId - 1;
    }

    /**
     * @notice Checks if a token ID exists
     * @param tokenId The ID to check
     * @return True if the token exists
     */
    function exists(uint256 tokenId) public view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the base URI for computing tokenURI
     * @return The base URI string
     */
    function _baseURI() internal view override returns (string memory) {
        return _baseTokenUri;
    }

    /**
     * @notice Hook that is called before any token transfer
     * @dev Required override for ERC721Enumerable
     */
    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    /**
     * @notice Required override for ERC721Enumerable
     */
    function _increaseBalance(address account, uint128 value)
        internal
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
    {
        super._increaseBalance(account, value);
    }

    /**
     * @notice See {IERC165-supportsInterface}
     * @dev Required override for ERC721Enumerable
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
