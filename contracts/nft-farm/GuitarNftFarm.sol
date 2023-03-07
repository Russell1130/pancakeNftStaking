pragma solidity ^0.6.0;
import "./ERC721.sol";






contract GuitarNftFarm is Ownable, ReentrancyGuard, IERC721Receiver {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    IBEP20 public stakingToken;
    ERC721Enumerable public nftToken;

    uint256 public startAt; // NFT Farming Start Date
    uint256 public endAt; // NFT Farming End Date

    uint256 public totalNftsToSell; // Total NFTs to sell
    uint256 public nftPrice; // NFT price in staking token
    uint256 public maxPerUser; // Max NFTs an user can get
    uint256 public totalNftsSold = 0; // Nfts sold to users including locked
    uint256 public totalNftsLocked = 0; // Nfts locked now
    uint256 public totalTokensLocked = 0; // Sum of tokens locked
    uint16 public depositFeeBP; // Deposit fee
    address public feeAddress; // Fee address
    uint256 public lockPeriod; // Lock period for getting NFTs

    uint16 public constant MAX_DEPOSIT_FEE = 2000; // Max deposit fee 20%
    uint256 public constant MAX_LOCK_PERIOD = 90 days; // Max lock period 3 months

    mapping(address => UserInfo) public userInfo;

    struct UserInfo {
        uint256 nftsLocked; // NFTs locked now
        uint256 tokensLocked; // Tokens locked now
        uint256 nftsPurchased; // NFTs purchased so far including locked
        uint256 lastStakedAt; // Last staked time
    }

    event Staked(
        address indexed user,
        uint256 tokenAmount,
        uint256 nftToBuyAmount
    );
    event Claimed(
        address indexed user,
        uint256 claimedTokenAmount,
        uint256 claimedNftAmount
    );
    event StartDateUpdated(uint256 oldDate, uint256 newDate);
    event EndDateUpdated(uint256 oldDate, uint256 newDate);
    event TotalNftsToSellUpdated(uint256 oldAmount, uint256 newAmount);
    event MaxPerUserUpdated(uint256 oldLimit, uint256 newLimit);
    event NftPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event FarmingEnded();
    event DepositFeeUpdated(uint16 oldFee, uint16 newFee);
    event FeeAddressUpdated(address oldAddress, address newAddress);
    event LockPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event EmergencyWithdrawn(address indexed user, uint256 amount);
    event AdminNftWithdrawn(uint256 amount);
    event AdminTokenRecovery(address tokenRecovered, uint256 amount);

    constructor(
        IBEP20 _stakingToken,
        ERC721Enumerable _nftToken,
        uint256 _startAt,
        uint256 _endAt,
        uint256 _totalNftsToSell,
        uint256 _nftPrice,
        uint256 _maxPerUser,
        uint16 _depositFeeBP,
        address _feeAddress,
        uint256 _lockPeriod
    ) public {
        stakingToken = _stakingToken;
        nftToken = _nftToken;

        require(_startAt <= _endAt, "Start time should be before end time");
        require(
            _startAt >= block.timestamp,
            "Start time should be after current time"
        );
        startAt = _startAt;
        endAt = _endAt;

        totalNftsToSell = _totalNftsToSell;
        require(_nftPrice > 0, "Invalid nft price");
        nftPrice = _nftPrice;
        maxPerUser = _maxPerUser;

        require(_depositFeeBP <= MAX_DEPOSIT_FEE, "Deposit fee exceeds limit");
        depositFeeBP = _depositFeeBP;
        require(_feeAddress != address(0), "Invalid fee address");
        feeAddress = _feeAddress;

        require(_lockPeriod <= MAX_LOCK_PERIOD, "Lock period exceeds limit");
        lockPeriod = _lockPeriod;
    }

    // Stake tokens to get NFTs
    function stake(uint256 tokenAmountToStake, uint256 nftAmountToBuy)
        external
        nonReentrant
    {
        require(block.timestamp >= startAt, "Farm not started yet");
        require(block.timestamp < endAt, "Farm ended already");
        require(nftAmountToBuy > 0, "Invalid nft amount to buy");
        require(
            tokenAmountToStake >= nftAmountToBuy.mul(nftPrice),
            "Insufficient token amount"
        );

        UserInfo storage user = userInfo[msg.sender];
        user.nftsPurchased = user.nftsPurchased.add(nftAmountToBuy);
        user.nftsLocked = user.nftsLocked.add(nftAmountToBuy);
        require(
            user.nftsPurchased <= maxPerUser,
            "Exceeds user purchasable limit"
        );
        user.lastStakedAt = block.timestamp;

        totalNftsLocked = totalNftsLocked.add(nftAmountToBuy);
        totalNftsSold = totalNftsSold.add(nftAmountToBuy);
        require(
            nftToken.balanceOf(address(this)) >= totalNftsLocked,
            "Insufficient NFTs to be farmed"
        );

        uint256 balanceBefore = stakingToken.balanceOf(address(this));
        stakingToken.safeTransferFrom(
            msg.sender,
            address(this),
            tokenAmountToStake
        );
        tokenAmountToStake = stakingToken.balanceOf(address(this)).sub(
            balanceBefore
        );
        if (depositFeeBP > 0) {
            uint256 depositFee = tokenAmountToStake.mul(depositFeeBP).div(
                10000
            );
            if (depositFee > 0) {
                tokenAmountToStake = tokenAmountToStake.sub(depositFee);
                stakingToken.safeTransfer(feeAddress, depositFee);
            }
        }
        user.tokensLocked = user.tokensLocked.add(tokenAmountToStake);
        totalTokensLocked = totalTokensLocked.add(tokenAmountToStake);
        emit Staked(msg.sender, tokenAmountToStake, nftAmountToBuy);
    }

    // Claim tokens and NFTs locked
    function claim() external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        require(
            user.tokensLocked > 0 || user.nftsLocked > 0,
            "Nothing to claim"
        );
        require(
            stakingToken.balanceOf(address(this)) >= user.tokensLocked,
            "Less amount of staking token in the farm"
        );
        require(
            nftToken.balanceOf(address(this)) >= user.nftsLocked,
            "Less amount of nfts in the farm"
        );
        require(
            user.lastStakedAt.add(lockPeriod) <= block.timestamp,
            "Still in lock status"
        );

        // Token claim
        stakingToken.safeTransfer(msg.sender, user.tokensLocked);

        // Nft claim
        for (uint256 i = 0; i < user.nftsLocked; i++) {
            uint256 tokenId = nftToken.tokenOfOwnerByIndex(address(this), 0);
            nftToken.safeTransferFrom(address(this), msg.sender, tokenId);
        }

        emit Claimed(msg.sender, user.tokensLocked, user.nftsLocked);

        totalNftsLocked = totalNftsLocked.sub(user.nftsLocked);
        totalTokensLocked = totalTokensLocked.sub(user.tokensLocked);
        user.tokensLocked = 0;
        user.nftsLocked = 0;
    }

    // function to set the presale start date
    // only owner can call this function
    function setStartDate(uint256 _startAt) external onlyOwner {
        require(startAt > block.timestamp, "Farm already started");
        require(
            _startAt >= block.timestamp,
            "Start date should be after current time"
        );
        require(_startAt <= endAt, "Start date should be before end date");
        emit StartDateUpdated(startAt, _startAt);
        startAt = _startAt;
    }

    // Function to set the presale end date
    // only owner can call this function
    function setEndDate(uint256 _endAt) external onlyOwner {
        require(
            _endAt >= block.timestamp,
            "End date should be after current time"
        );
        require(_endAt >= startAt, "End date should be after start date");
        emit EndDateUpdated(endAt, _endAt);
        endAt = _endAt;
    }

    // function to set the total tokens to sell
    // only owner can call this function
    function setTotalNftsToSell(uint256 _totalNftsToSell) external onlyOwner {
        require(
            _totalNftsToSell >= totalNftsSold,
            "Alreday sold more than this amount"
        );
        emit TotalNftsToSellUpdated(totalNftsToSell, _totalNftsToSell);
        totalNftsToSell = _totalNftsToSell;
    }

    // function to set the maximum amount which a user can buy
    // only owner can call this function
    function setMaxPerUser(uint256 _maxPerUser) external onlyOwner {
        emit MaxPerUserUpdated(maxPerUser, _maxPerUser);
        maxPerUser = _maxPerUser;
    }

    // function to set the Nft price
    // only owner can call this function
    function setNftPrice(uint256 _nftPrice) external onlyOwner {
        require(_nftPrice > 0, "Invalid Nft price");
        emit NftPriceUpdated(nftPrice, _nftPrice);
        nftPrice = _nftPrice;
    }

    //function to end the sale
    //only owner can call this function
    function endFarming() external onlyOwner {
        require(endAt <= block.timestamp, "Farming already finished");
        endAt = block.timestamp;
        if (startAt > block.timestamp) {
            startAt = block.timestamp;
        }
        emit FarmingEnded();
    }

    function updateDepositFee(uint16 _depositFeeBP) external onlyOwner {
        require(_depositFeeBP <= MAX_DEPOSIT_FEE, "Deposit fee exceeds limit");
        emit DepositFeeUpdated(depositFeeBP, _depositFeeBP);
        depositFeeBP = _depositFeeBP;
    }

    function updateFeeAddresss(address _feeAddress) external onlyOwner {
        require(_feeAddress != address(0), "Invalid fee address");
        emit FeeAddressUpdated(feeAddress, _feeAddress);
        feeAddress = _feeAddress;
    }

    function updateLockPeriod(uint256 _lockPeriod) external onlyOwner {
        require(_lockPeriod <= MAX_LOCK_PERIOD, "Lock period exceeds limit");
        emit LockPeriodUpdated(lockPeriod, _lockPeriod);
        lockPeriod = _lockPeriod;
    }

    //function to withdraw unsold tokens
    //only owner can call this function
    function withdrawRemainedNfts(uint256 nftAmount)
        external
        onlyOwner
        nonReentrant
    {
        uint256 nftsInFarm = nftToken.balanceOf(address(this));
        require(
            nftsInFarm >= nftAmount.add(totalNftsLocked),
            "Insufficient NFT amount"
        );

        for (uint256 i = 0; i < nftsInFarm; i++) {
            uint256 tokenId = nftToken.tokenOfOwnerByIndex(address(this), 0);
            nftToken.safeTransferFrom(address(this), msg.sender, tokenId);
        }

        emit AdminNftWithdrawn(nftAmount);
    }

    // Emergency withdraw tokens from the farm
    function emergencyWithdraw() external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        require(user.tokensLocked > 0, "Nothing to withdraw");
        require(
            stakingToken.balanceOf(address(this)) >= user.tokensLocked,
            "Less amount of staking token in the farm"
        );

        // Token claim
        stakingToken.safeTransfer(msg.sender, user.tokensLocked);

        emit EmergencyWithdrawn(msg.sender, user.tokensLocked);

        totalNftsLocked = totalNftsLocked.sub(user.nftsLocked);
        totalNftsSold = totalNftsSold.sub(user.nftsLocked);
        totalTokensLocked = totalTokensLocked.sub(user.tokensLocked);
        user.nftsPurchased = user.nftsPurchased.sub(user.nftsLocked);
        user.tokensLocked = 0;
        user.nftsLocked = 0;
    }

    /**
     * @notice It allows the admin to recover wrong tokens sent to the contract
     * @param _tokenAddress: the address of the token to withdraw
     * @param _tokenAmount: the number of tokens to withdraw
     * @dev This function is only callable by admin.
     */
    function recoverWrongTokens(address _tokenAddress, uint256 _tokenAmount)
        external
        onlyOwner
    {
        require(
            _tokenAddress != address(stakingToken),
            "Cannot be staked token"
        );

        IBEP20(_tokenAddress).safeTransfer(msg.sender, _tokenAmount);

        emit AdminTokenRecovery(_tokenAddress, _tokenAmount);
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
