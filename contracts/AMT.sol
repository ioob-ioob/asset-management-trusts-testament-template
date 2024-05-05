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

    struct NFTinfo {
        address nftAddress;
        uint256[] ids;
    }

    struct PropertyTokens {
        IERC20[] erc20Tokens;
        NFTinfo[] erc721Tokens;
        NFTinfo[] erc1155Tokens;
    }

    struct Successors {
        address nft721successor; // nft721 tokens receiver
        address nft1155successor; // nft1155 tokens receiver
        address[] erc20successors; // array of erc20 tokens receivers
        uint256[] erc20shares; // array of erc20 tokens shares corresponding to erc20successors
    }

    struct LostAccessConfirmation {
        uint256 confirmed;
        uint256 quorum;
        uint256 confirmationTime;
        address[] guardians;
    }

    struct Property {
        uint256 expirationTime;
        Successors successors;
        LostAccessConfirmation voting;
    }

    enum PropertyState {
        NotExist,
        OwnerActive,
        VoteActive,
        ConfirmationWaiting,
        Unlocked
    }

    uint256 private constant BASE_POINT = 10000;
    uint256 public immutable CONFIRMATION_LOCK = 180 days;
    uint256 public immutable MIN_PROPERTY_LOCK = 360 days;
    uint256 public immutable CONTINGENCY_PERIOD = 360 * 10 days;
    uint256 public immutable MAX_GUARDIANS = 10;
    uint256 public immutable MAX_SUCCESSORS = 10;
    uint256 public immutable FEE_BP = 100; // 1%
    address public feeAddress;

    mapping(address => Property) public properties;
    mapping(address => bool) public firstPayment;

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
     * @dev Emitted when guardians are changed for a property.
     * @param user The owner of the property.
     * @param newVoteQuorum The updated vote quorum.
     * @param newGuardians The updated list of guardians.
     */
    event GuardiansChanged(
        address user,
        uint256 newVoteQuorum,
        address[] newGuardians
    );

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
     * @param _CONFIRMATION_LOCK Period where owner can proof that he active
     * @param _MIN_PROPERTY_LOCK Minimum period to lock property
     * @param _CONTINGENCY_PERIOD After that period if quorum property can be shared
     * @param _MAX_GUARDIANS Max of guardians
     * @param _MAX_SUCCESSORS Max of successors
     * @param _FEE_BP % fee of that service
     */
    constructor(
        address _feeAddress,
        uint256 _CONFIRMATION_LOCK,
        uint256 _MIN_PROPERTY_LOCK,
        uint256 _CONTINGENCY_PERIOD,
        uint256 _MAX_GUARDIANS,
        uint256 _MAX_SUCCESSORS,
        uint256 _FEE_BP
    ) {
        feeAddress = _feeAddress;
        CONFIRMATION_LOCK = _CONFIRMATION_LOCK;
        MIN_PROPERTY_LOCK = _MIN_PROPERTY_LOCK;
        CONTINGENCY_PERIOD = _CONTINGENCY_PERIOD;
        MAX_GUARDIANS = _MAX_GUARDIANS;
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
     * @dev Checks the parameters for setting guardians.
     * @param _quorum The voting quorum.
     * @param _guardians An array of guardians.
     */
    function checkVoteParam(
        uint256 _quorum,
        uint256 _guardiansLength
    ) private pure {
        require(_quorum > 0, "AMT: _quorum value must be greater than null");
        require(_guardiansLength <= MAX_GUARDIANS, "AMT: Too many guardians");
        require(
            _guardiansLength >= _quorum,
            "AMT: _quorum should be equal to number of guardians"
        );
    }

    /**
     * @dev Sets the guardians for a property.
     * @param _quorum The voting quorum.
     * @param _guardians An array of guardians.
     */
    function setGuardians(
        uint256 _quorum,
        address[] calldata _guardians
    )
        external
        correctStatus(
            PropertyState.OwnerActive,
            msg.sender,
            "first confirm that you are still active"
        )
    {
        checkVoteParam(_quorum, _guardians.length);
        Property storage userProperty = properties[msg.sender];
        // reset current voting state
        userProperty.voting.confirmed = 0;
        userProperty.voting.guardians = _guardians;
        userProperty.voting.quorum = _quorum;
        emit GuardiansChanged(msg.sender, _quorum, _guardians);
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
     * @param _quorum: voting quorum
     * @param _guardians: array of guardians
     * @param _successors: array of successors
     */
    function createProperty(
        uint256 _quorum,
        address[] calldata _guardians,
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
            MAX_SUCCESSORS == 0 ||
                MAX_SUCCESSORS >= _successors.erc20successors.length,
            "AMT: ERC20 successors limit exceeded"
        );

        checkVoteParam(_quorum, _guardians.length);
        checkSharesSUM(_successors.erc20shares);

        Property memory newProperty = Property(
            block.timestamp + MIN_PROPERTY_LOCK,
            _successors,
            LostAccessConfirmation(0, _quorum, 0, _guardians)
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
            currentState == PropertyState.OwnerActive ||
                currentState == PropertyState.VoteActive,
            "AMT: State should be OwnerActive or VoteActive or you can try to delete the property while it not confirmed"
        );
        Property memory userProperty = properties[msg.sender];

        require(
            block.timestamp > (userProperty.expirationTime - MIN_PROPERTY_LOCK),
            "AMT: No more than two periods"
        );
        userProperty.voting.confirmed = 0;
        userProperty.expirationTime += MIN_PROPERTY_LOCK;

        properties[msg.sender] = userProperty;

        emit OwnerActive(msg.sender, userProperty.expirationTime);
    }

    function _getVotersCount(
        uint256 confirmed
    ) private pure returns (uint256 voiceCount) {
        while (confirmed > 0) {
            voiceCount += confirmed & 1;
            confirmed >>= 1;
        }
    }

    /**
     * @dev Gets the count of voters for a property.
     * @param propertyOwner The owner of the property.
     */
    function getVotersCount(
        address propertyOwner
    ) external view returns (uint256 voiceCount) {
        LostAccessConfirmation memory voting = properties[propertyOwner].voting;
        voiceCount = _getVotersCount(voting.confirmed);
    }

    /**
     * @dev Gets the voters for a property.
     * @param propertyOwner The owner of the property.
     * @return An array of voters' addresses.
     */
    function getVoters(
        address propertyOwner
    ) external view returns (address[] memory) {
        LostAccessConfirmation memory voting = properties[propertyOwner].voting;
        address[] memory voters = new address[](voting.guardians.length);
        if (voters.length > 0 && voting.confirmed > 0) {
            uint256 count;
            for (uint256 i = 0; i < voting.guardians.length; i++) {
                if (voting.confirmed & (1 << i) != 0) {
                    voters[count] = voting.guardians[i];
                    count++;
                }
            }

            assembly {
                mstore(voters, count)
            }
        }
        return voters;
    }

    /**
     * @dev Confirms lost access to a property.
     * @param propertyOwner The owner of the property.
     */
    function confirmLostAccess(
        address propertyOwner
    )
        external
        correctStatus(
            PropertyState.VoteActive,
            propertyOwner,
            "voting is not active"
        )
    {
        Property storage userProperty = properties[propertyOwner];
        LostAccessConfirmation memory voting = userProperty.voting;

        for (uint256 i = 0; i < voting.guardians.length; i++) {
            if (
                msg.sender == voting.guardians[i] &&
                voting.confirmed & (1 << i) == 0
            ) {
                voting.confirmed |= (1 << i);
            }
        }
        userProperty.voting.confirmed = voting.confirmed;

        if (_getVotersCount(voting.confirmed) >= voting.quorum) {
            userProperty.voting.confirmationTime =
                block.timestamp +
                CONFIRMATION_LOCK;
            emit LostAccessConfirmed(
                propertyOwner,
                userProperty.voting.confirmationTime
            );
        }
    }

    /**
     * @notice get property after lost access confirmation
     * call from successors
     * @param propertyOwner: property creator
     * withdrawal info:
     * @param tokens: {IERC20[] erc20Tokens;NFTinfo[] erc721Tokens;NFTinfo[] erc1155Tokens;}
     * erc20Tokens: array of erc20 tokens
     * erc721Tokens: array of {address nftAddress;uint256[] ids;} objects
     * erc1155Tokens: array of {address nftAddress;uint256[] ids;} objects
     */
    function withdrawProperty(
        address propertyOwner,
        PropertyTokens calldata tokens
    )
        external
        correctStatus(
            PropertyState.Unlocked,
            propertyOwner,
            "Property must be Unlocked"
        )
    {
        Property memory userProperty = properties[propertyOwner];
        Successors memory userSuccessors = userProperty.successors;

        uint256 userERC20Shares;

        for (uint256 i = 0; i < userSuccessors.erc20successors.length; i++) {
            if (msg.sender == userSuccessors.erc20successors[i]) {
                userERC20Shares += userSuccessors.erc20shares[i];
            }
        }

        if (userERC20Shares > 0) {
            // ERC20
            for (uint256 i = 0; i < tokens.erc20Tokens.length; i++) {
                mapping(address => bool) storage alreadyDone = alreadyWithdrawn[
                    propertyOwner
                ][msg.sender];
                if (alreadyDone[address(tokens.erc20Tokens[i])] == false) {
                    alreadyDone[address(tokens.erc20Tokens[i])] = true;
                    mapping(address => uint256)
                        storage amountPerShare = amountsPerShare[propertyOwner];
                    uint256 perShare = amountPerShare[
                        address(tokens.erc20Tokens[i])
                    ];

                    if (perShare == 0) {
                        uint256 propertyOwnerBalance = tokens
                            .erc20Tokens[i]
                            .balanceOf(propertyOwner);
                        uint256 feeAmount = (propertyOwnerBalance * FEE_BP) /
                            BASE_POINT;
                        if (feeAmount > 0) {
                            IERC20(tokens.erc20Tokens[i]).safeTransferFrom(
                                propertyOwner,
                                feeAddress,
                                feeAmount
                            );
                            propertyOwnerBalance -= feeAmount;
                        }

                        if (propertyOwnerBalance > BASE_POINT) {
                            perShare = propertyOwnerBalance / BASE_POINT;
                            amountPerShare[
                                address(tokens.erc20Tokens[i])
                            ] = perShare;

                            tokens.erc20Tokens[i].safeTransferFrom(
                                propertyOwner,
                                address(this),
                                propertyOwnerBalance
                            );
                        }
                    }
                    uint256 erc20Amount = userERC20Shares * perShare;
                    if (erc20Amount > 0) {
                        tokens.erc20Tokens[i].safeTransfer(
                            msg.sender,
                            erc20Amount
                        );
                    }
                }
            }
        }

        if (msg.sender == userSuccessors.nft721successor) {
            // ERC721
            for (uint256 i = 0; i < tokens.erc721Tokens.length; i++) {
                for (
                    uint256 x = 0;
                    x < tokens.erc721Tokens[i].ids.length;
                    x++
                ) {
                    IERC721(tokens.erc721Tokens[i].nftAddress).safeTransferFrom(
                            propertyOwner,
                            msg.sender,
                            tokens.erc721Tokens[i].ids[x]
                        );
                }
            }
        }

        if (msg.sender == userSuccessors.nft1155successor) {
            // ERC1155
            for (uint256 i = 0; i < tokens.erc1155Tokens.length; i++) {
                uint256[] memory batchBalances = new uint256[](
                    tokens.erc1155Tokens[i].ids.length
                );
                for (
                    uint256 x = 0;
                    x < tokens.erc1155Tokens[i].ids.length;
                    ++x
                ) {
                    batchBalances[x] = IERC1155(
                        tokens.erc1155Tokens[i].nftAddress
                    ).balanceOf(propertyOwner, tokens.erc1155Tokens[i].ids[x]);
                }
                IERC1155(tokens.erc1155Tokens[i].nftAddress)
                    .safeBatchTransferFrom(
                        propertyOwner,
                        msg.sender,
                        tokens.erc1155Tokens[i].ids,
                        batchBalances,
                        ""
                    );
            }
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
        LostAccessConfirmation memory voting = userProperty.voting;

        if (userProperty.expirationTime > 0) {
            // voting started
            if (block.timestamp > userProperty.expirationTime) {
                if (
                    _getVotersCount(voting.confirmed) >= voting.quorum ||
                    block.timestamp >
                    userProperty.expirationTime + CONTINGENCY_PERIOD
                ) {
                    if (block.timestamp < voting.confirmationTime) {
                        return PropertyState.ConfirmationWaiting;
                    }

                    return PropertyState.Unlocked;
                }

                if (
                    block.timestamp <
                    (userProperty.expirationTime + MIN_PROPERTY_LOCK)
                ) {
                    return PropertyState.VoteActive;
                }

                return PropertyState.NotExist;
            } else {
                return PropertyState.OwnerActive;
            }
        }

        return PropertyState.NotExist;
    }
}
