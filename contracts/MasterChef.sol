// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./interfaces/IERC20.sol";
import "./libraries/SafeERC20.sol";

import "./FOCToken.sol";
import "./SFOCBar.sol";

// import "@nomiclabs/buidler/console.sol";
// MasterChef is the master of FOC. He can make FOC and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once FOC is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of FOCs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accFOCPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accFOCPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. FOCs to distribute per block.
        uint256 lastRewardBlock; // Last block number that FOCs distribution occurs.
        uint256 accFOCPerShare; // Accumulated FOCs per share, times 1e12. See below.
    }

    // The FOC TOKEN!
    FOCToken public FOC;
    // The SFOC TOKEN!
    SFOCBar public SFOC;
    // Dev address.
    address public devaddr;
    address public treasury;
    // FOC tokens created per block.
    uint256 public FOCPerBlock;
    // Bonus muliplier for early FOC makers.
    uint256 public BONUS_MULTIPLIER = 1;
    uint256 public constant MAX_FEE = 500; // 5%
    uint256 public Fee = 200; // 2%
    uint256 public constant MAX_RewardFEE = 500; // 5%
    uint256 public RewardFee = 200; // 2%

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when FOC mining starts.
    uint256 public startBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        FOCToken _FOC,
        SFOCBar _SFOC,
        address _devaddr,
        uint256 _FOCPerBlock,
        uint256 _startBlock,
        address _treasury
    ) public {
        FOC = _FOC;
        SFOC = _SFOC;
        devaddr = _devaddr;
        FOCPerBlock = _FOCPerBlock;
        startBlock = _startBlock;
        treasury = _treasury;

        // staking pool
        poolInfo.push(PoolInfo({lpToken: _FOC, allocPoint: 1000, lastRewardBlock: startBlock, accFOCPerShare: 0}));

        totalAllocPoint = 1000;
    }

    function updateMultiplier(uint256 multiplierNumber) public onlyOwner {
        BONUS_MULTIPLIER = multiplierNumber;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }


    function setFee(uint256 _Fee) public onlyOwner {
        require(_Fee <= MAX_FEE, "Fee cannot be more than MAX_FEE");
        Fee = _Fee;
    }

    
    function setRewardFee(uint256 _RewardFee) public onlyOwner {
        require(_RewardFee <= MAX_RewardFEE, "RewardFee cannot be more than MAX_RewardFEE");
        RewardFee = _RewardFee;
    }


    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({lpToken: _lpToken, allocPoint: _allocPoint, lastRewardBlock: lastRewardBlock, accFOCPerShare: 0})
        );
        updateStakingPool();
    }

    // Update the given pool's FOC allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
            updateStakingPool();
        }
    }

    function updateStakingPool() internal {
        uint256 length = poolInfo.length;
        uint256 points = 0;
        for (uint256 pid = 1; pid < length; ++pid) {
            points = points.add(poolInfo[pid].allocPoint);
        }
        if (points != 0) {
            points = points.div(3);
            totalAllocPoint = totalAllocPoint.sub(poolInfo[0].allocPoint).add(points);
            poolInfo[0].allocPoint = points;
        }
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending FOCs on frontend.
    function pendingFOC(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accFOCPerShare = pool.accFOCPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 FOCReward = multiplier.mul(FOCPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accFOCPerShare = accFOCPerShare.add(FOCReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accFOCPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 FOCReward = multiplier.mul(FOCPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        FOC.mint(devaddr, FOCReward.div(10));
        FOC.mint(address(SFOC), FOCReward);
        pool.accFOCPerShare = pool.accFOCPerShare.add(FOCReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for FOC allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        require(_pid != 0, "deposit FOC by staking");

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accFOCPerShare).div(1e12).sub(user.rewardDebt);
            uint256 currentRewardFee = pending.mul(RewardFee).div(10000);
            if (pending > 0) {
                safeFOCTransfer(msg.sender, pending.sub(currentRewardFee));
                safeFOCTransfer(treasury, currentRewardFee);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accFOCPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public {
        require(_pid != 0, "withdraw FOC by unstaking");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accFOCPerShare).div(1e12).sub(user.rewardDebt);
        uint256 currentRewardFee = pending.mul(RewardFee).div(10000);
        if (pending > 0) {
            safeFOCTransfer(msg.sender, pending.sub(currentRewardFee));
            safeFOCTransfer(treasury, currentRewardFee);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            uint256 currentFee = _amount.mul(Fee).div(10000);
            pool.lpToken.safeTransfer(address(msg.sender), _amount.sub(currentFee));
            pool.lpToken.safeTransfer(treasury, currentFee);
            
        }
        user.rewardDebt = user.amount.mul(pool.accFOCPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Stake FOC tokens to MasterChef
    function enterStaking(uint256 _amount) public {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        updatePool(0);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accFOCPerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                safeFOCTransfer(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accFOCPerShare).div(1e12);

        SFOC.mint(msg.sender, _amount);
        emit Deposit(msg.sender, 0, _amount);
    }

    // Withdraw FOC tokens from STAKING.
    function leaveStaking(uint256 _amount) public {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(0);
        uint256 pending = user.amount.mul(pool.accFOCPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            safeFOCTransfer(msg.sender, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accFOCPerShare).div(1e12);

        SFOC.burn(msg.sender, _amount);
        emit Withdraw(msg.sender, 0, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Safe FOC transfer function, just in case if rounding error causes pool to not have enough FOCs.
    function safeFOCTransfer(address _to, uint256 _amount) internal {
        SFOC.safeFOCTransfer(_to, _amount);
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }
}
