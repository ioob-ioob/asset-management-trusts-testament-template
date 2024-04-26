// SPDX-License-Identifier: MIT
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

    struct TestamentTokens {
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

    struct DeathConfirmation {
        uint256 confirmed;
        uint256 quorum;
        uint256 confirmationTime;
        address[] guardians;
    }

    struct Testament {
        uint256 expirationTime;
        Successors successors;
        DeathConfirmation voting;
    }

    enum TestamentState {
        NotExist,
        OwnerAlive,
        VoteActive,
        ConfirmationWaiting,
        Unlocked
    }

    uint256 public constant CONFIRMATION_LOCK = 180 days;
    uint256 public constant MIN_TESTAMENT_LOCK = 360 days;
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
    mapping(address => Testament) public testaments;
    mapping(address => bool) public firstPayment;

    // testamentOwner  => token   =>  amountPerShare
    mapping(address => mapping(address => uint256)) private amountsPerShare;
    // testamentOwner   =>  successor   =>  token  => already withdrawn
    mapping(address => mapping(address => mapping(address => bool)))
        private alreadyWithdrawn;

    modifier correctStatus(
        TestamentState _state,
        address _testamentOwner,
        string memory _error
    ) {
        require(getTestamentState(_testamentOwner) == _state, _error);
        _;
    }

    event SuccessorsChanged(address testamentOwner, Successors newSuccessors);
    event TestamentDeleted(address testamentOwner);

    event GuardiansChanged(
        address user,
        uint256 newVoteQuorum,
        address[] newGuardians
    );

    event CreateTestament(address user, Testament newTestament);

    event TestatorAlive(address testamentOwner, uint256 newExpirationTime);

    event DeathConfirmed(address testamentOwner, uint256 deathConfirmationTime);

    event GetTestament(address testamentOwner, address successor);

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
            TestamentState.OwnerAlive,
            msg.sender,
            "first confirm that you are still alive"
        )
    {
        Testament storage userTestament = testaments[msg.sender];

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

        userTestament.successors = _newSuccessors;

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
            TestamentState.OwnerAlive,
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

        Testament storage userTestament = testaments[msg.sender];
        // reset current voting state
        userTestament.voting.confirmed = 0;
        userTestament.voting.guardians = _guardians;
        userTestament.voting.quorum = _quorum;
        emit GuardiansChanged(msg.sender, _quorum, _guardians);
    }

    function deleteTestament() external {
        require(
            getTestamentState(msg.sender) < TestamentState.Unlocked,
            "alive only"
        );
        delete testaments[msg.sender];
        emit TestamentDeleted(msg.sender);
    }

    /**
     * @notice create testament
     * @param _quorum: voting quorum
     * @param _guardians: array of guardians
     * @param _successors: array of successors
     */
    function createTestament(
        uint256 _quorum,
        address[] calldata _guardians,
        Successors calldata _successors
    )
        external
        correctStatus(TestamentState.NotExist, msg.sender, "already exist")
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

        Testament memory newTestament = Testament(
            block.timestamp + MIN_TESTAMENT_LOCK,
            _successors,
            DeathConfirmation(0, _quorum, 0, _guardians)
        );

        testaments[msg.sender] = newTestament;

        emit CreateTestament(msg.sender, newTestament);
    }

    /**
     * @notice confirm that you are still alive
     */
    function imAlive() external {
        TestamentState currentState = getTestamentState(msg.sender);
        require(
            currentState == TestamentState.OwnerAlive ||
                currentState == TestamentState.VoteActive,
            "state should be OwnerAlive or VoteActive or you can try to delete the testament while it not confirmed"
        );
        Testament memory userTestament = testaments[msg.sender];

        require(
            block.timestamp >
                (userTestament.expirationTime - MIN_TESTAMENT_LOCK),
            "no more than two periods"
        );
        userTestament.voting.confirmed = 0;
        userTestament.expirationTime += MIN_TESTAMENT_LOCK;

        testaments[msg.sender] = userTestament;

        emit TestatorAlive(msg.sender, userTestament.expirationTime);
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

    function getVotersCount(address testamentOwner)
        external
        view
        returns (uint256 voiceCount)
    {
        DeathConfirmation memory voting = testaments[testamentOwner].voting;
        voiceCount = _getVotersCount(voting.confirmed);
    }

    function getVoters(address testamentOwner)
        external
        view
        returns (address[] memory)
    {
        DeathConfirmation memory voting = testaments[testamentOwner].voting;
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

    function confirmDeath(address testamentOwner)
        external
        correctStatus(
            TestamentState.VoteActive,
            testamentOwner,
            "voting is not active"
        )
    {
        Testament storage userTestament = testaments[testamentOwner];
        DeathConfirmation memory voting = userTestament.voting;

        for (uint256 i = 0; i < voting.guardians.length; i++) {
            if (
                msg.sender == voting.guardians[i] &&
                voting.confirmed & (1 << i) == 0
            ) {
                voting.confirmed |= (1 << i);
            }
        }
        userTestament.voting.confirmed = voting.confirmed;

        if (_getVotersCount(voting.confirmed) >= voting.quorum) {
            userTestament.voting.confirmationTime =
                block.timestamp +
                CONFIRMATION_LOCK;
            emit DeathConfirmed(
                testamentOwner,
                userTestament.voting.confirmationTime
            );
        }
    }

    /**
     * @notice get testament after death confirmation
     * call from successors
     * @param testamentOwner: testament creator
     * withdrawal info:
     * @param tokens: {IERC20[] erc20Tokens;NFTinfo[] erc721Tokens;NFTinfo[] erc1155Tokens;}
     * erc20Tokens: array of erc20 tokens
     * erc721Tokens: array of {address nftAddress;uint256[] ids;} objects
     * erc1155Tokens: array of {address nftAddress;uint256[] ids;} objects
     */

    function withdrawTestament(
        address testamentOwner,
        TestamentTokens calldata tokens
    )
        external
        correctStatus(
            TestamentState.Unlocked,
            testamentOwner,
            "Testament must be Unlocked"
        )
    {
        Testament memory userTestament = testaments[testamentOwner];
        Successors memory userSuccessors = userTestament.successors;

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
                    testamentOwner
                ][msg.sender];
                if (alreadyDone[address(tokens.erc20Tokens[i])] == false) {
                    alreadyDone[address(tokens.erc20Tokens[i])] = true;
                    mapping(address => uint256)
                        storage amountPerShare = amountsPerShare[
                            testamentOwner
                        ];
                    uint256 perShare = amountPerShare[
                        address(tokens.erc20Tokens[i])
                    ];

                    if (perShare == 0) {
                        uint256 testamentOwnerBalance = tokens
                            .erc20Tokens[i]
                            .balanceOf(testamentOwner);
                        // tokens.erc20Tokens.length == 1 && tokens.erc20Tokens[0]) == quoteTokenAddress

                        uint256 feeAmount = (testamentOwnerBalance * FEE_BP) /
                            BASE_POINT;
                        if (feeAmount > 0) {
                            IERC20(quoteTokenAddress).safeTransferFrom(
                                testamentOwner,
                                feeAddress,
                                feeAmount
                            );
                            testamentOwnerBalance -= feeAmount;
                        }

                        if (testamentOwnerBalance > BASE_POINT) {
                            perShare = testamentOwnerBalance / BASE_POINT;
                            amountPerShare[
                                address(tokens.erc20Tokens[i])
                            ] = perShare;

                            tokens.erc20Tokens[i].safeTransferFrom(
                                testamentOwner,
                                address(this),
                                testamentOwnerBalance
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
                        testamentOwner,
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
                    ).balanceOf(testamentOwner, tokens.erc1155Tokens[i].ids[x]);
                }
                IERC1155(tokens.erc1155Tokens[i].nftAddress)
                    .safeBatchTransferFrom(
                        testamentOwner,
                        msg.sender,
                        tokens.erc1155Tokens[i].ids,
                        batchBalances,
                        ""
                    );
            }
        }

        emit GetTestament(testamentOwner, msg.sender);
    }

    function getTestamentState(address testamentOwner)
        public
        view
        returns (TestamentState)
    {
        Testament memory userTestament = testaments[testamentOwner];
        DeathConfirmation memory voting = userTestament.voting;

        if (userTestament.expirationTime > 0) {
            // voting started
            if (block.timestamp > userTestament.expirationTime) {
                if (
                    _getVotersCount(voting.confirmed) >= voting.quorum ||
                    block.timestamp >
                    userTestament.expirationTime + CONTINGENCY_PERIOD
                ) {
                    if (block.timestamp < voting.confirmationTime) {
                        return TestamentState.ConfirmationWaiting;
                    }

                    return TestamentState.Unlocked;
                }

                if (
                    block.timestamp <
                    (userTestament.expirationTime + MIN_TESTAMENT_LOCK)
                ) {
                    return TestamentState.VoteActive;
                }

                return TestamentState.NotExist;
            } else {
                return TestamentState.OwnerAlive;
            }
        }

        return TestamentState.NotExist;
    }
}
