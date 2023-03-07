
pragma solidity 0.6.12;
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/utils/Pausable.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';
import '@openzeppelin/contracts/token/ERC721/IERC721.sol';
contract GuitarNftStaking is Ownable,ReentrancyGuard, Pausable, IERC721Receiver {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.UintSet;
    using SafeERC20 for IERC20;

    /** Staking NFT address */
    address public _stakeNftAddress;
    /** Reward Token address */
    address public _rewardTokenAddress;
    /** Reward per block */
    uint256 public _rewardPerBlock = 1 ether;
    /** Max NFTs that a user can stake */
    uint256 public _maxNftsPerUser = 1;
    /** Staking start & end block */
    uint256 public _startBlock;
    uint256 public _endBlock;

    struct UserInfo {
        EnumerableSet.UintSet stakedNfts;
        uint256 rewards;
        uint256 lastRewardBlock;
    }

    // Info of each user that stakes LP tokens.
    mapping(address => UserInfo) private _userInfo;

    event RewardTokenUpdated(address oldToken, address newToken);
    event RewardPerBlockUpdated(uint256 oldValue, uint256 newValue);
    event Staked(address indexed account, uint256 tokenId);
    event Withdrawn(address indexed account, uint256 tokenId);
    event Harvested(address indexed account, uint256 amount);
    event InsufficientRewardToken(
        address indexed account,
        uint256 amountNeeded,
        uint256 balance
    );

    constructor(
        address __stakeNftAddress,
        address __rewardTokenAddress,
        uint256 __startBlock,
        uint256 __endBlock,
        uint256 __rewardPerBlock
    ) public {
        IERC20(__rewardTokenAddress).balanceOf(address(this));
        IERC721(__stakeNftAddress).balanceOf(address(this));
        require(__rewardPerBlock > 0, "Invalid reward per block");
        require(
            __startBlock <= __endBlock,
            "Start block must be before end block"
        );
        require(
            __startBlock > block.number,
            "Start block must be after current block"
        );

        _stakeNftAddress = __stakeNftAddress;
        _rewardTokenAddress = __rewardTokenAddress;
        _rewardPerBlock = __rewardPerBlock;
        _startBlock = __startBlock;
        _endBlock = __endBlock;
    }

    function viewUserInfo(address __account)
        external
        view
        returns (
            uint256[] memory stakedNfts,
            uint256 rewards,
            uint256 lastRewardBlock
        )
    {
        UserInfo storage user = _userInfo[__account];
        rewards = user.rewards;
        lastRewardBlock = user.lastRewardBlock;
        uint256 countNfts = user.stakedNfts.length();
        if (countNfts == 0) {
            // Return an empty array
            stakedNfts = new uint256[](0);
        } else {
            stakedNfts = new uint256[](countNfts);
            uint256 index;
            for (index = 0; index < countNfts; index++) {
                stakedNfts[index] = tokenOfOwnerByIndex(__account, index);
            }
        }
    }

    function tokenOfOwnerByIndex(address __account, uint256 __index)
        public
        view
        returns (uint256)
    {
        UserInfo storage user = _userInfo[__account];
        return user.stakedNfts.at(__index);
    }

    function userStakedNFTCount(address __account)
        public
        view
        returns (uint256)
    {
        UserInfo storage user = _userInfo[__account];
        return user.stakedNfts.length();
    }

    function updateMaxNftsPerUser(uint256 __maxLimit) external onlyOwner {
        require(__maxLimit > 0, "Invalid limit value");
        _maxNftsPerUser = __maxLimit;
    }

    function updateRewardTokenAddress(address __rewardTokenAddress)
        external
        onlyOwner
    {
        require(_startBlock > block.number, "Staking started already");
        IERC20(__rewardTokenAddress).balanceOf(address(this));
        emit RewardTokenUpdated(_rewardTokenAddress, __rewardTokenAddress);
        _rewardTokenAddress = __rewardTokenAddress;
    }

    function updateRewardPerBlock(uint256 __rewardPerBlock) external onlyOwner {
        require(__rewardPerBlock > 0, "Invalid reward per block");
        emit RewardPerBlockUpdated(_rewardPerBlock, __rewardPerBlock);
        _rewardPerBlock = __rewardPerBlock;
    }

    function updateStartBlock(uint256 __startBlock) external onlyOwner {
        require(
            __startBlock <= _endBlock,
            "Start block must be before end block"
        );
        require(__startBlock > block.number, "Start block must be after current block");
        require(_startBlock > block.number, "Staking started already");
        _startBlock = __startBlock;
    }

    function updateEndBlock(uint256 __endBlock) external onlyOwner {
        require(
            __endBlock >= _startBlock,
            "End block must be after start block"
        );
        require(
            __endBlock > block.number,
            "End block must be after current block"
        );
        _endBlock = __endBlock;
    }

    function isStaked(address __account, uint256 __tokenId)
        public
        view
        returns (bool)
    {
        UserInfo storage user = _userInfo[__account];
        return user.stakedNfts.contains(__tokenId);
    }

    function pendingRewards(address __account) public view returns (uint256) {
        UserInfo storage user = _userInfo[__account];

        uint256 fromBlock = user.lastRewardBlock < _startBlock ? _startBlock : user.lastRewardBlock;
        uint256 toBlock = block.number < _endBlock ? block.number : _endBlock;
        if (toBlock < fromBlock) {
            return user.rewards;
        }

        uint256 amount = toBlock
            .sub(fromBlock)
            .mul(userStakedNFTCount(__account))
            .mul(_rewardPerBlock);

        return user.rewards.add(amount);
    }


    function stake(uint256[] memory tokenIdList)
        external
        nonReentrant
        whenNotPaused
    {
        require(
            IERC721(_stakeNftAddress).isApprovedForAll(
                _msgSender(),
                address(this)
            ),
            "Not approve nft to staker address"
        );
        require(
            userStakedNFTCount(_msgSender()).add(tokenIdList.length) <=
                _maxNftsPerUser,
            "Exceeds the max limit per user"
        );

        UserInfo storage user = _userInfo[_msgSender()];
        uint256 pendingAmount = pendingRewards(_msgSender());
        if (pendingAmount > 0) {
            uint256 amountSent = safeRewardTransfer(
                _msgSender(),
                pendingAmount
            );
            user.rewards = pendingAmount.sub(amountSent);
            emit Harvested(_msgSender(), amountSent);
        }

        for (uint256 i = 0; i < tokenIdList.length; i++) {
            IERC721(_stakeNftAddress).safeTransferFrom(
                _msgSender(),
                address(this),
                tokenIdList[i]
            );

            user.stakedNfts.add(tokenIdList[i]);

            emit Staked(_msgSender(), tokenIdList[i]);
        }
        user.lastRewardBlock = block.number;
    }

    function withdraw(uint256[] memory tokenIdList) external nonReentrant {
        UserInfo storage user = _userInfo[_msgSender()];
        uint256 pendingAmount = pendingRewards(_msgSender());
        if (pendingAmount > 0) {
            uint256 amountSent = safeRewardTransfer(
                _msgSender(),
                pendingAmount
            );
            user.rewards = pendingAmount.sub(amountSent);
            emit Harvested(_msgSender(), amountSent);
        }

        for (uint256 i = 0; i < tokenIdList.length; i++) {
            require(tokenIdList[i] > 0, "Invaild token id");

            require(
                isStaked(_msgSender(), tokenIdList[i]),
                "Not staked this nft"
            );

            IERC721(_stakeNftAddress).safeTransferFrom(
                address(this),
                _msgSender(),
                tokenIdList[i]
            );

            user.stakedNfts.remove(tokenIdList[i]);

            emit Withdrawn(_msgSender(), tokenIdList[i]);
        }
        user.lastRewardBlock = block.number;
    }

    function safeRewardTransfer(address __to, uint256 __amount)
        internal
        returns (uint256)
    {
        uint256 balance = IERC20(_rewardTokenAddress).balanceOf(address(this));
        if (balance >= __amount) {
            IERC20(_rewardTokenAddress).safeTransfer(__to, __amount);
            return __amount;
        }

        if (balance > 0) {
            IERC20(_rewardTokenAddress).safeTransfer(__to, balance);
        }
        emit InsufficientRewardToken(__to, __amount, balance);
        return balance;
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
