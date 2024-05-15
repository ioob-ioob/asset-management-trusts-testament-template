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
contract AMTDemo is Ownable(msg.sender) {
    using SafeERC20 for IERC20;

    struct Property {
        uint256 expirationTime;
        IERC20 token;
        address successor1;
        uint256 share1;
        address successor2;
        uint256 share2;
    }

    enum PropertyState {
        NotExist,
        OwnerActive,
        Unlocked
    }

    uint256 private constant BASE_POINT = 10000;
    uint256 public immutable MIN_PROPERTY_LOCK;
    uint256 public immutable FEE_BP;
    address public feeAddress;

    mapping(address => Property) public properties;

    // propertyOwner => amountPerShare
    mapping(address => uint256) private amountsPerShare;
    // propertyOwner => successor => already withdrawn
    mapping(address => mapping(address => bool)) private alreadyWithdrawn;

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
     */
    event SuccessorsChanged(
        address propertyOwner,
        address successor1,
        uint256 share1,
        address successor2,
        uint256 share2
    );

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
     * @param _MIN_PROPERTY_LOCK Minimum period to lock property.
     * @param _FEE_BP % fee of that service.
     */
    constructor(
        address _feeAddress,
        uint256 _MIN_PROPERTY_LOCK,
        uint256 _FEE_BP
    ) {
        feeAddress = _feeAddress;
        MIN_PROPERTY_LOCK = _MIN_PROPERTY_LOCK;
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
     */
    function checkSharesSUM(uint256 share1, uint256 share2) private pure {
        require(share1 + share2 == BASE_POINT, "AMT: Incorrect shares sum");
    }

    /**
     * @dev Sets the successors for a property.
     */
    function setSuccessors(
        address successor1,
        uint256 share1,
        address successor2,
        uint256 share2
    )
        external
        correctStatus(
            PropertyState.OwnerActive,
            msg.sender,
            "First confirm that you are still active"
        )
    {
        Property storage userProperty = properties[msg.sender];
        checkSharesSUM(share1, share2);
        userProperty.successor1 = successor1;
        userProperty.share1 = share1;
        userProperty.successor2 = successor2;
        userProperty.share2 = share2;

        emit SuccessorsChanged(
            msg.sender,
            successor1,
            share1,
            successor2,
            share2
        );
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
     */
    function createProperty(
        IERC20 token,
        address successor1,
        uint256 share1,
        address successor2,
        uint256 share2
    )
        external
        correctStatus(PropertyState.NotExist, msg.sender, "already exist")
    {
        checkSharesSUM(share1, share2);

        Property memory newProperty = Property(
            block.timestamp + MIN_PROPERTY_LOCK,
            token,
            successor1,
            share1,
            successor2,
            share2
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
        Property storage userProperty = properties[msg.sender];
        require(
            block.timestamp > (userProperty.expirationTime - MIN_PROPERTY_LOCK),
            "AMT: No more than two periods"
        );
        userProperty.expirationTime += MIN_PROPERTY_LOCK;

        emit OwnerActive(msg.sender, userProperty.expirationTime);
    }

    /**
     * @dev Withdraw Token from property Owner
     * @param propertyOwner: property creator
     * @param share: user share
     */
    function withdrawToken(
        address propertyOwner,
        IERC20 token,
        uint256 share
    ) private {
        if (!alreadyWithdrawn[propertyOwner][msg.sender]) {
            alreadyWithdrawn[propertyOwner][msg.sender] = true;
            uint256 perShare = amountsPerShare[propertyOwner];
            if (perShare == 0) {
                uint256 propertyOwnerBalance = token.balanceOf(propertyOwner);
                uint256 feeAmount = (propertyOwnerBalance * FEE_BP) /
                    BASE_POINT;
                if (feeAmount > 0) {
                    token.safeTransferFrom(
                        propertyOwner,
                        feeAddress,
                        feeAmount
                    );
                    propertyOwnerBalance -= feeAmount;
                }
                if (propertyOwnerBalance > BASE_POINT) {
                    perShare = propertyOwnerBalance / BASE_POINT;
                    amountsPerShare[propertyOwner] = perShare;
                    token.safeTransferFrom(
                        propertyOwner,
                        address(this),
                        propertyOwnerBalance
                    );
                }
            }
            uint256 amountToDistribute = perShare * share;
            if (amountToDistribute > 0) {
                token.safeTransfer(msg.sender, amountToDistribute);
            }
        }
    }

    /**
     * @notice get property after lost access confirmation
     * call from successors
     * @param propertyOwner: property creator
     */
    function withdrawProperty(
        address propertyOwner
    )
        external
        correctStatus(
            PropertyState.Unlocked,
            propertyOwner,
            "Property must be Unlocked"
        )
    {
        // Find the shares for the calling successor
        Property memory propertyToWithdraw = properties[propertyOwner];
        address sender = msg.sender;
        if (sender == propertyToWithdraw.successor1) {
            withdrawToken(
                propertyOwner,
                propertyToWithdraw.token,
                propertyToWithdraw.share1
            );
        } else if (sender == propertyToWithdraw.successor2) {
            withdrawToken(
                propertyOwner,
                propertyToWithdraw.token,
                propertyToWithdraw.share2
            );
        } else {
            revert("AMT: Not a successor");
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
