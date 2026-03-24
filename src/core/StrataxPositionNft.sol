// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {
    ERC721EnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IFeeCollector} from "../interfaces/internal/IFeeCollector.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Stratax_Aave_1Inch as Stratax} from "./position-types/Stratax_Aave_1Inch.sol";
import {StrataxCalculations} from "../libraries/StrataxCalculations.sol";
import {IStrataxPositionAdapter} from "../interfaces/internal/IStrataxPositionAdapter.sol";
import {StrataxAaveLib} from "../libraries/lending/StrataxAaveLib.sol";

contract StrataxPositionNft is
    Initializable,
    ERC721Upgradeable,
    ERC721EnumerableUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    IERC721Receiver
{
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                            TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/
    using SafeERC20 for IERC20;

    /// @notice Struct for StrataxPositionNft initialization parameters
    struct StrataxPositionNftInitParams {
        /// @notice Address of the Stratax oracle
        address strataxOracle;
        address feeCollector;
        address configManager;
        /// @notice Address of the contract owner
        address owner;
        /// @notice Base URI for token metadata
        string uri;
    }

    /// @notice Shared configuration for a swap+lending combination.
    struct StrataxConfig {
        /// @notice Beacon address for this swap+lending combination
        address beacon;
        /// @notice Adapter address used by this swap+lending combination
        address adapter;
    }

    /// @notice Struct representing a leveraged position
    struct Position {
        /// @notice Address of the collateral token
        address collateralToken;
        /// @notice Address of the borrowed token
        address borrowToken;
        /// @notice Address of the deployed Stratax proxy contract for this position
        address strataxProxy;
        /// @notice Strategy id used to create this position
        bytes32 strategyId;
        /// @notice Swap protocol id used for this position
        bytes32 swapProtocolId;
        /// @notice Lending protocol id used for this position
        bytes32 lendingProtocolId;
        /// @notice Whether this position is currently active
        bool isActive;
        /// @notice Whether this position has been burned
        bool isBurned;
        /// @notice Timestamp when the position was created
        uint256 createdAt;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Protocol-id based shared config for adapter-driven pairs.
    mapping(bytes32 => mapping(bytes32 => StrataxConfig)) public protocolPairConfig;

    /// @notice Config data stored per lending protocol id.
    mapping(bytes32 => bytes) public lendingConfigByProtocolId;

    /// @notice Config data stored per swap protocol id.
    mapping(bytes32 => bytes) public swapConfigByProtocolId;

    /// @notice Pair adapter addresses keyed by lending+swap protocol ids.
    mapping(bytes32 => mapping(bytes32 => address)) public pairAdapterByProtocolIds;

    /// @notice Address of the Stratax oracle for initializing Stratax proxies
    address public strataxOracle;

    /// @notice Address of the fee collector for opening and closing positions
    address public feeCollector;

    /// @notice Contract authorized to manage encoded platform configs
    address public configManager;

    /// @notice Counter for token IDs (position types)
    uint256 public currentTokenId;

    /// @notice Mapping from token ID to position details
    mapping(uint256 => Position) public positions;

    mapping(address => uint256) public strataxAddressToTokenId;
    mapping(address => uint256) public callerCreate2SaltNonce;

    /// @notice Base URI for token metadata
    string private _baseTokenUri;

    /// @notice Storage gap for future upgrades
    uint256[45] private __gap;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new position NFT is minted
    /// @param tokenId The ID of the position
    /// @param owner The owner receiving the NFT
    /// @param strataxProxy Address of the deployed Stratax proxy contract
    /// @param collateralToken Address of the collateral token
    /// @param borrowToken Address of the borrowed token
    /// @param swapProtocolId The swap protocol id used
    /// @param lendingProtocolId The lending protocol id used
    event PositionMinted(
        uint256 indexed tokenId,
        address indexed owner,
        address strataxProxy,
        address collateralToken,
        address borrowToken,
        bytes32 swapProtocolId,
        bytes32 lendingProtocolId
    );

    /// @notice Emitted when a position NFT is burned
    /// @param tokenId The ID of the position
    /// @param owner The owner whose NFT was burned
    event PositionBurned(uint256 indexed tokenId, address indexed owner);

    /// @notice Emitted when the default borrow safety margin is updated
    /// @param oldMargin Previous default borrow safety margin
    /// @param newMargin New default borrow safety margin
    event DefaultBorrowSafetyMarginUpdated(uint256 indexed oldMargin, uint256 indexed newMargin);

    /// @notice Emitted when the default max leverage offset is updated
    /// @param oldOffset Previous default max leverage offset
    /// @param newOffset New default max leverage offset
    event DefaultMaxLeverageOffsetUpdated(uint256 indexed oldOffset, uint256 indexed newOffset);

    /// @notice Emitted when a caller salt nonce is incremented after a successful deployment
    /// @param caller The caller whose nonce was incremented
    /// @param previousNonce Previous nonce value
    /// @param newNonce New nonce value
    event CallerCreate2SaltNonceIncremented(address indexed caller, uint256 previousNonce, uint256 newNonce);

    /// @notice Emitted when flash loan fee is updated for a lending protocol id
    /// @param lendingProtocolId The lending protocol id
    /// @param newFeeBps New flash loan fee in basis points
    event PlatformFlashLoanFeeUpdated(bytes32 indexed lendingProtocolId, uint256 newFeeBps);

    event ConfigManagerUpdated(address indexed oldManager, address indexed newManager);

    event PairAdapterUpdated(
        bytes32 indexed lendingProtocolId, bytes32 indexed swapProtocolId, address indexed adapter
    );
    event ProtocolPairConfigUpdated(
        bytes32 indexed lendingProtocolId, bytes32 indexed swapProtocolId, address beacon, address adapter
    );
    event LendingProtocolConfigUpdated(bytes32 indexed lendingProtocolId);
    event SwapProtocolConfigUpdated(bytes32 indexed swapProtocolId);
    event PairAdapterOpenPositionSchemaUpdated(
        bytes32 indexed lendingProtocolId, bytes32 indexed swapProtocolId, bytes32 schemaId, uint16 schemaVersion
    );

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts function access to deployed Stratax proxy contracts only
    modifier onlyStrataxProxy(uint256 tokenId) {
        require(positions[tokenId].strataxProxy == msg.sender, "Caller must be Stratax proxy");
        _;
    }

    modifier onlyConfigManager() {
        require(msg.sender == configManager, "Caller must be config manager");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the StrataxPositionNft contract
    /// @dev Can only be called once due to initializer modifier
    /// @param params Initialization parameters struct
    function initialize(StrataxPositionNftInitParams calldata params) external initializer {
        require(params.strataxOracle != address(0), "Invalid Stratax oracle address");
        require(params.feeCollector != address(0), "Invalid fee collector address");
        require(params.configManager != address(0), "Invalid config manager");
        require(params.configManager.code.length > 0, "Config manager must be contract");
        require(params.owner != address(0), "Invalid owner address");

        __ERC721_init("Stratax Position NFT", "STRX-POS");
        __ERC721Enumerable_init();
        __Ownable_init(params.owner);

        _baseTokenUri = params.uri;
        strataxOracle = params.strataxOracle;
        feeCollector = params.feeCollector;
        configManager = params.configManager;
        currentTokenId = 1; // Start token IDs at 1
    }

    function setConfigManager(address newConfigManager) external onlyOwner {
        require(newConfigManager != address(0), "Invalid config manager");
        require(newConfigManager.code.length > 0, "Config manager must be contract");
        address oldManager = configManager;
        configManager = newConfigManager;
        emit ConfigManagerUpdated(oldManager, newConfigManager);
    }

    function setPairAdapter(bytes32 lendingProtocolId, bytes32 swapProtocolId, address adapter)
        external
        onlyConfigManager
    {
        require(adapter != address(0), "Invalid adapter");
        require(adapter.code.length > 0, "Adapter must be contract");
        pairAdapterByProtocolIds[lendingProtocolId][swapProtocolId] = adapter;
        emit PairAdapterUpdated(lendingProtocolId, swapProtocolId, adapter);
        emit PairAdapterOpenPositionSchemaUpdated(
            lendingProtocolId,
            swapProtocolId,
            IStrataxPositionAdapter(adapter).openPositionSchemaId(),
            IStrataxPositionAdapter(adapter).openPositionSchemaVersion()
        );
    }

    function getPairAdapterOpenPositionSchema(bytes32 lendingProtocolId, bytes32 swapProtocolId)
        external
        view
        returns (bytes32 schemaId, uint16 schemaVersion)
    {
        address adapterAddress = pairAdapterByProtocolIds[lendingProtocolId][swapProtocolId];
        require(adapterAddress != address(0), "Pair adapter not configured");
        IStrataxPositionAdapter adapter = IStrataxPositionAdapter(adapterAddress);
        schemaId = adapter.openPositionSchemaId();
        schemaVersion = adapter.openPositionSchemaVersion();
    }

    function setProtocolPairConfig(bytes32 lendingProtocolId, bytes32 swapProtocolId, address beacon, address adapter)
        public
        onlyConfigManager
    {
        require(beacon != address(0), "Invalid beacon address");
        StrataxConfig memory existingConfig = protocolPairConfig[lendingProtocolId][swapProtocolId];
        if (existingConfig.beacon != address(0)) {
            require(existingConfig.beacon == beacon, "Beacon already set");
        }

        StrataxConfig memory config = StrataxConfig({beacon: beacon, adapter: adapter});
        protocolPairConfig[lendingProtocolId][swapProtocolId] = config;

        emit ProtocolPairConfigUpdated(lendingProtocolId, swapProtocolId, config.beacon, config.adapter);
    }

    function setLendingProtocolConfig(bytes32 lendingProtocolId, bytes calldata configData) external onlyConfigManager {
        require(configData.length > 0, "Missing lending config");
        lendingConfigByProtocolId[lendingProtocolId] = configData;
        emit LendingProtocolConfigUpdated(lendingProtocolId);
    }

    function setSwapProtocolConfig(bytes32 swapProtocolId, bytes calldata configData) external onlyConfigManager {
        require(configData.length > 0, "Missing swap config");
        swapConfigByProtocolId[swapProtocolId] = configData;
        emit SwapProtocolConfigUpdated(swapProtocolId);
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    struct MintPositionParams {
        uint256 collateralAmount;
        uint256 leverage;
        uint256 minSwapAmountOut;
        bytes data;
    }

    function mintPositionByProtocolIds(
        address to,
        address collateralToken,
        address borrowToken,
        bytes32 lendingProtocolId,
        bytes32 swapProtocolId,
        bool _openInitPosition,
        bytes calldata _initTradeParams
    ) public returns (uint256 tokenId, address strataxProxy) {
        return _mintPositionByProtocolIds(
            to, collateralToken, borrowToken, lendingProtocolId, swapProtocolId, _openInitPosition, _initTradeParams
        );
    }

    // Deprecated compatibility overload: converts old struct params to adapter-encoded bytes.
    function mintPositionByProtocolIds(
        address to,
        address collateralToken,
        address borrowToken,
        bytes32 lendingProtocolId,
        bytes32 swapProtocolId,
        bool _openInitPosition,
        MintPositionParams memory _initParams
    ) public returns (uint256 tokenId, address strataxProxy) {
        bytes memory encodedInitParams;
        if (_openInitPosition && _initParams.collateralAmount > 0) {
            address adapterAddress = pairAdapterByProtocolIds[lendingProtocolId][swapProtocolId];
            require(adapterAddress != address(0), "Pair adapter not configured");
            encodedInitParams = IStrataxPositionAdapter(adapterAddress)
                .encodeOpenPositionData(
                    _initParams.collateralAmount, _initParams.leverage, _initParams.minSwapAmountOut, _initParams.data
                );
        }

        return _mintPositionByProtocolIds(
            to, collateralToken, borrowToken, lendingProtocolId, swapProtocolId, _openInitPosition, encodedInitParams
        );
    }

    function _mintPositionByProtocolIds(
        address to,
        address collateralToken,
        address borrowToken,
        bytes32 lendingProtocolId,
        bytes32 swapProtocolId,
        bool _openInitPosition,
        bytes memory _initTradeParams
    ) internal returns (uint256 tokenId, address strataxProxy) {
        require(to != address(0), "Cannot mint to zero address");

        address adapterAddress = pairAdapterByProtocolIds[lendingProtocolId][swapProtocolId];
        require(adapterAddress != address(0), "Pair adapter not configured");

        StrataxConfig memory config = protocolPairConfig[lendingProtocolId][swapProtocolId];
        require(config.beacon != address(0), "Pair config not configured");

        bytes memory lendingConfigData = lendingConfigByProtocolId[lendingProtocolId];
        bytes memory swapConfigData = swapConfigByProtocolId[swapProtocolId];
        require(lendingConfigData.length > 0, "Lending config missing");
        require(swapConfigData.length > 0, "Swap config missing");

        IStrataxPositionAdapter adapter = IStrataxPositionAdapter(adapterAddress);
        require(
            adapter.validateLendingTokens(collateralToken, borrowToken, lendingConfigData),
            "Invalid lending token pair for protocol"
        );
        require(
            adapter.validateSwapTokens(collateralToken, borrowToken, swapConfigData),
            "Invalid swap token pair for protocol"
        );

        tokenId = currentTokenId++;

        bytes memory strataxInitConfig = abi.encode(
            config.beacon, address(this), tokenId, strataxOracle, feeCollector, collateralToken, borrowToken
        );
        bytes32 deploymentSalt = getEffectiveCallerCreate2Salt(msg.sender);
        strataxProxy = adapter.deployAndInitialize(lendingConfigData, swapConfigData, strataxInitConfig, deploymentSalt);

        uint256 previousNonce = callerCreate2SaltNonce[msg.sender];
        callerCreate2SaltNonce[msg.sender] = previousNonce + 1;
        emit CallerCreate2SaltNonceIncremented(msg.sender, previousNonce, previousNonce + 1);

        positions[tokenId] = Position({
            collateralToken: collateralToken,
            borrowToken: borrowToken,
            strataxProxy: strataxProxy,
            strategyId: bytes32(0),
            swapProtocolId: swapProtocolId,
            lendingProtocolId: lendingProtocolId,
            isActive: true,
            isBurned: false,
            createdAt: block.timestamp
        });
        strataxAddressToTokenId[strataxProxy] = tokenId;

        if (_openInitPosition && _initTradeParams.length > 0) {
            uint256 collateralAmount = abi.decode(_initTradeParams, (uint256));
            require(collateralAmount > 0, "Init collateral must be > 0");

            _safeMint(address(adapter), tokenId);
            IERC20(collateralToken).safeTransferFrom(msg.sender, address(adapter), collateralAmount);
            IERC20(collateralToken).forceApprove(strataxProxy, collateralAmount);

            adapter.openPosition(tokenId, strataxProxy, _initTradeParams);
            // the adapter must give approval to ensure the token is sent to the owner
            _safeTransfer(address(adapter), to, tokenId, "");
        } else {
            _safeMint(to, tokenId);
        }

        emit PositionMinted(tokenId, to, strataxProxy, collateralToken, borrowToken, swapProtocolId, lendingProtocolId);
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
        positions[tokenId].isBurned = true;

        _burn(tokenId);

        emit PositionBurned(tokenId, owner);
    }

    /**
     * @notice Sets the base URI for token metadata
     * @dev Can only be called by the contract owner
     * @param baseUri The new base URI
     */
    function setBaseURI(string memory baseUri) external onlyOwner {
        _baseTokenUri = baseUri;
    }

    function setDefaultBorrowSafetyMargin(bytes32 lendingProtocolId, uint256 _borrowSafetyMargin)
        public
        onlyConfigManager
    {
        require(_borrowSafetyMargin < StrataxCalculations.BORROW_SAFETY_PRECISION, "Invlaid borrowSafetMargin");
        StrataxAaveLib.InitParams memory lendingConfig = _decodeAaveConfig(lendingConfigByProtocolId[lendingProtocolId]);
        uint256 oldMargin = lendingConfig.defaultBorrowSafetyMargin;
        lendingConfig.defaultBorrowSafetyMargin = _borrowSafetyMargin;
        lendingConfigByProtocolId[lendingProtocolId] = abi.encode(lendingConfig);
        emit DefaultBorrowSafetyMarginUpdated(oldMargin, _borrowSafetyMargin);
    }

    function setDefaultMaxLeverageOffset(bytes32 lendingProtocolId, uint256 _maxLeverageOffset)
        public
        onlyConfigManager
    {
        require(_maxLeverageOffset <= 500, "Max leverage offset too high");
        StrataxAaveLib.InitParams memory lendingConfig = _decodeAaveConfig(lendingConfigByProtocolId[lendingProtocolId]);
        uint256 oldOffset = lendingConfig.defaultMaxLeverageOffset;
        lendingConfig.defaultMaxLeverageOffset = _maxLeverageOffset;
        lendingConfigByProtocolId[lendingProtocolId] = abi.encode(lendingConfig);
        emit DefaultMaxLeverageOffsetUpdated(oldOffset, _maxLeverageOffset);
    }

    function getDefaultBorrowSafetyMargin(bytes32 lendingProtocolId) public view returns (uint256) {
        StrataxAaveLib.InitParams memory lendingConfig = _decodeAaveConfig(lendingConfigByProtocolId[lendingProtocolId]);
        return lendingConfig.defaultBorrowSafetyMargin;
    }

    function getDefaultMaxLeverageOffset(bytes32 lendingProtocolId) public view returns (uint256) {
        StrataxAaveLib.InitParams memory lendingConfig = _decodeAaveConfig(lendingConfigByProtocolId[lendingProtocolId]);
        return lendingConfig.defaultMaxLeverageOffset;
    }

    function updateProtocolFlashLoanFee(bytes32 lendingProtocolId, uint256 newFeeBps) public onlyConfigManager {
        require(newFeeBps < StrataxCalculations.FLASHLOAN_FEE_PREC, "Invalid flash loan fee");
        StrataxAaveLib.InitParams memory lendingConfig = _decodeAaveConfig(lendingConfigByProtocolId[lendingProtocolId]);
        lendingConfig.flashLoanFeeBps = newFeeBps;
        lendingConfigByProtocolId[lendingProtocolId] = abi.encode(lendingConfig);
        emit PlatformFlashLoanFeeUpdated(lendingProtocolId, newFeeBps);
    }

    /**
     * @notice Returns the effective CREATE2 salt for a caller
     * @dev Salt is derived from caller address and the caller's current salt nonce.
     * @param caller Caller address
     * @return salt Effective CREATE2 salt used for deployment and prediction
     */
    function getEffectiveCallerCreate2Salt(address caller) public view returns (bytes32 salt) {
        salt = keccak256(abi.encodePacked(caller, callerCreate2SaltNonce[caller]));
    }

    function _decodeAaveConfig(bytes memory data) internal pure returns (StrataxAaveLib.InitParams memory config) {
        require(data.length > 0, "Missing lending config");
        config = abi.decode(data, (StrataxAaveLib.InitParams));
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
        return getPositionsByOwner(owner, 0, balanceOf(owner));
    }

    /**
     * @notice Returns positions owned by an address in the index range [startIndex, endIndex)
     * @param owner The address to query
     * @param startIndex The starting owner-token index (inclusive)
     * @param endIndex The ending owner-token index (exclusive)
     * @return tokenIds Array of token IDs owned by the address in the requested range
     * @return positionList Array of position structs in the requested range
     */
    function getPositionsByOwner(address owner, uint256 startIndex, uint256 endIndex)
        public
        view
        returns (uint256[] memory tokenIds, Position[] memory positionList)
    {
        uint256 balance = balanceOf(owner);
        require(startIndex <= endIndex, "Invalid index range");
        require(endIndex <= balance, "Index out of bounds");

        uint256 rangeLength = endIndex - startIndex;
        tokenIds = new uint256[](rangeLength);
        positionList = new Position[](rangeLength);

        for (uint256 i = 0; i < rangeLength; i++) {
            uint256 tokenId = tokenOfOwnerByIndex(owner, startIndex + i);
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
        return currentTokenId - 1;
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
     * @notice Returns on-chain metadata for a position NFT
     * @dev Metadata includes live position USD value and cumulative trading volume (USD)
     * sourced from the Stratax proxy and FeeCollector contracts
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_ownerOf(tokenId) != address(0), "ERC721Metadata: URI query for nonexistent token");

        Position memory position = positions[tokenId];
        uint256 positionUsdValue = Stratax(position.strataxProxy).getPositionUsdValue();
        uint256 cumulativeTradeVolume = IFeeCollector(feeCollector).strataxTradeVolume(position.strataxProxy);

        string memory imageUri =
            bytes(_baseTokenUri).length == 0 ? "" : string.concat(_baseTokenUri, Strings.toString(tokenId));

        string memory json = Base64.encode(
            abi.encodePacked(
                '{"name":"Stratax Position #',
                Strings.toString(tokenId),
                '","description":"Dynamic NFT metadata for a Stratax leveraged position.","image":"',
                imageUri,
                '","attributes":[{"trait_type":"Position USD Value","display_type":"number","value":',
                Strings.toString(positionUsdValue),
                '},{"trait_type":"Cumulative Trade Volume USD","display_type":"number","value":',
                Strings.toString(cumulativeTradeVolume),
                '},{"trait_type":"Collateral Token","value":"',
                Strings.toHexString(uint256(uint160(position.collateralToken)), 20),
                '"},{"trait_type":"Borrow Token","value":"',
                Strings.toHexString(uint256(uint160(position.borrowToken)), 20),
                '"},{"trait_type":"Stratax Proxy","value":"',
                Strings.toHexString(uint256(uint160(position.strataxProxy)), 20),
                '"}]}'
            )
        );

        return string.concat("data:application/json;base64,", json);
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
        return interfaceId == type(IERC721Receiver).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @notice Handle the receipt of an NFT
     * @dev The ERC721 smart contract calls this function on the recipient
     * after a `safeTransfer`. This function MUST return the function selector,
     * otherwise the caller will revert the transaction.
     * @param operator The address which called `safeTransferFrom` function
     * @param from The address which previously owned the token
     * @param tokenId The NFT identifier which is being transferred
     * @param data Additional data with no specified format
     * @return bytes4 `bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))`
     */
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        pure
        override
        returns (bytes4)
    {
        return this.onERC721Received.selector;
    }

    /**
     * @notice Authorizes contract upgrades
     * @dev Required by UUPSUpgradeable - only allows owner to upgrade
     * @param newImplementation The address of the new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
