// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IStrataxPositionNft is IERC721 {
    /*//////////////////////////////////////////////////////////////
                            TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/

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
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the StrataxPositionNft contract
     * @dev Can only be called once due to initializer modifier
     * @param _strataxBeacon Address of the Stratax beacon for deploying proxies
     * @param _aavePool Address of the Aave pool
     * @param _aaveDataProvider Address of the Aave data provider
     * @param _oneInchRouter Address of the 1inch router
     * @param _strataxOracle Address of the Stratax oracle
     * @param _owner Address of the contract owner
     * @param _uri Base URI for token metadata
     */
    function initialize(
        address _strataxBeacon,
        address _aavePool,
        address _aaveDataProvider,
        address _oneInchRouter,
        address _strataxOracle,
        address _owner,
        string memory _uri
    ) external;

    /**
     * @notice Mints a new position NFT and deploys a dedicated Stratax proxy contract
     * @dev Deploys a new BeaconProxy for each position to hold position data
     * @param to Address to mint the tokens to
     * @param collateralToken Address of the collateral token
     * @param borrowToken Address of the borrowed token
     * @return tokenId The ID of the newly created position type
     * @return strataxProxy Address of the deployed Stratax proxy contract
     */
    function mint(address to, address collateralToken, address borrowToken)
        external
        returns (uint256 tokenId, address strataxProxy);

    /**
     * @notice Burns a position NFT
     * @dev Can only be called by the position's Stratax proxy contract
     * @param tokenId The ID of the position
     */
    function burn(uint256 tokenId) external;

    /**
     * @notice Sets the base URI for token metadata
     * @dev Can only be called by the contract owner
     * @param baseURI The new base URI
     */
    function setBaseURI(string memory baseURI) external;

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the position details for a given token ID
     * @param tokenId The ID of the position
     * @return position The position struct
     */
    function getPosition(uint256 tokenId) external view returns (Position memory position);

    /**
     * @notice Returns the Stratax proxy address for a given token ID
     * @param tokenId The ID of the position
     * @return strataxProxy The address of the deployed Stratax proxy contract
     */
    function getStrataxProxy(uint256 tokenId) external view returns (address strataxProxy);

    /**
     * @notice Returns all positions owned by an address
     * @param owner The address to query
     * @return tokenIds Array of token IDs owned by the address
     * @return positionList Array of position structs
     */
    function getPositionsByOwner(address owner)
        external
        view
        returns (uint256[] memory tokenIds, Position[] memory positionList);

    /**
     * @notice Returns the total number of position types ever created
     * @return count The total count of position types
     */
    function getTotalPositionsCreated() external view returns (uint256 count);

    /**
     * @notice Checks if a token ID exists
     * @param tokenId The ID to check
     * @return True if the token exists
     */
    function exists(uint256 tokenId) external view returns (bool);

    /**
     * @notice Returns the Stratax Beacon address
     * @return The address of the Stratax beacon
     */
    function strataxBeacon() external view returns (address);

    /**
     * @notice Returns the Aave pool address
     * @return The address of the Aave pool
     */
    function aavePool() external view returns (address);

    /**
     * @notice Returns the Aave data provider address
     * @return The address of the Aave data provider
     */
    function aaveDataProvider() external view returns (address);

    /**
     * @notice Returns the 1inch router address
     * @return The address of the 1inch router
     */
    function oneInchRouter() external view returns (address);

    /**
     * @notice Returns the Stratax oracle address
     * @return The address of the Stratax oracle
     */
    function strataxOracle() external view returns (address);

    /**
     * @notice Returns position details for a given token ID
     * @param tokenId The ID of the position
     * @return position The position struct
     */
    function positions(uint256 tokenId) external view returns (Position memory position);
}
