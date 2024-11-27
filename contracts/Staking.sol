// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol"; // Import SafeERC20
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface INonfungiblePositionManager {
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

contract StakingAndFarming is Ownable, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20; // Use SafeERC20 for IERC20

    uint256 public constant UNSTAKE_COOLDOWN = 4 hours;

    address public feeWallet;
    uint256 public depositFeeBps = 200; // 2%
    uint256 public withdrawalFeeBps = 500; // 5%
    address public positionManager; // Uniswap V3 NonfungiblePositionManager contract

    struct Pool {
        uint256 baseApy; // Maximum APY
        uint256 minApy;  // Minimum APY
        uint256 scalingFactor; // Determines APY reduction rate
        uint256 apy; // Current APY
        uint256 totalStaked; // For token pools
        IERC20 stakingToken;
        IERC721 nftToken;
        IERC20 rewardToken;
        bool supportsNFT;
        bool active;
        uint24 feeTier; // Changed from uint256 to uint24
        address lpPairContract; // LP pair contract address
        mapping(address => uint256) userStakes;
        mapping(address => uint256[]) userNFTs;
        mapping(address => uint256) lastStakeTime;
        uint256 totalRewardsDistributed; // Track total rewards distributed per pool
        uint256[] lpPositions; // Array to store LP token IDs for the pool
    }

    mapping(uint256 => Pool) public pools;
    uint256 public poolCount;
    mapping(uint256 => address[]) private poolUsers; // Mapping to track users per pool
    mapping(uint256 => mapping(address => bool)) private poolUserExists; // Efficient user existence check
    mapping(uint256 => mapping(uint256 => address)) private nftOwner; // Mapping to track NFT owners

    event PoolCreated(
        uint256 poolId,
        uint256 baseApy,
        uint256 minApy,
        uint256 scalingFactor,
        address stakingToken,
        address rewardToken,
        bool supportsNFT,
        uint24 feeTier, // Changed from uint256 to uint24
        address lpPairContract
    );
    event Staked(address indexed user, uint256 poolId, uint256 amount, uint256[] nftIds);
    event Unstaked(address indexed user, uint256 poolId, uint256 amount, uint256[] nftIds);
    event RewardClaimed(address indexed user, uint256 poolId, uint256 reward);
    event PoolActivated(uint256 poolId);
    event PoolDeactivated(uint256 poolId);
    event FeesUpdated(uint256 depositFee, uint256 withdrawalFee);
    event RewardsDeposited(uint256 indexed poolId, uint256 amount); // New event for depositRewards
    event MinimumStakeSet(uint256 indexed poolId, uint256 minimumStake);
    event RewardCalculated(address indexed user, uint256 poolId, uint256 reward); // New event for reward calculation

    modifier onlyValidFeeWallet() {
        require(feeWallet != address(0), "Fee wallet not set");
        _;
    }

    modifier onlyActivePool(uint256 poolId) {
        require(poolId < poolCount, "Invalid pool ID");
        require(pools[poolId].active, "Inactive pool");
        _;
    }

    modifier meetsMinimumStake(uint256 poolId, uint256 amount) {
        require(amount >= minimumStake[poolId], "Stake amount too low");
        _;
    }

    constructor(address _feeWallet, address _positionManager, address initialOwner) Ownable(initialOwner) {
        require(_feeWallet != address(0), "Invalid fee wallet");
        require(_positionManager != address(0), "Invalid position manager");
        feeWallet = _feeWallet;
        positionManager = _positionManager;
    }

    function setFeeWallet(address _feeWallet) external onlyOwner {
        require(_feeWallet != address(0), "Invalid fee wallet");
        feeWallet = _feeWallet;
    }

    function updateFees(uint256 _depositFeeBps, uint256 _withdrawalFeeBps) external onlyOwner {
        require(_depositFeeBps <= 1000 && _withdrawalFeeBps <= 1000, "Fees too high");
        depositFeeBps = _depositFeeBps;
        withdrawalFeeBps = _withdrawalFeeBps;
        emit FeesUpdated(_depositFeeBps, _withdrawalFeeBps);
    }

    function createPool(
        uint256 _baseApy,
        uint256 _minApy,
        uint256 _scalingFactor,
        address _stakingToken,
        address _rewardToken,
        address _nftToken,
        bool _supportsNFT,
        uint24 _feeTier,
        address _lpPairContract
    ) external onlyOwner {
        require(_rewardToken != address(0), "Invalid reward token");
        if (!_supportsNFT) require(_stakingToken != address(0), "Invalid staking token");
        if (_supportsNFT) require(_nftToken != address(0), "Invalid NFT token");

        Pool storage pool = pools[poolCount];
        pool.baseApy = _baseApy;
        pool.minApy = _minApy;
        pool.scalingFactor = _scalingFactor;
        pool.apy = _baseApy; // Initialize with base APY
        pool.stakingToken = IERC20(_stakingToken);
        pool.rewardToken = IERC20(_rewardToken);
        pool.supportsNFT = _supportsNFT;
        pool.feeTier = _feeTier;
        pool.active = true;
        if (_supportsNFT) pool.nftToken = IERC721(_nftToken);
        pool.lpPairContract = _lpPairContract; // Store LP pair contract address

        emit PoolCreated(poolCount, _baseApy, _minApy, _scalingFactor, _stakingToken, _rewardToken, _supportsNFT, _feeTier, _lpPairContract);
        poolCount++;
    }

    function activatePool(uint256 poolId) external onlyOwner {
        pools[poolId].active = true;
        emit PoolActivated(poolId);
    }

    function deactivatePool(uint256 poolId) external onlyOwner {
        pools[poolId].active = false;
        emit PoolDeactivated(poolId);
    }

    function stake(
        uint256 poolId,
        uint256 amount,
        uint256[] calldata nftIds
    ) external nonReentrant onlyValidFeeWallet onlyActivePool(poolId) meetsMinimumStake(poolId, amount) {
        Pool storage pool = pools[poolId];
        require(amount > 0 || nftIds.length > 0, "Must stake tokens or NFTs");

        if (amount > 0) {
            require(!pool.supportsNFT, "Cannot stake tokens in an NFT pool"); // Enforce exclusive staking
            uint256 fee = (amount * depositFeeBps) / 10000;
            uint256 netAmount = amount - fee;

            pool.stakingToken.safeTransferFrom(msg.sender, address(this), netAmount);
            pool.stakingToken.safeTransferFrom(msg.sender, feeWallet, fee);

            pool.userStakes[msg.sender] += netAmount;
            pool.totalStaked += netAmount;

            adjustApy(poolId); // Adjust APY based on total staked tokens
        }

        if (nftIds.length > 0) {
            require(pool.supportsNFT, "NFTs not supported");

            for (uint256 i = 0; i < nftIds.length; i++) {
                // Ensure the NFT represents a valid position
                (, , , , , , , uint128 liquidity, , , , ) = INonfungiblePositionManager(positionManager).positions(nftIds[i]);
                require(liquidity > 0, "Invalid liquidity for NFT");

                pool.nftToken.safeTransferFrom(msg.sender, address(this), nftIds[i]);
                pool.userNFTs[msg.sender].push(nftIds[i]);
                nftOwner[poolId][nftIds[i]] = msg.sender; // Assign NFT owner
            }

            adjustApyNFT(poolId); // Adjust APY based on current liquidity
        }

        if (!poolUserExists[poolId][msg.sender]) {
            poolUserExists[poolId][msg.sender] = true;
            poolUsers[poolId].push(msg.sender);
        }

        pool.lastStakeTime[msg.sender] = block.timestamp;
        emit Staked(msg.sender, poolId, amount, nftIds);
    }

    function unstake(
        uint256 poolId,
        uint256 amount,
        uint256[] calldata nftIds
    ) external nonReentrant onlyValidFeeWallet onlyActivePool(poolId) {
        Pool storage pool = pools[poolId];
        require(amount > 0 || nftIds.length > 0, "Must unstake tokens or NFTs");
        require(block.timestamp >= pool.lastStakeTime[msg.sender] + UNSTAKE_COOLDOWN, "Cooldown active");

        if (amount > 0) {
            require(!pool.supportsNFT, "Cannot unstake tokens from an NFT pool"); // Enforce exclusive unstaking
            require(pool.userStakes[msg.sender] >= amount, "Insufficient tokens");

            uint256 fee = (amount * withdrawalFeeBps) / 10000;
            uint256 netAmount = amount - fee;

            pool.userStakes[msg.sender] -= amount;
            pool.totalStaked -= amount;

            pool.stakingToken.safeTransfer(msg.sender, netAmount);
            pool.stakingToken.safeTransfer(feeWallet, fee);

            adjustApy(poolId); // Adjust APY based on total staked tokens
        }

        if (nftIds.length > 0) {
            require(pool.supportsNFT, "NFTs not supported");

            for (uint256 i = 0; i < nftIds.length; i++) {
                uint256 index = findNFTIndex(pool.userNFTs[msg.sender], nftIds[i]);
                require(index < pool.userNFTs[msg.sender].length, "NFT not staked");

                pool.nftToken.safeTransferFrom(address(this), msg.sender, nftIds[i]);
                delete nftOwner[poolId][nftIds[i]];
                pool.userNFTs[msg.sender][index] = pool.userNFTs[msg.sender][pool.userNFTs[msg.sender].length - 1];
                pool.userNFTs[msg.sender].pop();
            }

            adjustApyNFT(poolId); // Adjust APY based on current liquidity
        }

        emit Unstaked(msg.sender, poolId, amount, nftIds);
    }

    function claimRewards(uint256 poolId) external nonReentrant onlyActivePool(poolId) {
        Pool storage pool = pools[poolId];
        uint256 reward = calculateReward(poolId, msg.sender);
        require(reward > 0, "No rewards available");

        // Update the last stake time before transferring to prevent reentrancy issues
        pool.lastStakeTime[msg.sender] = block.timestamp;

        // Use SafeERC20 for transfer
        pool.rewardToken.safeTransfer(msg.sender, reward);

        pool.totalRewardsDistributed += reward; // Track total rewards
        emit RewardClaimed(msg.sender, poolId, reward);
        emit RewardCalculated(msg.sender, poolId, reward);
    }

    function calculateReward(uint256 poolId, address user) public view returns (uint256) {
        Pool storage pool = pools[poolId];
        uint256 reward = 0;

        if (pool.supportsNFT) {
            uint256 userLiquidity = calculateUserLiquidity(poolId, user);
            if (userLiquidity > 0) {
                uint256 timeStakedNFT = block.timestamp - pool.lastStakeTime[user];

                // Multiplier based on user liquidity
                uint256 nftMultiplier = 100; // Default multiplier
                if (userLiquidity > 100000) {
                    nftMultiplier = 130; // 30% boost
                } else if (userLiquidity > 50000) {
                    nftMultiplier = 120; // 20% boost
                }

                reward += (userLiquidity * pool.apy * timeStakedNFT * nftMultiplier) / (365 days * 10000);
            }
        } else {
            uint256 userStake = pool.userStakes[user];
            if (userStake > 0) {
                uint256 timeStaked = block.timestamp - pool.lastStakeTime[user];

                // Multiplier based on staking duration
                uint256 multiplier = 100; // Default multiplier
                if (timeStaked > 90 days) {
                    multiplier = 150; // 50% boost
                } else if (timeStaked > 30 days) {
                    multiplier = 120; // 20% boost
                }

                reward += (userStake * pool.apy * timeStaked * multiplier) / (365 days * 10000);
            }
        }

        return reward;
    }

    function calculateTotalLiquidity(uint256 poolId, address account) public view returns (uint256) {
        Pool storage pool = pools[poolId];
        uint256[] memory userNFTsArray = pool.userNFTs[account];
        uint256 totalLiquidity = 0;

        for (uint256 i = 0; i < userNFTsArray.length; i++) {
            (, , , , , , , uint128 liquidity, , , , ) = INonfungiblePositionManager(positionManager).positions(userNFTsArray[i]);
            totalLiquidity += liquidity;
        }

        return totalLiquidity;
    }

    function calculateUserLiquidity(uint256 poolId, address user) internal view returns (uint256) {
        return calculateTotalLiquidity(poolId, user);
    }

    function adjustApy(uint256 poolId) internal {
        Pool storage pool = pools[poolId];
        uint256 totalStaked = pool.totalStaked;

        if (totalStaked >= pool.scalingFactor) {
            pool.apy = pool.minApy;
        } else {
            pool.apy = pool.baseApy - ((pool.baseApy - pool.minApy) * totalStaked) / pool.scalingFactor;
        }
    }

    function adjustApyNFT(uint256 poolId) internal {
        Pool storage pool = pools[poolId];
        uint256 totalLiquidity = calculateTotalLiquidity(poolId, address(this));

        if (totalLiquidity >= pool.scalingFactor) {
            pool.apy = pool.minApy;
        } else {
            pool.apy = pool.baseApy - ((pool.baseApy - pool.minApy) * totalLiquidity) / pool.scalingFactor;
        }
    }

    function findNFTIndex(uint256[] storage nftArray, uint256 nftId) internal view returns (uint256) {
        for (uint256 i = 0; i < nftArray.length; i++) {
            if (nftArray[i] == nftId) {
                return i;
            }
        }
        revert("NFT not found");
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // Function to fetch LP pair contract address
    function getLpPairContract(uint256 poolId) public view returns (address) {
        require(poolId < poolCount, "Invalid pool ID");
        return pools[poolId].lpPairContract;
    }

    // Function to fetch total liquidity in the LP pair
    function getTotalLiquidity(uint256 poolId) public view returns (uint128) {
        require(poolId < poolCount, "Invalid pool ID");

        uint256[] memory tokenIds = pools[poolId].lpPositions;
        uint128 totalLiquidity = 0;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            (, , , , , , , uint128 liquidity, , , , ) = INonfungiblePositionManager(positionManager).positions(tokenIds[i]);
            totalLiquidity += liquidity;
        }

        return totalLiquidity;
    }

    // Function to fetch user-specific data
    function getUserInfo(uint256 poolId, address user)
        external
        view
        returns (uint256 userStake, uint256[] memory userNFTsArray, uint256 lastStakeTimeVal, uint256 pendingRewards)
    {
        Pool storage pool = pools[poolId];
        uint256 rewards = calculateReward(poolId, user);
        return (
            pool.userStakes[user],
            pool.userNFTs[user],
            pool.lastStakeTime[user],
            rewards
        );
    }

    // Function to fetch all active pools
    function getActivePools() external view returns (uint256[] memory) {
        uint256[] memory activePools = new uint256[](poolCount);
        uint256 count = 0;

        for (uint256 i = 0; i < poolCount; i++) {
            if (pools[i].active) {
                activePools[count] = i;
                count++;
            }
        }

        // Resize the array to match the count of active pools
        assembly {
            mstore(activePools, count)
        }

        return activePools;
    }

    // Function to fetch pending rewards for a user
    function getPendingRewards(uint256 poolId, address user) external view returns (uint256) {
        require(poolId < poolCount, "Invalid pool ID");
        return calculateReward(poolId, user);
    }

    // Function to allow emergency withdrawal of staked tokens and NFTs
function emergencyWithdraw(uint256 poolId) external nonReentrant {
    require(poolId < poolCount, "Invalid pool ID");
    Pool storage pool = pools[poolId];

    uint256 stakedAmount = pool.userStakes[msg.sender];
    bool hasNFTs = pool.userNFTs[msg.sender].length > 0;
    require(stakedAmount > 0 || hasNFTs, "No stake to withdraw");

    // Withdraw tokens if any
    if (stakedAmount > 0) {
        require(!pool.supportsNFT, "Cannot withdraw tokens from an NFT pool");
        pool.userStakes[msg.sender] = 0;
        pool.totalStaked -= stakedAmount;

        pool.stakingToken.safeTransfer(msg.sender, stakedAmount);

        // Emit Unstaked event for token withdrawal with empty NFT array
        emit Unstaked(msg.sender, poolId, stakedAmount, new uint256[](0));
    }

    // Withdraw NFTs if any
    if (hasNFTs) {
        require(pool.supportsNFT, "Cannot withdraw NFTs from a token pool");
        uint256[] memory userNFTsArray = pool.userNFTs[msg.sender];
        for (uint256 i = 0; i < userNFTsArray.length; i++) {
            pool.nftToken.safeTransferFrom(address(this), msg.sender, userNFTsArray[i]);
            delete nftOwner[poolId][userNFTsArray[i]];
        }
        delete pool.userNFTs[msg.sender];

        // Emit Unstaked event for NFT withdrawal with the array of NFT IDs
        emit Unstaked(msg.sender, poolId, 0, userNFTsArray);
    }
}


    // Function to update certain details of a pool
function updatePoolDetails(
    uint256 poolId,
    uint256 newBaseApy,
    uint256 newMinApy,
    uint256 newScalingFactor,
    bool newActiveStatus
) external onlyOwner {
    require(poolId < poolCount, "Invalid pool ID");

    Pool storage pool = pools[poolId];
    pool.baseApy = newBaseApy;
    pool.minApy = newMinApy;
    pool.scalingFactor = newScalingFactor;
    pool.active = newActiveStatus;

    // Explicitly reset APY to baseApy
    pool.apy = newBaseApy;

    // Adjust APY based on new parameters
    if (pool.supportsNFT) {
        adjustApyNFT(poolId);
    } else {
        adjustApy(poolId);
    }
}


    // Function to set minimum stake requirement for a pool
    mapping(uint256 => uint256) public minimumStake;

    function setMinimumStake(uint256 poolId, uint256 amount) external onlyOwner {
        require(poolId < poolCount, "Invalid pool ID");
        minimumStake[poolId] = amount;
        emit MinimumStakeSet(poolId, amount);
    }

    // Function to deposit additional reward tokens for a specific pool
    function depositRewards(uint256 poolId, uint256 amount) external onlyOwner {
        require(poolId < poolCount, "Invalid pool ID");
        Pool storage pool = pools[poolId];

        pool.rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        emit RewardsDeposited(poolId, amount);
    }

    // Fallback function to prevent accidental ETH transfers
    fallback() external {
        revert("Direct ETH transfers not allowed");
    }
}
