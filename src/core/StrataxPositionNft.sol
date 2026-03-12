// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {
    ERC721EnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IProtocolDataProvider} from "../interfaces/external/IProtocolDataProvider.sol";
import {IStrataxOracle} from "../interfaces/internal/IStrataxOracle.sol";
import {IFeeCollector} from "../interfaces/internal/IFeeCollector.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPool} from "../interfaces/external/IPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Stratax} from "./Stratax.sol";
import {StrataxCalculations} from "../libraries/StrataxCalculations.sol";

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
        /// @notice Whether this position is currently active
        bool isActive;
        /// @notice Whether this position has been burned
        bool isBurned;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

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

    /// @notice the default value for safety margin which can be modified by the NFT owner
    uint256 public defaultBorrowSafetyMargin;

    /// @notice Default offset from maximum leverage with 4 decimals (e.g., 75 = 0.75%)
    uint256 public defaultMaxLeverageOffset;

    /// @notice flash loan fee bps from Aave pool, cached for gas optimization
    uint256 public flashLoanFeeBps;

    /// @notice Counter for token IDs (position types)
    uint256 public currentTokenId;

    /// @notice Mapping from token ID to position details
    mapping(uint256 => Position) public positions;

    mapping(address => uint256) public strataxAddressToTokenId;

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

    /// @notice Emitted when the default borrow safety margin is updated
    /// @param oldMargin Previous default borrow safety margin
    /// @param newMargin New default borrow safety margin
    event DefaultBorrowSafetyMarginUpdated(uint256 indexed oldMargin, uint256 indexed newMargin);

    /// @notice Emitted when the Aave flash loan fee is updated
    /// @param oldFeeBps Previous flash loan fee in basis points
    /// @param newFeeBps New flash loan fee in basis points
    event AaveFlashLoanFeeUpdated(uint256 indexed newFeeBps, uint256 indexed oldFeeBps);

    /// @notice Emitted when the default max leverage offset is updated
    /// @param oldOffset Previous default max leverage offset
    /// @param newOffset New default max leverage offset
    event DefaultMaxLeverageOffsetUpdated(uint256 indexed oldOffset, uint256 indexed newOffset);

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
        require(params.feeCollector != address(0), "Invalid fee collector address");
        require(params.owner != address(0), "Invalid owner address");

        __ERC721_init("Stratax Position NFT", "STRX-POS");
        __ERC721Enumerable_init();
        __Ownable_init(params.owner);

        flashLoanFeeBps = IPool(params.aavePool).FLASHLOAN_PREMIUM_TOTAL();
        _baseTokenUri = params.uri;
        strataxBeacon = params.strataxBeacon;
        aavePool = params.aavePool;
        aaveDataProvider = params.aaveDataProvider;
        oneInchRouter = params.oneInchRouter;
        strataxOracle = params.strataxOracle;
        feeCollector = params.feeCollector;

        //default deployment settings
        defaultBorrowSafetyMargin = 9950; // Default to 99.5% of max LTV
        defaultMaxLeverageOffset = 75;

        currentTokenId = 1; // Start token IDs at 1
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    struct InitPositionParams {
        uint256 flashLoanAmount;
        uint256 collateralAmount;
        uint256 borrowAmount;
        bytes oneInchSwapData;
        uint256 minReturnAmount;
    }

    /**
     * @notice Calculates the flash loan and borrow amounts needed for opening a position when minting
     * @dev Uses the shared StrataxCalculations library for consistent calculation logic
     * @param collateralToken Address of the collateral token
     * @param borrowToken Address of the borrow token
     * @param collateralAmount Amount of collateral the user will provide
     * @param desiredLeverage Desired leverage multiplier with 4 decimals (e.g., 30000 = 3x)
     * @return flashLoanAmount The amount to flash loan (in collateral token units)
     * @return borrowAmount The amount to borrow from Aave (in borrow token units)
     * @return strataxFee The Stratax protocol fee amount
     */
    function calculateInitOpenParams(
        address collateralToken,
        address borrowToken,
        uint256 collateralAmount,
        uint256 desiredLeverage
    ) public view returns (uint256 flashLoanAmount, uint256 borrowAmount, uint256 strataxFee) {
        require(collateralAmount > 0, "Collateral must be > 0");
        require(desiredLeverage >= StrataxCalculations.LEVERAGE_PRECISION, "Leverage must be >= 1x");

        // Validate tokens
        _validateTokens(collateralToken, borrowToken);

        // Get token decimals
        uint256 collateralTokenDecimals = IERC20Metadata(collateralToken).decimals();
        uint256 borrowTokenDecimals = IERC20Metadata(borrowToken).decimals();

        // Get LTV from Aave
        (, uint256 ltv,,,,,,,,) = IProtocolDataProvider(aaveDataProvider).getReserveConfigurationData(collateralToken);
        require(ltv > 0, "Asset not usable as collateral");

        // Get prices from oracle
        uint256 collateralTokenPrice = IStrataxOracle(strataxOracle).getPrice(collateralToken);
        uint256 borrowTokenPrice = IStrataxOracle(strataxOracle).getPrice(borrowToken);
        require(collateralTokenPrice > 0, "Collateral token price must be > 0");
        require(borrowTokenPrice > 0, "Borrow token price must be > 0");

        // Prepare calculation parameters
        StrataxCalculations.CalcParams memory calcParams = StrataxCalculations.CalcParams({
            desiredLeverage: desiredLeverage,
            collateralAmount: collateralAmount,
            collateralTokenPrice: collateralTokenPrice,
            borrowTokenPrice: borrowTokenPrice,
            collateralTokenDecimals: collateralTokenDecimals,
            borrowTokenDecimals: borrowTokenDecimals,
            ltv: ltv,
            borrowSafetyMargin: defaultBorrowSafetyMargin,
            flashLoanFeeBps: flashLoanFeeBps,
            strataxFeeBps: IFeeCollector(feeCollector).strataxFee(),
            maxLeverageOffset: defaultMaxLeverageOffset
        });

        // Use the library to calculate
        StrataxCalculations.CalcResult memory result = StrataxCalculations.calculateOpenParams(calcParams);

        return (result.flashLoanAmount, result.borrowAmount, result.strataxFee);
    }

    /**
     * @notice Updates the cached Aave flash loan fee from the Aave pool
     * @dev Can be called by anyone to sync the cached fee with the current Aave pool fee
     */
    function updateAaveFlashLoanBps() external {
        uint256 newFlashLoanFeeBps = IPool(aavePool).FLASHLOAN_PREMIUM_TOTAL();
        require(newFlashLoanFeeBps < StrataxCalculations.FLASHLOAN_FEE_PREC, "Invalid flash loan fee");
        if (newFlashLoanFeeBps != flashLoanFeeBps) {
            uint256 oldFlashLoanFeeBps = flashLoanFeeBps;
            flashLoanFeeBps = newFlashLoanFeeBps;
            emit AaveFlashLoanFeeUpdated(newFlashLoanFeeBps, oldFlashLoanFeeBps);
        }
    }

    /**
     * @notice Mints a new position NFT and deploys a dedicated Stratax proxy contract using CREATE2
     * @dev Deploys a new BeaconProxy for each position using CREATE2 for deterministic addresses
     * @param to Address to mint the tokens to
     * @param collateralToken Address of the collateral token
     * @param borrowToken Address of the borrowed token
     * @param _openInitPosition Whether to immediately open a leveraged position upon minting
     * @param _initParams Initial position parameters (flash loan amount, collateral, borrow amount, swap data)
     * @return tokenId The ID of the newly created position type
     * @return strataxProxy Address of the deployed Stratax proxy contract
     */
    function mintPositionNft(
        address to,
        address collateralToken,
        address borrowToken,
        bool _openInitPosition,
        InitPositionParams memory _initParams
    ) external returns (uint256 tokenId, address strataxProxy) {
        require(to != address(0), "Cannot mint to zero address");

        _validateTokens(collateralToken, borrowToken);

        tokenId = currentTokenId++;

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
            borrowSafetyMargin: defaultBorrowSafetyMargin,
            maxLeverageOffset: defaultMaxLeverageOffset
        });

        // Deploy a new Stratax proxy contract for this position using CREATE2
        bytes memory initData = abi.encodeWithSignature(
            "initialize((address,address,address,address,uint256,address,address,address,address,uint256,uint256))",
            initParams
        );

        // Calculate salt from msg.sender and tokenId for deterministic address
        bytes32 salt = keccak256(abi.encodePacked(msg.sender, tokenId));

        strataxProxy = _deployBeaconProxyWithCreate2(strataxBeacon, initData, salt);

        // Create position data
        positions[tokenId] = Position({
            collateralToken: collateralToken,
            borrowToken: borrowToken,
            strataxProxy: strataxProxy,
            isActive: true,
            isBurned: false
        });

        // Map the Stratax proxy address to the token ID for easy lookup
        strataxAddressToTokenId[strataxProxy] = tokenId;

        if (_openInitPosition) {
            // Mint the NFT
            _safeMint(address(this), tokenId);
            IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), _initParams.collateralAmount);
            IERC20(collateralToken).forceApprove(strataxProxy, _initParams.collateralAmount);
            Stratax(strataxProxy)
                .createLeveragedPosition(
                    _initParams.flashLoanAmount,
                    _initParams.collateralAmount,
                    _initParams.borrowAmount,
                    _initParams.oneInchSwapData,
                    _initParams.minReturnAmount
                );

            // transfer the NFT to the user after opening the position
            _safeTransfer(address(this), to, tokenId, "");
        } else {
            // Just mint the NFT to the user, they can call createLeveragedPosition separately when ready
            _safeMint(to, tokenId);
        }

        //@dev possible reentrancy here

        emit PositionMinted(tokenId, to, strataxProxy, collateralToken, borrowToken);

        return (tokenId, strataxProxy);
    }

    /**
     * @notice Predicts the address of a Stratax proxy with full parameters
     * @dev More accurate prediction including collateral and borrow tokens
     * @param minter The address that will call mintPositionNft
     * @param tokenId The token ID that will be used
     * @param collateralToken The collateral token address
     * @param borrowToken The borrow token address
     * @return predictedAddress The predicted address of the Stratax proxy
     */
    function predictStrataxProxyAddress(address minter, uint256 tokenId, address collateralToken, address borrowToken)
        public
        view
        returns (address predictedAddress)
    {
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
            borrowSafetyMargin: defaultBorrowSafetyMargin,
            maxLeverageOffset: defaultMaxLeverageOffset
        });

        bytes memory initData = abi.encodeWithSignature(
            "initialize((address,address,address,address,uint256,address,address,address,address,uint256,uint256))",
            initParams
        );

        bytes32 salt = keccak256(abi.encodePacked(minter, tokenId));

        return _predictCreate2Address(strataxBeacon, initData, salt);
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

    /**
     * @notice Sets the default borrow safety margin for newly deployed Stratax contracts
     * @dev Can only be called by the contract owner. Must be less than BORROW_SAFETY_PRECISION (10000)
     * @param _borrowSafetyMargin The new default safety margin with 4 decimals (e.g., 9950 = 99.5%)
     */
    function setDefaultBorrowSafetyMargin(uint256 _borrowSafetyMargin) public onlyOwner {
        require(_borrowSafetyMargin < StrataxCalculations.BORROW_SAFETY_PRECISION, "Invlaid borrowSafetMargin");
        uint256 oldMargin = defaultBorrowSafetyMargin;
        defaultBorrowSafetyMargin = _borrowSafetyMargin;
        emit DefaultBorrowSafetyMarginUpdated(oldMargin, _borrowSafetyMargin);
    }

    /**
     * @notice Sets the default max leverage offset for newly deployed Stratax contracts
     * @dev Can only be called by the contract owner. Offset is capped at 5% (500 bps with 4-decimal precision)
     * @param _maxLeverageOffset The new max leverage offset (e.g., 75 = 0.75%)
     */
    function setDefaultMaxLeverageOffset(uint256 _maxLeverageOffset) public onlyOwner {
        require(_maxLeverageOffset <= 500, "Max leverage offset too high");
        uint256 oldOffset = defaultMaxLeverageOffset;
        defaultMaxLeverageOffset = _maxLeverageOffset;
        emit DefaultMaxLeverageOffsetUpdated(oldOffset, _maxLeverageOffset);
    }

    /**
     * @notice Deploys a BeaconProxy using CREATE2 for deterministic address
     * @param beacon The beacon address for the proxy
     * @param data The initialization data for the proxy
     * @param salt The salt for CREATE2 deployment
     * @return proxy The address of the deployed proxy
     */
    function _deployBeaconProxyWithCreate2(address beacon, bytes memory data, bytes32 salt)
        internal
        returns (address proxy)
    {
        // Get the creation code for BeaconProxy with constructor arguments
        bytes memory bytecode = abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(beacon, data));

        assembly {
            proxy := create2(
                0, // no value sent
                add(bytecode, 0x20), // bytecode starts after length prefix
                mload(bytecode), // bytecode length
                salt // salt for deterministic address
            )
        }

        require(proxy != address(0), "BeaconProxy deployment failed");
    }

    /**
     * @notice Predicts the CREATE2 address for a BeaconProxy deployment
     * @param beacon The beacon address for the proxy
     * @param data The initialization data for the proxy
     * @param salt The salt for CREATE2 deployment
     * @return predicted The predicted address
     */
    function _predictCreate2Address(address beacon, bytes memory data, bytes32 salt)
        internal
        view
        returns (address predicted)
    {
        bytes memory bytecode = abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(beacon, data));

        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode)));

        return address(uint160(uint256(hash)));
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
     * @notice Returns a limited number of positions owned by an address for pagination
     * @param owner The address to query
     * @param amountOfPositions The maximum number of positions to return (starting from index 0)
     * @return tokenIds Array of token IDs owned by the address
     * @return positionList Array of position structs
     */
    function getPositionsByOwner(address owner, uint256 amountOfPositions)
        public
        view
        returns (uint256[] memory tokenIds, Position[] memory positionList)
    {
        uint256 balance = balanceOf(owner);
        uint256 returnAmount = amountOfPositions > balance ? balance : amountOfPositions;
        tokenIds = new uint256[](returnAmount);
        positionList = new Position[](returnAmount);

        for (uint256 i = 0; i < returnAmount; i++) {
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
     * @notice Validates that a token is a valid Aave collateral asset
     * @param token The token address to validate
     * @return isValid True if the token can be used as collateral
     */
    function _isValidCollateralToken(address token) internal view returns (bool isValid) {
        (, uint256 ltv,,,, bool usageAsCollateralEnabled,,, bool isActive, bool isFrozen) =
            IProtocolDataProvider(aaveDataProvider).getReserveConfigurationData(token);

        // Token must be active, not frozen, have collateral enabled, and have non-zero LTV
        return isActive && !isFrozen && usageAsCollateralEnabled && ltv > 0;
    }

    /**
     * @notice Validates that a token is a valid Aave borrow asset
     * @param token The token address to validate
     * @return isValid True if the token can be borrowed
     */
    function _isValidBorrowToken(address token) internal view returns (bool isValid) {
        (,,,,,, bool borrowingEnabled,, bool isActive, bool isFrozen) =
            IProtocolDataProvider(aaveDataProvider).getReserveConfigurationData(token);

        // Token must be active, not frozen, and have borrowing enabled
        return isActive && !isFrozen && borrowingEnabled;
    }

    /**
     * @notice Validates both collateral and borrow tokens for a position
     * @param collateralToken The collateral token address
     * @param borrowToken The borrow token address
     */
    function _validateTokens(address collateralToken, address borrowToken) internal view {
        require(collateralToken != address(0), "Invalid collateral token address");
        require(borrowToken != address(0), "Invalid borrow token address");
        require(collateralToken != borrowToken, "Collateral and borrow tokens must be different");

        require(_isValidCollateralToken(collateralToken), "Collateral token not supported by Aave");
        require(_isValidBorrowToken(borrowToken), "Borrow token not supported by Aave");
    }

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
     * @notice Validates if a token pair is valid for creating a position
     * @param _collateralToken The collateral token address to validate
     * @param _borrowToken The borrow token address to validate
     * @return True if both tokens are valid for their respective roles
     */
    function isTokenPairValid(address _collateralToken, address _borrowToken) public view returns (bool) {
        return _isValidCollateralToken(_collateralToken) && _isValidBorrowToken(_borrowToken);
    }

    /**
     * @notice Authorizes contract upgrades
     * @dev Required by UUPSUpgradeable - only allows owner to upgrade
     * @param newImplementation The address of the new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
