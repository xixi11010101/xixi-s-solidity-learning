// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "../lib/openzeppelin-contracts/contracts/security/Pausable.sol";
import "../lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";


contract SmallWethStaking is ERC20, ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    // ===================== PRD 全局常量 =====================
    uint256 public constant ADMIN_SINGLE_MAX_AMOUNT = 500 ether;
    uint256 public constant SCALE = 1e36;
    uint256 public rewardFeeRate = 0.1e36; //10%手续费
    uint256 public slashMaxRatio = 0.1e36; //单次slash最大10%
    uint256 public depositMin = 1 ether;
    uint256 public depositPerUserMax = 50 ether;
    uint256 public depositPoolMax = 5000 ether;

    // ===================== 全局状态变量 =====================
    IERC20 public immutable weth;
    address public feeRecipient;

    uint256 public totalAssets; // 账面本金总额，仅用户质押本金
    uint256 public slashFactor; // 初始=SCALE，无罚没时1:1
    uint256 public rewardIndex; //全局奖励累计点位(放大1e36)
    uint256 public bufferReward; //空池暂存奖励缓冲区
    address public immutable timelock;

// 用户记账：仅【原始份额 + 用户上次结算到的rewardIndex】
    struct UserInfo {
        uint256 userShares; //原始份额，永久不变，slash不修改
        uint256 userRewardIndex; //用户奖励结算点位
    }
    mapping(address => uint256) public shares;
   
    struct SlashCheckpoint {
        uint256 snapshotRewardIndex; // 罚没瞬间全局rewardIndex（固化奖励）
        uint256 oldSlashFactor;
        uint256 timestamp;
        uint256 newSlashFactor;
        uint256 lossAmount;
        uint256 totalAssetsAfterSlash;

    }
    SlashCheckpoint[] public slashCheckpoints;

    struct HighRiskProposal {
        bytes callData;
        uint256 createBlock;
        bool executed;
    }
    HighRiskProposal[] public highRiskProposals;

    mapping(address => UserInfo) public userInfo;

    // ===================== 事件（严格匹配PRD） =====================
    event Staked(address indexed user, uint256 amount, uint256 mintedShares);
    event Unstaked(address indexed user, uint256 sharesBurned, uint256 wethReturned, uint256 rewardClaimed);
    event RewardClaimed(address indexed user, address indexed recipient, uint256 rewardAmount);
    event RewardDeposited(address indexed rewardSender, uint256 totalReward, uint256 feeAmount, uint256 netRewardToPool);
    event BufferRewardMigrated(uint256 migratedAmount);
    event SlashExecuted(uint256 indexed checkpointId,uint256 oldSlashFactor,uint256 newSlashFactor, uint256 lossAmount, uint256 newTotalAssets);
    event FeeRecipientSet(address oldRecipient, address newRecipient);
    event DepositLimitUpdated(uint256 oldMin,uint256 oldPerUserMax,uint256 oldPoolMax,uint256 newMin, uint256 newPerUserMax, uint256 newPoolMax);
    event RewardFeeRateUpdated(uint256 oldRate, uint256 newRate);
    event Paused(bool pausedState);

    // ===================== 自定义Error =====================
    error InvalidAddress();
    error InvalidAmount();
    error ZeroAmount();
    error ExceedUserDepositLimit();
    error ExceedPoolDepositLimit();
    error DepositLessThanMin();
    error InsufficientShares();
    error InsufficientBalance();
    error SlashLossExceedMaxRatio();
    error SlashLossExceedTotalAssets();
    error AlreadyPaused();
    error AlreadyUnpaused();
    error NotOwner();
    error RewardAlreadySettled();
    error BufferCannotWithdraw();
    error NotTimelock();
    error InvalidLimit();
    error AdminSingleAmountExceedLimit();
    error HighRiskProposalRateLimitExceeded();
    error ProposalNotExist();
    error ProposalAlreadyExecuted();
    error ProposalNotReady();

    // ===================== 构造函数 =====================
    constructor(address _weth, address _feeRecipient, address _owner,address _timelock) ERC20("StakeShare", "STK")  {
        if(_weth == address(0)) revert InvalidAddress();
        if(_feeRecipient == address(0)) revert InvalidAddress();
        if(_timelock == address(0)) revert InvalidAddress();
        weth = IERC20(_weth);
        feeRecipient = _feeRecipient;
        timelock = _timelock;
        slashFactor = SCALE; //初始无罚没
        _transferOwnership(_owner);
    }

    // ===================== 修饰器 =====================
    modifier whenNotPausedContract() {
    require(!paused(), "Pausable: paused");
    _;
    }

    modifier onlyTimelock() {
    if(msg.sender != timelock) revert NotTimelock();
    _;
    }

    // ============ 工具函数：有效份额计算（PRD公式） ============
    function getEffectiveShares(uint256 userShares,uint256 slashFactorVal) internal pure returns(uint256) {
        return Math.mulDiv(userShares, slashFactorVal, SCALE);
    }

    // 全局有效总份额，用于奖励指数计算
    function getGlobalEffectiveShares() internal view returns(uint256) {
        return Math.mulDiv(totalSupply(), slashFactor, SCALE);
    }

    // ============ 质押铸造份额公式 PRD：userShares = amount * SCALE / slashFactor ============
    function _calcMintShares(uint256 amount) internal view returns(uint256) {
        return Math.mulDiv(amount, SCALE, slashFactor);
    }

    //视图函数：查询用户待领取奖励，供前端/测试
    function claimable(address user) external view returns(uint256) {
        return _calcUserPendingReward(user);
    }

    //PRD核心：分段快照计算用户待奖励，遍历slashCheckpoint分段计算
    function _calcUserPendingReward(address user) internal view returns(uint256 totalPending) {
        UserInfo storage u = userInfo[user];
        uint256 userLastIndex = u.userRewardIndex;
        if(userLastIndex == rewardIndex) return 0;

        uint256 prevIndex = userLastIndex;
        uint256 prevSlash = SCALE;
        uint256 checkpointCount = slashCheckpoints.length;//第几个点位

        // 遍历所有slash快照，分段计算奖励
        for(uint256 i=0; i<checkpointCount; i++){
            SlashCheckpoint memory cp = slashCheckpoints[i];
            uint256 cpIndex = cp.snapshotRewardIndex;
            if(cpIndex <= prevIndex) {
                prevSlash = cp.oldSlashFactor;
                continue;
            }
            if(cpIndex > rewardIndex) break;

            uint256 userEffective = getEffectiveShares(u.userShares, prevSlash);
            uint256 deltaIndex = cpIndex - prevIndex;
            totalPending += Math.mulDiv(userEffective, deltaIndex, SCALE);

            prevIndex = cpIndex;
            prevSlash = cp.newSlashFactor;
        }
        // 最后一段：最后一个快照到当前全局rewardIndex
        if(prevIndex < rewardIndex) {
            uint256 userEffective = getEffectiveShares(u.userShares, prevSlash);
            uint256 deltaIndex = rewardIndex - prevIndex;
            totalPending += Math.mulDiv(userEffective, deltaIndex, SCALE);
        }
    }


    /// @notice 质押WETH，铸造原始份额，PRD规范
/// @param recipient 份额接收地址
/// @param amount 质押WETH数量（wei）
function deposit(address recipient, uint256 amount)
    external
    nonReentrant
    whenNotPausedContract
    returns (uint256 sharesMinted)
{
    if (recipient == address(0)) revert InvalidAddress();
    if (amount == 0) revert ZeroAmount();
    if (amount < depositMin) revert DepositLessThanMin();
    if (amount > depositPerUserMax) revert ExceedUserDepositLimit();
    if (totalAssets + amount > depositPoolMax) revert ExceedPoolDepositLimit();

    // ========= 懒结算：先结算该用户历史奖励 =========
    _settleUserReward(recipient);

    // PRD核心铸造公式：原始份额 = amount * SCALE / slashFactor
    sharesMinted = Math.mulDiv(amount, SCALE, slashFactor);
    if (sharesMinted == 0) revert InvalidAmount();

    // 从用户钱包转移WETH到合约
    weth.safeTransferFrom(msg.sender, address(this), amount);

    // 更新全局本金账面
    totalAssets += amount;

    // 更新用户原始份额记账
    UserInfo storage user = userInfo[recipient];
    user.userShares += sharesMinted;

    // ========= PRD：空池，首次质押，迁移bufferReward =========
    if (totalSupply() == 0) {
        if (bufferReward > 0) {
            uint256 migrateAmt = bufferReward;
            bufferReward = 0;
            //空池迁移bufferReward，计算奖励指数增量并入全局rewardIndex
            uint256 globalEffectiveShares = getGlobalEffectiveShares();
            if(globalEffectiveShares > 0) {
                uint256 deltaRewardIndex = Math.mulDiv(migrateAmt, SCALE, globalEffectiveShares);
                rewardIndex += deltaRewardIndex;
            }
            emit BufferRewardMigrated(migrateAmt);
        }
    }

    // 可选：如果你的质押份额用ERC20记录，执行铸造
    _mint(recipient, sharesMinted);

    emit Staked(msg.sender, amount, sharesMinted);
}

    /// @dev 内部：结算用户截至当前的奖励，更新用户奖励点位
function _settleUserReward(address user) internal {
    UserInfo storage u = userInfo[user];
    uint256 lastIndex = u.userRewardIndex;
    if(lastIndex == rewardIndex) return; // 已经结算完毕

    // 此处：分段计算该用户可领取奖励（结合slash快照）
    uint256 pendingReward = _calcUserPendingReward(user);
    if(pendingReward > 0){
    if(bufferReward < pendingReward) revert InsufficientBalance();
    bufferReward -= pendingReward;
    }
    u.userRewardIndex = rewardIndex;
}

    /// @notice 解质押，销毁原始份额，取回本金+领取奖励
/// @param sharesToBurn 想要销毁【原始份额】数量（PRD：操作单位是原始份额，不是WETH数量）
/// @param recipient 接收WETH(本金+奖励)的接收地址
function unstake(uint256 sharesToBurn, address recipient)
    external
    nonReentrant
    whenNotPausedContract
    returns (uint256 principalWeth, uint256 rewardWeth)
{
    if (sharesToBurn == 0) revert ZeroAmount();
    if (recipient == address(0)) revert InvalidAddress();

    UserInfo storage user = userInfo[msg.sender];
    // 校验：用户原始份额足够销毁
    if(user.userShares < sharesToBurn) revert InsufficientShares();

    // ========= PRD强制：先懒结算，计算用户截止当前全部待领奖励 =========
    rewardWeth = _calcUserPendingReward(msg.sender);
    _settleUserReward(msg.sender);

    // 本金换算：根据销毁的原始份额，计算对应的本金WETH
    // 本金 = sharesToBurn * amount / sharesMinted 的对应本金，这里是本金提取
    principalWeth = Math.mulDiv(sharesToBurn, SCALE, slashFactor);

    // 更新全局本金账面：totalAssets只扣本金（PRD：totalAssets仅质押本金）
    totalAssets -= principalWeth;

    // 更新用户记账：原始份额减少
    user.userShares -= sharesToBurn;

    // ERC20份额销毁
    _burn(msg.sender, sharesToBurn);

    // 合约转账：本金+奖励一次性转给recipient
    uint256 totalPayout = principalWeth + rewardWeth;
    weth.safeTransfer(recipient, totalPayout);

    emit Unstaked(msg.sender, sharesToBurn, principalWeth, rewardWeth);
}

    
/// @notice 单独领取奖励，质押份额保留不动，本金继续质押生息
/// @param recipient 奖励WETH的接收地址（可以是自己或第三方）
function claimReward(address recipient)
    external
    nonReentrant
    whenNotPausedContract
    returns (uint256 rewardWeth)
{
    if (recipient == address(0)) revert InvalidAddress();

    
    // 第一步：先计算当前待领取奖励（结算前快照）
    rewardWeth = _calcUserPendingReward(msg.sender);

    if(rewardWeth == 0) revert ZeroAmount();

    // PRD：懒结算，更新用户奖励点位，标记这笔奖励已经领取，防止重复领取
    _settleUserReward(msg.sender);

    // 校验合约WETH余额充足
    if(weth.balanceOf(address(this)) < rewardWeth) revert InsufficientBalance();

    // 转账奖励给接收人
    weth.safeTransfer(recipient, rewardWeth);

    emit RewardClaimed(msg.sender, recipient, rewardWeth);
}

// depositReward：注入奖励到质押池，自动计算并扣协议手续费
function depositReward(
    address recipient,
    uint256 rewardWeth
) 
    external 
    nonReentrant 
    whenNotPausedContract 
    onlyTimelock
    returns (uint256 fee)
{
    if (recipient == address(0)) revert InvalidAddress();
    if (rewardWeth == 0) revert ZeroAmount();
    if(rewardWeth > ADMIN_SINGLE_MAX_AMOUNT) revert AdminSingleAmountExceedLimit();
    // 费率计算，SCALE=1e36，使用mulDiv防溢出
    fee = Math.mulDiv(rewardWeth, rewardFeeRate, SCALE);
    uint256 netRewardToPool = rewardWeth - fee;
    

    // 资金转入合约
    bufferReward += netRewardToPool;
    uint256 globalEffectiveShares = getGlobalEffectiveShares();
    if(globalEffectiveShares > 0) {
        uint256 deltaRewardIndex = Math.mulDiv(netRewardToPool, SCALE, globalEffectiveShares);
        rewardIndex += deltaRewardIndex;
    }
    weth.safeTransferFrom(msg.sender, address(this), rewardWeth);
    if(fee > 0) {
        weth.safeTransfer(feeRecipient, fee);
    }
    emit RewardDeposited(msg.sender, rewardWeth, fee, netRewardToPool);
}

// slash 罚没函数：仅Timelock可调用，全局池子资产亏损
function slash(uint256 totalAssetsBeforeSlash, uint256 lossAmount)
    external
    onlyTimelock
    nonReentrant
    whenNotPausedContract
    returns (uint256 newSlashFactor, uint256 newTotalAssets)
{
    // 基础入参校验
    if (lossAmount == 0) revert ZeroAmount();
    if (lossAmount > totalAssetsBeforeSlash) revert SlashLossExceedTotalAssets();
    if(lossAmount > ADMIN_SINGLE_MAX_AMOUNT) revert AdminSingleAmountExceedLimit();

    //PRD强制顺序：先快照当前rewardIndex固化奖励，再计算罚没
    uint256 currentRewardIndex = rewardIndex;
    uint256 oldSlashFactor = slashFactor;

    // 计算罚没比例，mulDiv防精度丢失
    uint256 slashRatio = Math.mulDiv(lossAmount, SCALE, totalAssetsBeforeSlash);
    if(slashRatio > slashMaxRatio) revert SlashLossExceedMaxRatio();
    
    // 公式：按资产比例更新slashFactor（和你PRD公式保持一致）
    // newSlashFactor = oldSlashFactor * (totalAssetsBeforeSlash - lossAmount) / totalAssetsBeforeSlash
    newSlashFactor = Math.mulDiv(
        oldSlashFactor,
        totalAssetsBeforeSlash - lossAmount,
        totalAssetsBeforeSlash
    );

    // 更新全局资产
    newTotalAssets = totalAssetsBeforeSlash - lossAmount;
    totalAssets = newTotalAssets;
    slashFactor = newSlashFactor;

        // 写入检查点
        uint256 checkpointId = slashCheckpoints.length;
        slashCheckpoints.push(SlashCheckpoint({
            snapshotRewardIndex: currentRewardIndex,
            timestamp: block.timestamp,
            oldSlashFactor: oldSlashFactor,
            newSlashFactor: newSlashFactor,
            lossAmount: lossAmount,
            totalAssetsAfterSlash: newTotalAssets
        }));

        emit SlashExecuted(checkpointId, oldSlashFactor, newSlashFactor, lossAmount, newTotalAssets);
    }

    // 设置手续费收款地址，仅Timelock调用
function setFeeRecipient(address _newFeeRecipient)
    external
    onlyTimelock
    whenNotPausedContract
{
    if (_newFeeRecipient == address(0)) revert InvalidAddress();

    // 保存旧值用于事件
    address oldRecipient = feeRecipient;
    feeRecipient = _newFeeRecipient;

    emit FeeRecipientSet(oldRecipient, _newFeeRecipient);

}

function setDepositLimit(
    uint256 _depositMin,
    uint256 _depositPerUserMax,
    uint256 _depositPoolMax
)
    external
    onlyTimelock
    whenNotPausedContract
{
    // 非0校验
    if (_depositMin == 0) revert InvalidLimit();
    if (_depositPerUserMax == 0) revert InvalidLimit();
    if (_depositPoolMax == 0) revert InvalidLimit();

    // 大小关系校验
    if (_depositMin > _depositPerUserMax) revert ExceedUserDepositLimit();
    if (_depositPerUserMax > _depositPoolMax) revert ExceedPoolDepositLimit();

    // 快照旧值
    uint256 oldMin = depositMin;
    uint256 oldPerUserMax = depositPerUserMax;
    uint256 oldPoolMax = depositPoolMax;

    // 更新全局状态变量（核心！保存配置上链）
    depositMin = _depositMin;
    depositPerUserMax = _depositPerUserMax;
    depositPoolMax = _depositPoolMax;

    // 事件：旧值+新值全部记录
    emit DepositLimitUpdated(oldMin, oldPerUserMax, oldPoolMax, _depositMin, _depositPerUserMax, _depositPoolMax);
}

function setRewardFeeRate(uint256 _rewardFeeRate)
    external
    onlyTimelock
    whenNotPausedContract
{
    // 费率上限：不可超过100%
    if (_rewardFeeRate > SCALE) revert InvalidLimit();

    // 快照旧费率（必须在修改storage之前读取！）
    uint256 oldRate = rewardFeeRate;

    // 更新全局状态
    rewardFeeRate = _rewardFeeRate;

    // 事件：旧值在前，新值在后
    emit RewardFeeRateUpdated(oldRate, _rewardFeeRate);
    }

    // 重写transferOwnership，增加onlyTimelock，PRD要求时间锁保护
        function transferOwnership(address newOwner) public override onlyTimelock {
            super.transferOwnership(newOwner);
    }

    // 暂停合约
    function pause()
        external
        onlyTimelock
    {
        if(paused()) revert AlreadyPaused();
        _pause(); 
        emit Paused(true);
    }
    // 解除暂停
    function unpause()
        external
        onlyTimelock
    {
        if(!paused()) revert AlreadyUnpaused();
        _unpause(); 
        emit Paused(false);
    }

    
    function createHighRiskProposal(
        string calldata proposalName,
        bytes calldata callData
    ) external onlyTimelock returns(uint256 newPropId) {
        uint256 currentBlock = block.number;
        uint256 windowSize = 86400;
        uint256 windowStart = currentBlock > windowSize ? currentBlock - windowSize : 0;
        uint256 count;
        for(uint256 i=0; i < highRiskProposals.length; i++){
            uint256 b = highRiskProposals[i].createBlock;
            if(b > windowStart){
                count ++;
        }
    }
        if(count >= 3) {
            revert HighRiskProposalRateLimitExceeded();
    }
        highRiskProposals.push(HighRiskProposal({
            callData: callData,
            createBlock: block.number,
            executed: false
    }));
        newPropId = highRiskProposals.length - 1;
}



/**
 * @dev 执行高危提案，按提案ID执行，区块等待期7天
 * @param proposalId highRiskProposals数组下标
 */
function executeHighRiskProposal(uint256 proposalId)
    external
    onlyTimelock
    nonReentrant
    returns (bytes memory returnData)
{
    if (proposalId >= highRiskProposals.length) revert ProposalNotExist();
    HighRiskProposal storage prop = highRiskProposals[proposalId];
    if (prop.executed) revert ProposalAlreadyExecuted();

    // 7天等待区块：按12s一个区块
    uint256 waitBlocks = (7 * 86400) / 12;
    if (block.number < prop.createBlock + waitBlocks) revert ProposalNotReady();

    // 执行存储的calldata
    (bool success, bytes memory ret) = address(this).call(prop.callData);
    require(success, "HighRiskProposal execute failed");

    prop.executed = true;
    returnData = ret;
}

function getSlashCheckpoint(uint256 checkpointId) external view returns (SlashCheckpoint memory) {
    return slashCheckpoints[checkpointId];
}

function getSlashCheckpointCount() external view returns(uint256) {
    return slashCheckpoints.length;
}

function getBufferReward() external view returns(uint256) {
    return bufferReward;
}

function getUserRewardIndexSnapshot(address user) external view returns (uint256) {
    return userInfo[user].userRewardIndex;
}

function getHighRiskProposalLength() external view returns(uint256) {
    return highRiskProposals.length;
}
}

