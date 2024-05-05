// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title AMT (Asset Management Toolkit)
 * @dev A smart contract for managing assets including ERC20 tokens, ERC721, and ERC1155 tokens.
 */
contract AMT is Ownable(msg.sender) {
    using SafeERC20 for IERC20;

    struct Successors {
        address[] erc20successors; // array of erc20 tokens receivers
        uint256[] erc20shares; // array of erc20 tokens shares corresponding to erc20successors
    }

    struct Property {
        uint256 expirationTime;
        Successors successors;
    }

    enum PropertyState {
        NotExist,
        OwnerActive,
        Unlocked
    }

    uint256 private constant BASE_POINT = 10000;
    uint256 public immutable MIN_PROPERTY_LOCK = 7 days;
    uint256 public immutable MAX_SUCCESSORS = 10;
    uint256 public immutable FEE_BP = 100; // 1%
    address public feeAddress;

    mapping(address => Property) public properties;

    // propertyOwner  => token   =>  amountPerShare
    mapping(address => mapping(address => uint256)) private amountsPerShare;
    // propertyOwner   =>  successor   =>  token  => already withdrawn
    mapping(address => mapping(address => mapping(address => bool)))
        private alreadyWithdrawn;

    /**
     * @dev Modifier to check the current status of the property.
     * @param _state The expected state of the property.
     * @param _propertyOwner The owner of the property.
     * @param _error Error message to display if the status check fails.
     */
    modifier correctStatus(
        PropertyState _state,
        address _propertyOwner,
        string memory _error
    ) {
        require(getPropertyState(_propertyOwner) == _state, _error);
        _;
    }

    /**
     * @dev Emitted when successors are changed for a property.
     * @param propertyOwner The owner of the property.
     * @param newSuccessors The updated successors.
     */
    event SuccessorsChanged(address propertyOwner, Successors newSuccessors);

    /**
     * @dev Emitted when a property is deleted.
     * @param propertyOwner The owner of the property.
     */
    event PropertyDeleted(address propertyOwner);

    /**
     * @dev Emitted when a new property is created.
     * @param user The owner of the property.
     * @param newProperty The details of the new property.
     */
    event CreateProperty(address user, Property newProperty);

    /**
     * @dev Emitted when a property owner is active.
     * @param propertyOwner The owner of the property.
     * @param newExpirationTime The updated expiration time of the property.
     */
    event OwnerActive(address propertyOwner, uint256 newExpirationTime);

    /**
     * @dev Emitted when lost access to a property is confirmed.
     * @param propertyOwner The owner of the property.
     * @param lostAccessConfirmationTime The time when lost access is confirmed.
     */
    event LostAccessConfirmed(
        address propertyOwner,
        uint256 lostAccessConfirmationTime
    );

    /**
     * @dev Emitted when a successor retrieves property assets.
     * @param propertyOwner The owner of the property.
     * @param successor The successor who retrieves the property assets.
     */
    event GetProperty(address propertyOwner, address successor);

    /**
     * @dev Constructor to initialize contract parameters.
     * @param _feeAddress The address to receive fees.
     * @param _MIN_PROPERTY_LOCK Minimum period to lock property
     * @param _MAX_SUCCESSORS Max of successors
     * @param _FEE_BP % fee of that service
     */
    constructor(
        address _feeAddress,
        uint256 _MIN_PROPERTY_LOCK,
        uint256 _MAX_SUCCESSORS,
        uint256 _FEE_BP
    ) {
        feeAddress = _feeAddress;
        MIN_PROPERTY_LOCK = _MIN_PROPERTY_LOCK;
        MAX_SUCCESSORS = _MAX_SUCCESSORS;
        FEE_BP = _FEE_BP;
    }

    /**
     * @dev Sets the fee address.
     * @param _feeAddress The new fee address.
     */
    function setFeeAddress(address _feeAddress) external onlyOwner {
        feeAddress = _feeAddress;
    }

    // Function to return the address of this contract
    function getContractAddress() public view returns (address) {
        return address(this);
    }

    /**
     * @dev Check shares sum it should not be greater than 10000 (BASE_POINT).
     * @param _erc20shares array of erc20shares.
     */
    function checkSharesSUM(uint256[] memory _erc20shares) private pure {
        uint256 sharesSum;
        for (uint256 i = 0; i < _erc20shares.length; i++) {
            sharesSum += _erc20shares[i];
        }
        require(sharesSum == BASE_POINT, "AMT: Incorrect shares sum");
    }

    /**
     * @dev Sets the successors for a property.
     * @param _newSuccessors The new successors for the property.
     */
    function setSuccessors(
        Successors calldata _newSuccessors
    )
        external
        correctStatus(
            PropertyState.OwnerActive,
            msg.sender,
            "First confirm that you are still active"
        )
    {
        Property storage userProperty = properties[msg.sender];

        require(
            _newSuccessors.erc20shares.length ==
                _newSuccessors.erc20successors.length,
            "AMT: ERC20 successors and shares must be the same length"
        );
        require(
            MAX_SUCCESSORS == 0 ||
                MAX_SUCCESSORS >= _newSuccessors.erc20successors.length,
            "AMT: ERC20 successors limit exceeded"
        );

        checkSharesSUM(_newSuccessors.erc20shares);
        userProperty.successors = _newSuccessors;

        emit SuccessorsChanged(msg.sender, _newSuccessors);
    }

    /**
     * @dev Deletes a property.
     */
    function deleteProperty() external {
        require(
            getPropertyState(msg.sender) < PropertyState.Unlocked,
            "AMT: Active only"
        );
        delete properties[msg.sender];
        emit PropertyDeleted(msg.sender);
    }

    /**
     * @notice create property
     * @param _successors: array of successors
     */
    function createProperty(
        Successors calldata _successors
    )
        external
        correctStatus(PropertyState.NotExist, msg.sender, "already exist")
    {
        require(
            _successors.erc20shares.length ==
                _successors.erc20successors.length,
            "AMT: ERC20 successors and shares must be the same length"
        );
        require(
            MAX_SUCCESSORS <= _successors.erc20successors.length,
            "AMT: ERC20 successors limit exceeded"
        );

        checkSharesSUM(_successors.erc20shares);

        Property memory newProperty = Property(
            block.timestamp + MIN_PROPERTY_LOCK,
            _successors
        );

        properties[msg.sender] = newProperty;

        emit CreateProperty(msg.sender, newProperty);
    }

    /**
     * @dev Confirms that the property owner is still active.
     */
    function imActive() external {
        PropertyState currentState = getPropertyState(msg.sender);
        require(
            currentState == PropertyState.OwnerActive,
            "AMT: State should be OwnerActive or you can try to delete the property while it not confirmed"
        );
        Property memory userProperty = properties[msg.sender];
        require(
            block.timestamp > (userProperty.expirationTime - MIN_PROPERTY_LOCK),
            "AMT: No more than two periods"
        );
        userProperty.expirationTime += MIN_PROPERTY_LOCK;

        properties[msg.sender] = userProperty;

        emit OwnerActive(msg.sender, userProperty.expirationTime);
    }

    /**
     * @dev count ERC20Shares for user
     * @param successor: successor address
     * @param propertyOwner: property creator
     */
    function getUserERC20Shares(
        address successor,
        address propertyOwner
    ) private view returns (uint256) {
        Successors storage successors = properties[propertyOwner].successors;
        for (uint256 i = 0; i < successors.erc20successors.length; i++) {
            if (successor == successors.erc20successors[i]) {
                return successors.erc20shares[i];
            }
        }
        return 0;
    }

    /**
     * @dev Withdraw Token from propery Owner
     * @param propertyOwner: property creator
     * @param token: ERC20 token
     * @param userERC20Shares: user share
     */
    function withdrawForToken(
        address propertyOwner,
        IERC20 token,
        uint256 userERC20Shares
    ) private {
        mapping(address => bool) storage alreadyDone = alreadyWithdrawn[
            propertyOwner
        ][msg.sender];
        if (alreadyDone[address(token)] == false) {
            alreadyDone[address(token)] = true;
            mapping(address => uint256)
                storage amountPerShare = amountsPerShare[propertyOwner];
            uint256 perShare = amountPerShare[address(token)];
            if (perShare == 0) {
                uint256 propertyOwnerBalance = token.balanceOf(propertyOwner);
                uint256 feeAmount = (propertyOwnerBalance * FEE_BP) /
                    BASE_POINT;
                if (feeAmount > 0) {
                    IERC20(token).safeTransferFrom(
                        propertyOwner,
                        feeAddress,
                        feeAmount
                    );
                    propertyOwnerBalance -= feeAmount;
                }
                if (propertyOwnerBalance > BASE_POINT) {
                    perShare = propertyOwnerBalance / BASE_POINT;
                    amountPerShare[address(token)] = perShare;

                    IERC20(token).safeTransferFrom(
                        propertyOwner,
                        address(this),
                        propertyOwnerBalance
                    );
                }
            }
            uint256 amountToDistribute = perShare * userERC20Shares;
            if (amountToDistribute > 0) {
                token.safeTransfer(msg.sender, amountToDistribute);
            }
        }
    }

    /**
     * @notice get property after lost access confirmation
     * call from successors
     * @param propertyOwner: property creator
     * withdrawal info:
     * @param erc20Tokens: IERC20[]
     */
    function withdrawProperty(
        address propertyOwner,
        IERC20[] calldata erc20Tokens
    )
        external
        correctStatus(
            PropertyState.Unlocked,
            propertyOwner,
            "Property must be Unlocked"
        )
    {
        // Find the shares for the calling successor
        uint256 userERC20Shares = getUserERC20Shares(msg.sender, propertyOwner);
        require(userERC20Shares > 0, "AMT: No shares for this successor");

        for (uint256 i = 0; i < erc20Tokens.length; i++) {
            withdrawForToken(propertyOwner, erc20Tokens[i], userERC20Shares);
        }

        emit GetProperty(propertyOwner, msg.sender);
    }

    /**
     * @dev Gets the state of a property.
     * @param propertyOwner The owner of the property.
     * @return The state of the property.
     */
    function getPropertyState(
        address propertyOwner
    ) public view returns (PropertyState) {
        Property memory userProperty = properties[propertyOwner];
        if (userProperty.expirationTime == 0) {
            return PropertyState.NotExist;
        }
        if (block.timestamp <= userProperty.expirationTime) {
            return PropertyState.OwnerActive;
        }
        if (block.timestamp > userProperty.expirationTime) {
            return PropertyState.Unlocked;
        }
        return PropertyState.NotExist;
    }
}
