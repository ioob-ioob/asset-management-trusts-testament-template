pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract BT is Ownable(msg.sender) {
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
        uint256[] erc20shares; //array of erc20 tokens shares corresponding to erc20successors
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
        OwnerAlive,
        VoteActive,
        ConfirmationWaiting,
        Unlocked
    }

    uint256 public constant CONFIRMATION_LOCK = 180 days;
    uint256 public constant MIN_PROPERTY_LOCK = 360 days;
    uint256 public constant CONTINGENCY_PERIOD = 360 * 10 days;
    uint256 public constant MAX_GUARDIANS = 10;
    uint256 public constant erc20SuccessorsLimit = 10;
    uint256 public constant BASE_POINT = 10000; // 100%
    uint256 public constant FEE_BP = 100; // 1%
    address public feeAddress;
    address public immutable quoteTokenAddress;
    /// price in quote token
    uint256 public priceForChangingguardians;
    /// price in quote token
    uint256 public priceForChangingSuccessors;
    mapping(address => Property) public properties;
    mapping(address => bool) public firstPayment;

    // propertyOwner  => token   =>  amountPerShare
    mapping(address => mapping(address => uint256)) private amountsPerShare;
    // propertyOwner   =>  successor   =>  token  => already withdrawn
    mapping(address => mapping(address => mapping(address => bool)))
    private alreadyWithdrawn;

    modifier correctStatus(
        PropertyState _state,
        address _propertyOwner,
        string memory _error
    ) {
        require(getPropertyState(_propertyOwner) == _state, _error);
        _;
    }

    event SuccessorsChanged(address propertyOwner, Successors newSuccessors);
    event PropertyDeleted(address propertyOwner);

    event GuardiansChanged(
        address user,
        uint256 newVoteQuorum,
        address[] newGuardians
    );

    event CreateProperty(address user, Property newProperty);

    event OwnerActive(address propertyOwner, uint256 newExpirationTime);

    event LostAccessConfirmed(address propertyOwner, uint256 lostAccessConfirmationTime);

    event GetProperty(address propertyOwner, address successor);

    constructor(address _feeAddress, address _quoteTokenAddress) {
        feeAddress = _feeAddress;
        quoteTokenAddress = _quoteTokenAddress;
    }

    /**
     * @param _feeAddress: new feeAddress
     */
    function setFeeAddress(address _feeAddress) external onlyOwner {
        feeAddress = _feeAddress;
    }

    function checkSharesSUM(uint256[] memory _erc20shares) private pure {
        uint256 sharesSum;
        for (uint256 i = 0; i < _erc20shares.length; i++) {
            sharesSum += _erc20shares[i];
        }
        require(sharesSum == BASE_POINT, "incorrect shares sum");
    }

    /**
     * @notice assignment of successors
     */
    function setSuccessors(Successors calldata _newSuccessors)
    external
    correctStatus(
    PropertyState.OwnerAlive,
    msg.sender,
    "first confirm that you are still alive"
    )
    {
        Property storage userProperty = properties[msg.sender];

        require(
            _newSuccessors.erc20shares.length ==
            _newSuccessors.erc20successors.length,
            "erc20 successors and shares must be the same length"
        );
        require(
            erc20SuccessorsLimit == 0 ||
            erc20SuccessorsLimit >= _newSuccessors.erc20successors.length,
            "erc20 successors limit exceeded"
        );

        checkSharesSUM(_newSuccessors.erc20shares);

        if (priceForChangingSuccessors > 0) {
            IERC20(quoteTokenAddress).safeTransferFrom(
                msg.sender,
                feeAddress,
                priceForChangingSuccessors
            );
        }

        userProperty.successors = _newSuccessors;

        emit SuccessorsChanged(msg.sender, _newSuccessors);
    }

    /**
     * @notice check validator's and quorum
     */
    function checkVoteParam(uint256 _quorum, uint256 _guardiansLength)
    private
    pure
    {
        require(_quorum > 0, "_quorum value must be greater than null");
        require(_guardiansLength <= MAX_GUARDIANS, "too many guardians");
        require(
            _guardiansLength >= _quorum,
            "_quorum should be equal to number of guardians"
        );
    }

    /**
     * @notice the weight of the validator's vote in case of repetition of the address in _guardians increases
     */
    function setguardians(uint256 _quorum, address[] calldata _guardians)
    external
    correctStatus(
    PropertyState.OwnerAlive,
    msg.sender,
    "first confirm that you are still alive"
    )
    {
        checkVoteParam(_quorum, _guardians.length);
        if (priceForChangingguardians > 0) {
            IERC20(quoteTokenAddress).safeTransferFrom(
                msg.sender,
                feeAddress,
                priceForChangingguardians
            );
        }

        Property storage userProperty = properties[msg.sender];
        // reset current voting state
        userProperty.voting.confirmed = 0;
        userProperty.voting.guardians = _guardians;
        userProperty.voting.quorum = _quorum;
        emit GuardiansChanged(msg.sender, _quorum, _guardians);
    }

    function deleteProperty() external {
        require(
            getPropertyState(msg.sender) < PropertyState.Unlocked,
            "alive only"
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
            "erc20 successors and shares must be the same length"
        );
        require(
            erc20SuccessorsLimit == 0 ||
            erc20SuccessorsLimit >= _successors.erc20successors.length,
            "erc20 successors limit exceeded"
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
     * @notice confirm that you are still alive
     */
    function imAlive() external {
        PropertyState currentState = getPropertyState(msg.sender);
        require(
            currentState == PropertyState.OwnerAlive ||
            currentState == PropertyState.VoteActive,
            "state should be OwnerAlive or VoteActive or you can try to delete the property while it not confirmed"
        );
        Property memory userProperty = properties[msg.sender];

        require(
            block.timestamp >
            (userProperty.expirationTime - MIN_PROPERTY_LOCK),
            "no more than two periods"
        );
        userProperty.voting.confirmed = 0;
        userProperty.expirationTime += MIN_PROPERTY_LOCK;

        properties[msg.sender] = userProperty;

        emit OwnerActive(msg.sender, userProperty.expirationTime);
    }

    function _getVotersCount(uint256 confirmed)
    private
    pure
    returns (uint256 voiceCount)
    {
        while (confirmed > 0) {
            voiceCount += confirmed & 1;
            confirmed >>= 1;
        }
    }

    function getVotersCount(address propertyOwner)
    external
    view
    returns (uint256 voiceCount)
    {
        LostAccessConfirmation memory voting = properties[propertyOwner].voting;
        voiceCount = _getVotersCount(voting.confirmed);
    }

    function getVoters(address propertyOwner)
    external
    view
    returns (address[] memory)
    {
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

    function confirmLostAccess(address propertyOwner)
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
                    storage amountPerShare = amountsPerShare[
                                propertyOwner
                        ];
                    uint256 perShare = amountPerShare[
                                    address(tokens.erc20Tokens[i])
                        ];

                    if (perShare == 0) {
                        uint256 propertyOwnerBalance = tokens
                            .erc20Tokens[i]
                            .balanceOf(propertyOwner);
                        // tokens.erc20Tokens.length == 1 && tokens.erc20Tokens[0]) == quoteTokenAddress

                        uint256 feeAmount = (propertyOwnerBalance * FEE_BP) /
                                    BASE_POINT;
                        if (feeAmount > 0) {
                            IERC20(quoteTokenAddress).safeTransferFrom(
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

    function getPropertyState(address propertyOwner)
    public
    view
    returns (PropertyState)
    {
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
                return PropertyState.OwnerAlive;
            }
        }

        return PropertyState.NotExist;
    }
}
