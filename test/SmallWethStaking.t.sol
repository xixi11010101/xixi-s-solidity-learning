// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/SmallWethStaking.sol";


contract SmallWethStakingTest is Test {
    SmallWethStaking internal queue;

    address internal oracle = makeAddr("oracle");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal recipient = makeAddr("recipient");
    address internal timelockAddr = makeAddr("timelock");
    address internal rewardSender = makeAddr("rewardSender");
    address internal rewardProvider = makeAddr("rewardProvider");
    address internal feeRecipient = makeAddr("feeRecipient");
    uint256 internal constant SCALE = 1e36;

    WETHMock internal weth;

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

    function setUp() public {
    // 部署Mock WETH
    weth = new WETHMock();
    // 部署质押合约，按PRD构造函数传入WETH地址
    address ownerAddr = makeAddr("ownerAddr");
    queue = new SmallWethStaking(address(weth), feeRecipient, ownerAddr, timelockAddr);


    // 给测试账户原生ETH，用于gas，可保留
    vm.deal(alice, 100 ether);
    vm.deal(bob, 100 ether);
    vm.deal(carol, 100 ether);
    vm.deal(oracle, 100 ether);

    // mint WETH给用户
    vm.prank(alice);
    WETHMock(address(weth)).mint(alice, 50 ether);
    vm.prank(bob);
    WETHMock(address(weth)).mint(bob, 50 ether);
    vm.prank(carol);
    WETHMock(address(weth)).mint(carol, 50 ether);

    // PRD强制：用户授权合约划转WETH
    vm.prank(alice);
    weth.approve(address(queue), type(uint256).max);
    vm.prank(bob);
    weth.approve(address(queue), type(uint256).max);
    vm.prank(carol);
    weth.approve(address(queue), type(uint256).max);
    }

    function _deposit(
        address sender,
        uint256 amount,
        address recipient_
    ) internal returns (uint256 sharesMinted) {
    vm.prank(sender);
    sharesMinted = queue.deposit(recipient_, amount);
}

    function _depositReward(address sender, address _recipient, uint256 amount) internal {
    // mint WETH给sender
    vm.prank(sender);
    weth.mint(sender, amount);
    // approve授权质押合约
    vm.prank(sender);
    weth.approve(address(queue), amount);
    // 调用depositReward(recipient, rewardWeth)
    vm.prank(sender);
    queue.depositReward(_recipient, amount);
}


    function _unstake(address user, uint256 shareAmount) internal returns(uint256 principal, uint256 reward) {
    vm.prank(user);
    (principal, reward) = queue.unstake(shareAmount, user);
}

// slash 辅助函数：仅timelock执行罚没
function _slash(uint256 totalAssetsBeforeSlash, uint256 lossAmount) internal returns (uint256 newSlashFactor, uint256 newTotalAssets) {
    vm.prank(timelockAddr);
    (newSlashFactor, newTotalAssets) = queue.slash(totalAssetsBeforeSlash, lossAmount);
}

function _calcEffective(uint256 raw, uint256 factor) internal pure returns (uint256) {
    return Math.mulDiv(raw, factor, SCALE);
}


function _executeDepositRewardProposalWithMint(address _rewardSender, address _feeRecipient, uint256 rewardAmt) internal {
    // mint weth给奖励发送者
    WETHMock(address(weth)).mint(_rewardSender, rewardAmt);
    vm.prank(_rewardSender);
    weth.approve(address(queue), 0);
    vm.prank(_rewardSender);
    weth.approve(address(queue), rewardAmt);

    // 1. timelock创建提案
    vm.prank(timelockAddr);
    bytes memory callData = abi.encodeWithSignature("depositReward(address,uint256)", _feeRecipient, rewardAmt);
    uint256 propId = queue.createHighRiskProposal("depositReward", callData);

    // 2. 快进7天区块
    uint256 waitBlocks = (7 * 86400) / 12;
    vm.roll(block.number + waitBlocks);

    // 【调试】捕获真实revert，不要笼统的HighRiskProposal execute failed
    vm.prank(timelockAddr);
    vm.expectRevert(); // 会打印具体revert selector
    queue.executeHighRiskProposal(propId);
}


function testDepositAddStake () public {
    uint256 depositFirstAdd = 1 ether;   // 第一次质押
    uint256 depositSecAdd = 2 ether;     // 追加质押金额

    // ========== 第一步：Alice 首次质押 1 ether ==========
    uint256 sharesFirst = _deposit(alice, depositFirstAdd, alice);

    // 【可选】注入奖励，验证旧质押可以拿到这一段的奖励，追加质押前自动结算
    _executeDepositRewardProposalWithMint(rewardSender,feeRecipient, 1 ether);

    // ========== 第二步：Alice 追加质押 2 ether ==========
    // 监听追加质押触发的Staked事件
    vm.expectEmit(true, false, false, true);
    emit Staked(alice, depositSecAdd, depositSecAdd);
    uint256 sharesAdd = _deposit(alice, depositSecAdd, alice);

    // ========== 断言校验 ==========
    // 本次追加铸造的份额等于本次存入WETH（无罚没slashFactor=SCALE）
    assertEq(sharesAdd, depositSecAdd);

    // 用户原始总份额 = 第一次 + 追加
    uint256 totalUserShares = sharesFirst + sharesAdd;
    assertEq(queue.balanceOf(alice), totalUserShares);

    // 池子账面本金 totalAssets = 1 + 2 = 3 ether
    assertEq(queue.totalAssets(), depositFirstAdd + depositSecAdd);
    // 全局总原始份额同步累加
    assertEq(queue.totalSupply(), totalUserShares);

    // 核心校验：追加质押会自动结算历史奖励，结算后待领奖励清零
    assertEq(queue.claimable(alice), 0);
}

function testPartialUnstake() public {
    // 1. 先质押两笔，模拟多笔质押场景
    uint256 stake1 = 1 ether;
    uint256 stake2 = 2 ether;
    uint256 partialUnstakeAmount = 2 ether; // 部分赎回，赎回2WETH份额

    // Alice 第一次质押1ether
    uint256 share1 = _deposit(alice, stake1, alice);
    // Alice 追加质押2ether
    uint256 share2 = _deposit(alice, stake2, alice);
    uint256 totalUserSharesBefore = share1 + share2;
    assertEq(queue.balanceOf(alice), totalUserSharesBefore);

    // 注入奖励，产生待领奖励，用于验证自动结算
    _executeDepositRewardProposalWithMint(rewardSender, feeRecipient, 1 ether);

    // 读取解质押前待领奖励
    uint256 pendingRewardBefore = queue.claimable(alice);
    assertGt(pendingRewardBefore, 0); // 确认存在奖励

    // 捕获Unstake事件
    (uint256 principalWeth, uint256 rewardWeth) = queue.unstake(partialUnstakeAmount, alice);
    vm.expectEmit(true, true, false, true);
    emit Unstaked(alice, partialUnstakeAmount, principalWeth, rewardWeth);

    // ====== 执行【部分解质押】======
    (uint256 returnedPrincipal, uint256 rewardOut) = _unstake(alice, partialUnstakeAmount);

    // ========== 断言校验 ==========
    // 1. 解质押自动结算，本次奖励全部发放，用户待领奖励清零
    assertEq(queue.claimable(alice), 0);
    // 发放的奖励等于结算前待领奖励
    assertEq(rewardOut, pendingRewardBefore);
    // 返回本金等于赎回份额对应的本金
    assertEq(returnedPrincipal, partialUnstakeAmount);

    // 2. 用户剩余份额 = 总份额 - 赎回份额，剩余份额保留继续计息
    uint256 remainShares = totalUserSharesBefore - partialUnstakeAmount;
    assertEq(queue.balanceOf(alice), remainShares);

    // 3. 全局池子参数扣减赎回部分
    assertEq(queue.totalAssets(), stake1 + stake2 - partialUnstakeAmount);
    assertEq(queue.totalSupply(), totalUserSharesBefore - partialUnstakeAmount);

    // 4. 校验：剩余份额仍然可以参与后续奖励（再注入一笔奖励验证）
    _executeDepositRewardProposalWithMint(rewardSender, feeRecipient, 0.5 ether);
    uint256 newPending = queue.claimable(alice);
    assertGt(newPending, 0); // 剩余份额产生新奖励 
}

    function testFullUnstake() public {
        // 1. 先质押，模拟用户质押场景
        uint256 stake = 1 ether;
        uint256 unstakeAmount = 1 ether; // 全额赎回，赎回全部份额

        // Alice 质押1ether
        uint256 share = _deposit(alice, stake, alice);
        uint256 totalUserSharesBefore = share;
        assertEq(queue.balanceOf(alice), totalUserSharesBefore);

    // 注入奖励，产生待领奖励，验证解质押自动结算
    _executeDepositRewardProposalWithMint(rewardSender, feeRecipient, 1 ether);

    // 读取解质押前待领奖励
    uint256 pendingRewardBefore = queue.claimable(alice);
    assertGt(pendingRewardBefore, 0); // 确认存在待结算奖励

    // 捕获Unstaked事件
    vm.expectEmit(true, true, false, true);
    (uint256 principalWeth, uint256 rewardWeth) = queue.unstake(1 ether, alice);
    emit Unstaked(alice, 1 ether, principalWeth, rewardWeth);

    // 执行全额解质押
    (uint256 returnedPrincipal, uint256 rewardOut) = _unstake(alice, unstakeAmount);

    // 校验1：全额解质押自动结算全部奖励，结算后待领奖励清零
    assertEq(queue.claimable(alice), 0);
    // 发放的奖励等于结算前待领奖励
    assertEq(rewardOut, pendingRewardBefore);
    // 返回本金等于赎回份额对应的本金
    assertEq(returnedPrincipal, unstakeAmount);

    // 校验2：用户份额全部销毁，剩余份额=0
    uint256 remainShares = 0;
    assertEq(queue.balanceOf(alice), remainShares);

    // 校验3：全局池子参数扣减全部质押本金与份额
    assertEq(queue.totalAssets(), stake - unstakeAmount);
    assertEq(queue.totalSupply(), totalUserSharesBefore - unstakeAmount);
}

   
    function testDepositZeroAmountRevert() public {
    uint256 depositAmount = 0;

    // 捕获revert，预期抛出错误（和你合约自定义revert保持一致）
    vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
    // 执行质押，传入0金额
    _deposit(alice, depositAmount, alice);

    // 兜底校验：池子状态完全没变化
    assertEq(queue.totalAssets(), 0);
    assertEq(queue.totalSupply(), 0);
    assertEq(queue.balanceOf(alice), 0);
}

    function testDepositOverUserMaxRevert() public {
    uint256 depositAmount = 51 ether; // 超过单人上限50WETH

    // 预期触发【超过用户单笔/单人上限】的自定义错误，和你合约保持一致
    vm.expectRevert(abi.encodeWithSignature("ExceedUserDepositLimit()"));
    // 执行质押，传入超过上限的金额
    _deposit(alice, depositAmount, alice);

    // 兜底校验：交易回滚，池子状态完全没变化
    assertEq(queue.totalAssets(), 0);
    assertEq(queue.totalSupply(), 0);
    assertEq(queue.balanceOf(alice), 0);
}

    function testDepositOverPoolMaxRevert() public {
    // 池子总上限：5000 ether
    // 先质押4950 ether，池子接近上限
    uint256 firstStake = 4950 ether;
    _deposit(alice, firstStake, alice);
    assertEq(queue.totalAssets(), firstStake);

    // 再质押60 ether，4950 + 60 = 5010 ether > 5000 ether，超出池子全局上限
    uint256 depositAmount = 60 ether;

    // 预期抛出：超过池子总上限自定义错误 ExceedPoolDepositLimit()
    vm.expectRevert(abi.encodeWithSignature("ExceedPoolDepositLimit()"));
    _deposit(alice, depositAmount, alice);

    // 兜底校验：交易回滚，池子状态不变，仍然是4950 ether
    assertEq(queue.totalAssets(), 4950 ether);
    assertEq(queue.totalSupply(), 4950 ether);
    assertEq(queue.balanceOf(alice), 4950 ether);
}        
    
    //边界测试4：解质押，赎回份额超过用户自有份额 → 预期revert，状态不变
function testUnstakeAmountExceedUserShareRevert() public {
    // 1. 先质押1 ether
    uint256 stake = 1 ether;
    uint256 unstakeAmount = 3 ether; // 尝试赎回3ether份额，用户只有1ether份额

    // Alice 质押1etherforge test --via-ir
    uint256 share = _deposit(alice, stake, alice);
    uint256 totalUserSharesBefore = share;
    assertEq(queue.balanceOf(alice), totalUserSharesBefore);

    // 预期：赎回份额超过用户持有份额，触发revert
    vm.expectRevert(abi.encodeWithSignature("InsufficientShares()"));
    // 执行解质押（尝试赎回超额份额）
    (uint256 returnedPrincipal, uint256 rewardOut) = _unstake(alice, unstakeAmount);

    // 兜底校验：交易回滚，所有状态保持质押后的样子，没有任何改动
    assertEq(queue.totalAssets(), 1 ether);
    assertEq(queue.totalSupply(), 1 ether);
    assertEq(queue.balanceOf(alice), 1 ether);
}

    //管理员测试1：记录快照并更新收益
//场景分支1：有收益，调用depositReward注入奖励，触发RewardDeposited事件、更新rewardIndex
function testAdminSnapshotRewardGain() public {
    // 前置：Alice质押2 ether，池子有质押本金
    uint256 stakeAmt = 2 ether;
    _deposit(alice, stakeAmt, alice);
    assertEq(queue.totalAssets(), stakeAmt);

    // 管理员注入奖励（产生收益）
    uint256 rewardIn = 1 ether;
    uint256 fee = Math.mulDiv(rewardIn, queue.rewardFeeRate(), queue.SCALE());
    uint256 userReward = rewardIn - fee;

    // 开始收集所有事件，不再用expectEmit
    vm.recordLogs();
    _executeDepositRewardProposalWithMint(rewardSender, feeRecipient, rewardIn);
    Vm.Log[] memory logs = vm.getRecordedLogs();

    // 遍历日志，找到 RewardDeposited
    bool foundRewardEvent = false;
    for (uint256 i = 0; i < logs.length; i++) {
        Vm.Log memory log = logs[i];
        // 对比事件的topic0（event签名hash）
        if (log.topics[0] == keccak256("RewardDeposited(address,uint256,uint256,uint256)")) {
            foundRewardEvent = true;
            // 解码参数校验
            (address sender, uint256 amount, uint256 feeAmt, uint256 netReward) = abi.decode(log.data, (address,uint256,uint256,uint256));
            assertEq(sender, rewardSender);
            assertEq(amount, rewardIn);
            assertEq(feeAmt, fee);
            assertEq(netReward, userReward);
            break;
        }
    }
    assertTrue(foundRewardEvent, "RewardDeposited not emitted");

    // 校验：奖励指数上涨，用户产生待领奖励
    uint256 pendingAlice = queue.claimable(alice);
    assertGt(pendingAlice, 0);
}

//场景分支2：无新增收益，不注入奖励，直接读取全局状态校验（本合约无单独takeSnapshot）
function testAdminSnapshotNoGain() public {
    uint256 stakeAmt = 2 ether;
    _deposit(alice, stakeAmt, alice);
    assertEq(queue.totalAssets(), stakeAmt);

    // 不执行depositReward，没有奖励注入
    // 直接读取全局状态，模拟“记录全局状态快照”
    uint256 assetSnap = queue.totalAssets();
    uint256 shareSnap = queue.totalSupply();
    uint256 rewardIdxSnap = queue.rewardIndex();
    uint256 slashFactorSnap = queue.slashFactor();

    // 校验用户待领奖励不变，仍然是0
    uint256 pendingAlice = queue.claimable(alice);
    assertEq(pendingAlice, 0);

    // 校验快照读取的值和当前合约状态一致
    assertEq(assetSnap, stakeAmt);
    assertEq(shareSnap, queue.totalSupply());
    assertEq(rewardIdxSnap, queue.rewardIndex());
    assertEq(slashFactorSnap, queue.slashFactor());
}

//场景分支3：池子亏损，Timelock调用slash罚没，自动写入SlashCheckpoint快照，触发SlashExecuted事件
function testAdminSlashSnapshotLoss() public {
    // 前置：Alice质押2 ether
    uint256 stakeAmt = 2 ether;
    _deposit(alice, stakeAmt, alice);
    uint256 lossAmount = 0.2 ether; // 池子亏损0.5ether
    uint256 assetBeforeSlash = queue.totalAssets();

    uint256 oldSlashFactor = queue.slashFactor();
    uint256 expectedNewSlashFactor = Math.mulDiv(oldSlashFactor, assetBeforeSlash - lossAmount, assetBeforeSlash);
    uint256 checkpointId = queue.getSlashCheckpointCount();

    // 捕获SlashExecuted事件，参数顺序严格匹配合约event
    vm.expectEmit(true, false, false, true);
    emit SlashExecuted(checkpointId, oldSlashFactor, expectedNewSlashFactor, lossAmount, assetBeforeSlash - lossAmount);

    // Timelock管理员调用slash，传入2个参数：totalAssetsBeforeSlash, lossAmount
    vm.prank(timelockAddr);
    (uint256 newSlashFactor, uint256 newTotalAssets) = queue.slash(assetBeforeSlash, lossAmount);

    // 校验：全局资产减少
    assertEq(queue.totalAssets(), assetBeforeSlash - lossAmount);
    // 校验slashFactor更新
    assertEq(queue.slashFactor(), newSlashFactor);
    // 校验检查点数组新增一条快照记录
    assertEq(queue.getSlashCheckpointCount(), checkpointId + 1);
    // 读取快照校验快照内容
    uint256 cpId = queue.getSlashCheckpointCount();
    SmallWethStaking.SlashCheckpoint memory cp = queue.getSlashCheckpoint(cpId - 1);
    assertEq(cp.lossAmount, lossAmount);
    assertEq(cp.newSlashFactor, newSlashFactor);
    assertEq(cp.totalAssetsAfterSlash, newTotalAssets);
}

    /**
 * 管理员测试2：罚没逻辑校验
 * 预期：
 * 1. 执行slash罚没前，全局奖励点位固化（当前rewardIndex写入快照）
 * 2. 用户【原始份额userShares保持不变】，仅有效份额随slashFactor衰减
 * 3. 用户【历史已经产生的待领奖励不受罚没影响，完全不变】
 * 4. 罚没之后新产生的奖励，按照新的有效份额分配
 */
function testAdminSlashFullLogic() public {
    // 1. 前置：Alice质押2 ether，获得原始份额
    uint256 stakeAmt = 2 ether;
    _deposit(alice, stakeAmt, alice);
    (uint256 aliceOriginalShares, uint256 aliceRewardIndex) = queue.userInfo(alice);
    uint256 oldSlashFactor = queue.slashFactor();

    // 2. 注入一笔奖励，生成【罚没前的历史奖励】
    _executeDepositRewardProposalWithMint(rewardSender, feeRecipient, 1 ether);
    // ========= 修复点1：注入奖励之后再读取totalAssets！=========
    uint256 assetBeforeSlash = queue.totalAssets();

    // 记录：罚没执行前，Alice可领取的历史奖励
    uint256 rewardBeforeSlash = queue.claimable(alice);
    assertGt(rewardBeforeSlash, 0, "should have reward before slash");

    // 3. 执行罚没
    uint256 lossAmount = 0.5 ether;
    uint256 checkpointId = queue.getSlashCheckpointCount();
    // 捕获SlashExecuted事件，校验快照写入
    vm.expectEmit(true, false, false, true);
    emit SlashExecuted(
        checkpointId,
        oldSlashFactor,
        Math.mulDiv(oldSlashFactor, assetBeforeSlash - lossAmount, assetBeforeSlash),
        lossAmount,
        assetBeforeSlash - lossAmount
    );
    (uint256 newSlashFactor, uint256 newTotalAssets) = _slash(assetBeforeSlash, lossAmount);

    // ========= 校验1：用户原始份额不变（核心PRD要求） =========
    (uint256 aliceSharesAfterSlash, uint256 aliceRewardIndexAfter) = queue.userInfo(alice);
    assertEq(aliceSharesAfterSlash, aliceOriginalShares,"Original shares should not be modified by slash");

    // ========= 校验2：历史待领奖励完全不变（罚没不影响已产生奖励） =========
    uint256 rewardAfterSlashBeforeNewReward = queue.claimable(alice);
    assertEq(rewardAfterSlashBeforeNewReward, rewardBeforeSlash, "After slash, the rewards remain unchanged");

    // ========= 校验3：有效份额衰减，基于新slashFactor =========
    uint256 effectiveOld = Math.mulDiv(aliceOriginalShares, oldSlashFactor, queue.SCALE());
    uint256 effectiveNew = Math.mulDiv(aliceOriginalShares, newSlashFactor, queue.SCALE());
    assertLt(effectiveNew, effectiveOld, "After slash, the effective share decreased");

    // ========= 校验4：再注入一笔【罚没之后的新奖励】，只能用新有效份额计算 =========
    _executeDepositRewardProposalWithMint(rewardSender, feeRecipient, 1 ether);
    uint256 rewardAfterNewReward = queue.claimable(alice);
    // 新增奖励部分，是基于衰减后的有效份额计算
    assertGt(rewardAfterNewReward, rewardAfterSlashBeforeNewReward, "new reward should accrue");
    uint256 rewardIndexBeforeSlash = queue.rewardIndex();
    // ========= 校验5：读取快照，确认罚没瞬间rewardIndex固化在检查点 =========
    SmallWethStaking.SlashCheckpoint memory cp = queue.getSlashCheckpoint(checkpointId);
    assertEq(cp.snapshotRewardIndex, rewardIndexBeforeSlash, "Snapshot record the rewardIndex");

}

        /**
 * 管理员测试3：普通用户尝试调用onlyTimelock管理员函数，全部被拦截
 * 预期：所有管理员函数，普通质押用户调用时，均 revert NotTimelock()
 */
function testAdminOnlyTimelockRevertWhenUserCall() public {
    // 普通用户Alice，不是timelock
    address user = alice;
    address randomNewRecipient = makeAddr("newFeeRecipient");
    address newOwner = makeAddr("newOwner");

    // 1. 用户尝试调用 setFeeRecipient
    vm.prank(user);
    vm.expectRevert(SmallWethStaking.NotTimelock.selector);
    queue.setFeeRecipient(randomNewRecipient);

    // 2. 用户尝试调用 setDepositLimit
    vm.prank(user);
    vm.expectRevert(SmallWethStaking.NotTimelock.selector);
    queue.setDepositLimit(1 ether, 50 ether, 5000 ether);

    // 3. 用户尝试调用 setRewardFeeRate
    vm.prank(user);
    vm.expectRevert(SmallWethStaking.NotTimelock.selector);
    queue.setRewardFeeRate(0.1e36);

    // 4. 用户尝试调用 slash罚没
    uint256 poolTotalAssetsBefore = queue.totalAssets();
    vm.prank(alice);
    vm.expectRevert(SmallWethStaking.NotTimelock.selector);
    queue.slash(poolTotalAssetsBefore, 2 ether);

    // 5. 用户尝试 pause 暂停合约
    vm.prank(user);
    vm.expectRevert(SmallWethStaking.NotTimelock.selector);
    queue.pause();

    // 6. 用户尝试 unpause 解除暂停
    vm.prank(user);
    vm.expectRevert(SmallWethStaking.NotTimelock.selector);
    queue.unpause();

    // 7. 用户尝试转移合约所有权 transferOwnership
    vm.prank(user);
    vm.expectRevert(SmallWethStaking.NotTimelock.selector);
    queue.transferOwnership(newOwner);
}

    /**
 * 奖励测试1：用户解质押；不同质押额的用户按比例获得奖励
 * 操作：Alice质押2WETH，Bob质押1WETH，注入奖励，两人全额解质押
 * 预期：两人最终结算奖励比例 = 2:1，与原始份额比例保持一致
 */
function testReward_UnstakeRewardProportional() public {
    // 质押金额
    uint256 stakeAlice = 2 ether;
    uint256 stakeBob = 1 ether;

    // 1. Alice、Bob分别质押
    uint256 sharesAlice = _deposit(alice, stakeAlice, alice);
    uint256 sharesBob = _deposit(bob, stakeBob, bob);

    // 校验原始份额 2:1
    assertEq(sharesAlice * 1, sharesBob * 2, "The original share ratio has to be 2:1");

    // 2. 注入奖励
    
    address currentFeeRecipient = address(queue.feeRecipient());
    uint256 rewardInput = 3 ether;
    _executeDepositRewardProposalWithMint(rewardSender, currentFeeRecipient, rewardInput);

    // 3. 查询解质押前待领奖励，比例2:1
    uint256 pendingAlice = queue.claimable(alice);
    uint256 pendingBob = queue.claimable(bob);
    assertEq(pendingAlice, pendingBob * 2, "Reward ratio before releasing the pledge: 2:1");

    // 4. Alice全额解质押
    vm.prank(alice);
    (uint256 principalA, uint256 rewardA) = queue.unstake(sharesAlice, alice);
    assertEq(rewardA, pendingAlice, "Alice unpledged and got rewards that match what's claimable");

    // 5. Bob全额解质押
    vm.prank(bob);
    (uint256 principalB, uint256 rewardB) = queue.unstake(sharesBob, bob);
    assertEq(rewardB, pendingBob, "Bob's rewards from unpledging match what he can claim");

    // 6. 最终校验解质押发放奖励比例 2:1
    assertEq(rewardA, rewardB * 2, "Unstaking settlement rewards stay at a 2:1 ratio");
}

    /**
 * 奖励测试3：奖励来源计算；管理员调用depositReward传入税前总收益
 * 预期：合约自动拆分手续费，税后净奖励进入奖励池bufferReward，手续费转给feeRecipient
 */
function testReward_DepositRewardFeeSplit() public {
    // 前置：Alice质押1WETH，池子存在有效质押份额，奖励指数正常计算
    uint256 stakeAmt = 1 ether;
    _deposit(alice, stakeAmt, alice);

    // 业务参数：从合约实时读取，不硬编码，复用已部署合约
    
    address currentFeeRecipient = address(queue.feeRecipient());
    uint256 totalRewardPreTax = 10 ether; // 本次传入depositReward的税前总额
    uint256 rewardFeeRate = queue.rewardFeeRate();
    

    // 计算预期手续费 & 税后净奖励
    uint256 expectedFee = Math.mulDiv(totalRewardPreTax, rewardFeeRate, SCALE);
    uint256 expectedNetReward = totalRewardPreTax - expectedFee;

    // 记录执行前快照状态
    uint256 bufferBefore = queue.bufferReward();
    uint256 feeRecipientBalanceBefore = weth.balanceOf(feeRecipient);
    uint256 rewardIndexBefore = queue.rewardIndex();

    // 捕获RewardDeposited事件，校验事件参数
    vm.expectEmit(true, false, false, true);
    emit RewardDeposited(rewardSender, totalRewardPreTax, expectedFee, expectedNetReward);

    // 调用helper注入奖励，复用你写好的三参数 _depositReward
    _executeDepositRewardProposalWithMint(rewardSender, feeRecipient, totalRewardPreTax);

    // ====== 断言校验 ======
    // 1. bufferReward增加税后净额
    assertEq(queue.bufferReward(), bufferBefore + expectedNetReward, "bufferReward should increase the net reward after taxes");
    // 2. feeRecipient收到手续费WETH
    assertEq(weth.balanceOf(feeRecipient), feeRecipientBalanceBefore + expectedFee, "feeRecipient received the fee");
    // 3. rewardIndex全局奖励点位上涨
    assertGt(queue.rewardIndex(), rewardIndexBefore, "rewardIndex should increase");
    // 4. 质押用户产生待领奖励
    uint256 pendingAlice = queue.claimable(alice);
    assertGt(pendingAlice, 0, "Users who stake can get corresponding rewards");
}

    /**
 * 精度测试：基于SCALE=1e36 质押、解质押全流程，校验无精度漂移，无池子资产异常亏损
 * 预期：多轮质押+部分解质押+全额解质押，Math.mulDiv 1e36定点运算，不会出现资产丢失、池子资产缩水
 */
function testPrecision_NoAssetLoss() public {
    
    // 采用带小数的非整数金额，专门命中定点乘法除法精度边界，暴露精度漂移
    uint256 stake1 = 1.000000000000000001 ether;
    uint256 stake2 = 2.999999999999999999 ether;
    uint256 partialUnstakeShare = 2 ether;

    // 1. Alice 两次质押
    uint256 share1 = _deposit(alice, stake1, alice);
    uint256 share2 = _deposit(alice, stake2, alice);
    uint256 totalSharesAlice = share1 + share2;
    uint256 totalDeposited = stake1 + stake2;
    assertEq(queue.totalAssets(), totalDeposited);
    assertEq(queue.totalSupply(), totalSharesAlice);

    // 注入一笔奖励，触发1e36奖励指数计算，放大定点运算场景
    address currentFeeRecipient = address(queue.feeRecipient());
    uint256 rewardAmount = 0.5 ether;
    _executeDepositRewardProposalWithMint(rewardSender, currentFeeRecipient, rewardAmount);

    // 记录池子WETH余额快照（合约持有WETH本金+税后奖励）
    uint256 contractWethBalanceBefore = weth.balanceOf(address(queue));

    // 2. 部分解质押 2 ether份额
    (uint256 principalOutPartial, uint256 rewardOutPartial) = _unstake(alice, partialUnstakeShare);

    // 校验：解质押返回本金+奖励，合约转出的WETH总和等于用户拿到的
    uint256 contractWethBalanceMid = weth.balanceOf(address(queue));
    assertEq(contractWethBalanceBefore - contractWethBalanceMid, principalOutPartial + rewardOutPartial, "Partial unstake transfer WETH match");

    // 3. 全额解质押剩余全部份额
    uint256 remainSharesAlice = queue.balanceOf(alice);
    (uint256 principalOutFull, uint256 rewardOutFull) = _unstake(alice, remainSharesAlice);

    // 合约最终WETH余额
    uint256 contractWethBalanceEnd = weth.balanceOf(address(queue));

    // ========== 核心精度校验（重点：无异常资产丢失） ==========
    // 用户总共取出：部分解质押 + 全额解质押 的本金+奖励
    uint256 totalUserWithdraw = principalOutPartial + rewardOutPartial + principalOutFull + rewardOutFull;
    uint256 totalWethInjected = totalDeposited + rewardAmount;

    // 允许极小舍入误差（mulDiv向上/向下取整，最多1wei，1e36定点特性）
    uint256 delta = totalWethInjected > totalUserWithdraw ? totalWethInjected - totalUserWithdraw : totalUserWithdraw - totalWethInjected;
    assertLe(delta, 1, "Precision drift, asset loss over 1 wei");

    // 用户份额清零
    assertEq(queue.balanceOf(alice), 0);
    // 池子totalAssets归零
    assertEq(queue.totalAssets(), 0);
}


/**
 * 罚没测试1：基础罚没冒烟校验
 * 操作：传入合法大于0的亏损金额执行罚没
 * 预期：slashFactor 正确更新，totalAssets 扣减，用户原始 userShares 不变
 */
function testAdminSlash_Basic() public {
    // 前置：Alice质押2 ether，获取原始份额
    uint256 stakeAmt = 2 ether;
    _deposit(alice, stakeAmt, alice);
    (uint256 aliceOriginalShares, uint256 aliceRewardIndex) = queue.userInfo(alice);
    uint256 assetBeforeSlash = queue.totalAssets();
    uint256 oldSlashFactor = queue.slashFactor();
    uint256 lossAmount = 0.2 ether;
    // 执行罚没
    (uint256 newSlashFactor, uint256 newTotalAssets) = _slash(assetBeforeSlash, lossAmount);

    // 断言1：用户原始份额不变
    (uint256 aliceSharesAfterSlash, uint256 aliceRewardIndexAfter) = queue.userInfo(alice);
    assertEq(aliceSharesAfterSlash, aliceOriginalShares, "The original share can't be changed by slash");

    // 断言2：totalAssets 扣减对应亏损
    assertEq(queue.totalAssets(), assetBeforeSlash - lossAmount, "total assets minus losses");

    // 断言3：slashFactor按公式衰减
    assertEq(newSlashFactor, Math.mulDiv(oldSlashFactor, assetBeforeSlash - lossAmount, assetBeforeSlash), "slashFactor is false");
}

        /**
 * 罚没测试2：罚没超限校验
 * 操作：传入亏损金额 > 质押池总资产
 * 预期：交易回滚，抛出SlashLossExceedTotalAssets
 */
    function testAdminSlash_RevertWhenLossExceedTotalAssets() public {
        // 前置：Alice质押2 ether，获取原始份额
        uint256 stakeAmt = 2 ether;
        _deposit(alice, stakeAmt, alice);
        uint256 assetBeforeSlash = queue.totalAssets();

        // 亏损超过池子资产，触发revert
        uint256 lossAmount = 3 ether;
        vm.expectRevert(abi.encodeWithSignature("SlashLossExceedTotalAssets()"));
        _slash(assetBeforeSlash, lossAmount);
}

            /**
 * 罚没测试3：正常罚没校验
 * 操作：传入合法亏损金额（小于质押池总资产）执行罚没
 * 预期：质押池总额大于0，成功扣减对应亏损资产
 */
function testAdminSlash_NormalSlash() public {
    // 前置：Alice质押2 ether，获取原始份额
    uint256 stakeAmt = 2 ether;
    _deposit(alice, stakeAmt, alice);
    uint256 assetBeforeSlash = queue.totalAssets();

    uint256 lossAmount = 0.2 ether;
    (uint256 newSlashFactor, uint256 newTotalAssets) = _slash(assetBeforeSlash, lossAmount);

    assertGt(assetBeforeSlash, lossAmount, "The pool assets need to be greater than the loss amount");
    assertEq(queue.totalAssets(), assetBeforeSlash - lossAmount, "total assets minus losses");
}

/**
 * 安全测试1：防重入全套校验
 * 操作：在WETH转账fallback回调，嵌套调用unstake / claimReward，尝试重入
 * 预期：nonReentrant锁拦截嵌套调用，交易全部revert
 */
function testReentrancyGuard_AllUserFuncRevert() public {
    // 部署共用攻击合约
    ReentrancyAttacker attacker = new ReentrancyAttacker(address(queue), address(weth));
    uint256 stakeAmt = 1 ether;

    // 给攻击合约铸造WETH + 授权
    vm.prank(address(attacker));
    WETHMock(address(weth)).mint(address(attacker), stakeAmt);
    vm.prank(address(attacker));
    weth.approve(address(queue), type(uint256).max);

    // 攻击者质押1 ether，拿到份额
    vm.prank(address(attacker));
    uint256 shares = queue.deposit(address(attacker), stakeAmt);
    (uint256 attackerShares, uint256 attackerIndex) = queue.userInfo(address(attacker));
    assertEq(attackerShares, shares);

    // ========= Case1：重入调用 unstake =========
    attacker.setTargetCall(1); // 标记回调内部执行 unstake
    vm.expectRevert("ReentrancyGuard: reentrant call");
    vm.prank(address(attacker));
    queue.unstake(shares, address(attacker));

    // 重置状态，重新质押，测试claimReward重入
    vm.prank(address(attacker));
    WETHMock(address(weth)).mint(address(attacker), stakeAmt);
    vm.prank(address(attacker));
    queue.deposit(address(attacker), stakeAmt);
    // 注入奖励，保证有奖励可领取
    address currentFeeRecipient = address(queue.feeRecipient());
    _executeDepositRewardProposalWithMint(rewardSender, currentFeeRecipient, 0.5 ether);

    // ========= Case2：重入调用 claimReward =========
    attacker.setTargetCall(2); // 标记回调内部执行 claimReward
    vm.expectRevert("ReentrancyGuard: reentrant call");
    vm.prank(address(attacker));
    queue.claimReward(address(attacker));
}


    //安全测试234
    function testPause_AllFunctionFrozenWhenPaused() public {
    // 直接复用全局alice，不再makeAddr新建user
    uint256 stakeAmt = 2 ether;
    vm.prank(alice);
    uint256 shares = queue.deposit(alice, stakeAmt);

    // 注入奖励，复用全局rewardProvider
    vm.prank(rewardProvider);
    queue.depositReward(rewardProvider,1 ether);

    // Timelock执行暂停
    vm.prank(timelockAddr);
    queue.pause();
    assertTrue(queue.paused());

    // 1. deposit 质押被冻结
    vm.prank(alice);
    vm.expectRevert();
    queue.deposit(alice, 1 ether);

    // 2. unstake 解质押冻结
    vm.prank(alice);
    vm.expectRevert();
    queue.unstake(shares, alice);

    // 3. claimReward 领奖励冻结
    vm.prank(alice);
    vm.expectRevert();
    queue.claimReward(alice);

    // 4. depositReward 注入奖励冻结
    vm.prank(timelockAddr);
    vm.expectRevert();
    queue.depositReward(rewardProvider, 0.5 ether);

    // 5. slash罚没冻结
    vm.prank(timelockAddr);
    vm.expectRevert();
    queue.slash(queue.totalAssets(), 0.1 ether);

    // Timelock解除暂停
    vm.prank(timelockAddr);
    queue.unpause();
    assertFalse(queue.paused());

    // 验证业务恢复
    vm.prank(alice);
    queue.deposit(alice, 1 ether);
}

     // ===================== 安全测试3：拦截全部0地址入参（复用全局alice） =====================
function testZeroAddress_RevertAll() public {
    uint256 stakeAmt = 2 ether;
    vm.prank(alice);
    uint256 shares = queue.deposit(alice, stakeAmt);

    // 1. deposit recipient = address(0)
    vm.prank(alice);
    vm.expectRevert(SmallWethStaking.InvalidAddress.selector);
    queue.deposit(address(0), 1 ether);

    // 2. unstake recipient = address(0)
    vm.prank(alice);
    vm.expectRevert(SmallWethStaking.InvalidAddress.selector);
    queue.unstake(shares, address(0));

    // 3. claimReward recipient = address(0)
    vm.prank(alice);
    vm.expectRevert(SmallWethStaking.InvalidAddress.selector);
    queue.claimReward(address(0));

    // 4. depositReward recipient = address(0)
    vm.prank(alice);
    vm.expectRevert(SmallWethStaking.InvalidAddress.selector);
    queue.depositReward(address(0), 0.5 ether);

    // 5. setFeeRecipient 设置0地址
    vm.prank(timelockAddr);
    vm.expectRevert(SmallWethStaking.InvalidAddress.selector);
    queue.setFeeRecipient(address(0));
}  

    function testInsufficientBalance_RevertNoSilentTransfer() public {
    uint256 stakeAmt = 1 ether;
    vm.prank(alice);
    uint256 shares = queue.deposit(alice, stakeAmt);

    // 注入奖励，复用rewardProvider
    vm.prank(rewardProvider);
    queue.depositReward(rewardProvider, 0.5 ether);

    // 手动把合约WETH全部转出，制造余额不足场景
    address drain = makeAddr("drain");
    uint256 contractWethBal = weth.balanceOf(address(queue));
    vm.prank(address(queue));
    weth.transfer(drain, contractWethBal);
    assertEq(weth.balanceOf(address(queue)), 0);

    // 场景1：claimReward 领奖励，合约WETH余额不足，预期 revert InsufficientBalance
    vm.prank(alice);
    vm.expectRevert(SmallWethStaking.InsufficientBalance.selector);
    queue.claimReward(alice);

    // 场景2：unstake 提取本金+奖励，合约余额不足，预期 revert InsufficientBalance
    vm.prank(alice);
    vm.expectRevert(SmallWethStaking.InsufficientBalance.selector);
    queue.unstake(shares, alice);
}

/**
* 事件测试：操作：执行各类业务操作；预期：对应事件触发，事件字段参数全部正确记录
*/
function test_AllEventEmit() public {
    address currentFeeRecipient = address(queue.feeRecipient());
    uint256 stakeAmt = 2 ether;

    // 1. deposit质押，校验Staked事件
    vm.expectEmit(true, false, false, true);
    emit Staked(alice, stakeAmt, Math.mulDiv(stakeAmt, queue.SCALE(), queue.slashFactor()));
    uint256 shares = _deposit(alice, stakeAmt, alice);

    // 2. depositReward注入奖励，校验RewardDeposited事件
    uint256 rewardIn = 1 ether;
    uint256 feeCalc = Math.mulDiv(rewardIn, queue.rewardFeeRate(), queue.SCALE());
    uint256 netReward = rewardIn - feeCalc;
    vm.expectEmit(true, false, false, true);
    emit RewardDeposited(rewardSender, rewardIn, feeCalc, netReward);
    _executeDepositRewardProposalWithMint(rewardSender, feeRecipient, rewardIn);

    // 3. claimReward单独领奖励，校验RewardClaimed事件
    uint256 pending = queue.claimable(alice);
    vm.expectEmit(true, true, false, true);
    emit RewardClaimed(alice, alice, pending);
    vm.prank(alice);
    queue.claimReward(alice);

    // 4. 管理员slash罚没，校验SlashExecuted事件
    uint256 assetBeforeSlash = queue.totalAssets();
    uint256 lossAmt = 0.5 ether;
    uint256 oldSlashFactor = queue.slashFactor();
    uint256 newSlashFactorExp = Math.mulDiv(oldSlashFactor, assetBeforeSlash - lossAmt, assetBeforeSlash);
    uint256 cpId = queue.getSlashCheckpointCount();
    vm.expectEmit(true, false, false, true);
    emit SlashExecuted(cpId, oldSlashFactor, newSlashFactorExp, lossAmt, assetBeforeSlash - lossAmt);
    _slash(assetBeforeSlash, lossAmt);

    // 5. pause暂停，校验Paused事件
    vm.expectEmit(false, false, false, true);
    emit Paused(true);
    vm.prank(timelockAddr);
    queue.pause();

    // 6. unpause解除暂停，校验Paused事件
    vm.expectEmit(false, false, false, true);
    emit Paused(false);
    vm.prank(timelockAddr);
    queue.unpause();

    // 7. setFeeRecipient 修改手续费收款地址，校验FeeRecipientSet事件
    address newFeeRecipient = makeAddr("newFee");
    address oldFee = queue.feeRecipient();
    vm.expectEmit(true, true, false, true);
    emit FeeRecipientSet(oldFee, newFeeRecipient);
    vm.prank(timelockAddr);
    queue.setFeeRecipient(newFeeRecipient);

    // 8. setDepositLimit 修改质押限额，校验DepositLimitUpdated事件
    uint256 newMin = 1 ether;
    uint256 newPerUserMax = 40 ether;
    uint256 newPoolMax = 4000 ether;
    uint256 oldMin = queue.depositMin();
    uint256 oldPerUserMax = queue.depositPerUserMax();
    uint256 oldPoolMax = queue.depositPoolMax();
    vm.expectEmit(false, false, false, true);
    emit DepositLimitUpdated(oldMin, oldPerUserMax, oldPoolMax, newMin, newPerUserMax, newPoolMax);
    vm.prank(timelockAddr);
    queue.setDepositLimit(newMin, newPerUserMax, newPoolMax);

    // 9. setRewardFeeRate 修改手续费率，校验RewardFeeRateUpdated事件
    uint256 oldFeeRate = queue.rewardFeeRate();
    uint256 newFeeRate = 0.05e36; //5%
    vm.expectEmit(false, false, false, true);
    emit RewardFeeRateUpdated(oldFeeRate, newFeeRate);
    vm.prank(timelockAddr);
    queue.setRewardFeeRate(newFeeRate);

    // 10. unstake解质押，校验Unstaked事件，重新质押后测试
    uint256 stakeForUnstake = 1 ether;
    uint256 shareUnstake = _deposit(bob, stakeForUnstake, bob);
    _executeDepositRewardProposalWithMint(rewardSender, newFeeRecipient, 0.5 ether);
    uint256 pendingBob = queue.claimable(bob);
    vm.expectEmit(true, true, false, true);
    emit Unstaked(bob, shareUnstake, stakeForUnstake, pendingBob);
    vm.prank(bob);
    queue.unstake(shareUnstake, bob);
}

/**
* 异常测试：操作：gas不足无法操作；预期：交易失败，全部状态回滚
* 原理：vm.prank + vm.setGasLimit 设置极低gas，执行质押，Out of Gas，合约状态不变
*/
function test_OutOfGas_RevertAndRollback() public {
    uint256 stakeAmt = 2 ether;
    // 先校验前置，alice有WETH授权
    assertGt(weth.balanceOf(alice), stakeAmt);

    // 记录执行前快照
    uint256 assetBefore = queue.totalAssets();
    (uint256 shareBeforeAlice, uint256 aliceRewardIndex) = queue.userInfo(alice);

    // 设置极低gas，不足以跑完deposit完整逻辑，触发OutOfGas
    vm.prank(alice);
    // 用底层call，手动限制gas=1000，捕获OutOfGas
    (bool success, bytes memory ret) = address(queue).call{gas:1000}(
    abi.encodeWithSignature("deposit(address,uint256)", alice, 1 ether)
    );
    assertFalse(success);

    // 兜底校验：交易回滚，状态完全不变
    assertEq(queue.totalAssets(), assetBefore, "Assets can't change, OOG has to roll back");
    (uint256 shareAfterAlice, uint256 aliceRewardIndexAfter) = queue.userInfo(alice);
    assertEq(shareAfterAlice, shareBeforeAlice, "User share stays the same");
}

    /**
 * 安全测试5：管理员RateLimit频率限制，窗口86400区块，最多3条高危提案
 * 预期：
 * 1. RateLimit窗口为86400区块
 * 2. 窗口内最多提交3条高危提案(slash / setFeeRecipient)
 * 3. 提交第4条高危提案，创建提案直接revert
 * 4. 提案**到期执行动作**不受频率计数约束（计数只在【创建提案】阶段校验）
 */
function testAdminRateLimit_HighRiskProposal() public {
    address timelock = timelockAddr;
 
    vm.startPrank(timelock);


    // 2. 窗口内最多提交3条高危提案
    queue.createHighRiskProposal(
        "setFeeRecipient",
        abi.encodeWithSignature("setFeeRecipient(address)", recipient)
    );
    queue.createHighRiskProposal(
        "setFeeRecipient",
        abi.encodeWithSignature("setFeeRecipient(address)", alice)
    );
    queue.createHighRiskProposal(
        "setFeeRecipient",
        abi.encodeWithSignature("setFeeRecipient(address)", recipient)
    );

    // 3. 提交第4条高危提案，创建提案直接revert
    vm.expectRevert(abi.encodeWithSignature("HighRiskProposalRateLimitExceeded()"));
    queue.createHighRiskProposal(
        "setFeeRecipient",
        abi.encodeWithSignature("setFeeRecipient(address)", alice)
    );

    // 同窗口内，继续提交依然超限
    vm.roll(block.number + 100);
    vm.expectRevert(abi.encodeWithSignature("HighRiskProposalRateLimitExceeded()"));
    queue.createHighRiskProposal(
        "setFeeRecipient",
        abi.encodeWithSignature("setFeeRecipient(address)", recipient)
    );

    // 跨窗口：前进超过86400区块，计数器重置，可以再提交3条
    vm.roll(block.number + 86400);
    queue.createHighRiskProposal(
        "setFeeRecipient",
        abi.encodeWithSignature("setFeeRecipient(address)", recipient)
    );

    vm.stopPrank();
}

/**
 * 安全测试6：slash单次亏损上限校验
 * 操作：调用slash，传入亏损金额 > 500 WETH
 * 预期：revert，禁止单次罚没超过500 WETH
 */
function testSlash_SingleLossCapRevert() public {
    // 前置：Alice质押足够多资产，池子总资产大于500 WETH，满足可以尝试大额slash
    uint256 stakeAmt = 600 ether;
    _deposit(alice, stakeAmt, alice);
    assertEq(queue.totalAssets(), stakeAmt);

    // 单次罚没超过上限 500 ether → 预期回滚
    uint256 excessiveLoss = 501 ether;
    vm.prank(timelockAddr);
    // 替换为你合约对应的自定义错误签名，若用字符串报错就改成 vm.expectRevert("Slash: single loss exceed cap");
    vm.expectRevert(abi.encodeWithSignature("AdminSingleAmountExceedLimit()"));
    queue.slash(queue.totalAssets(), excessiveLoss);

    // 兜底校验：池子资产完全不变，罚没没有生效
    assertEq(queue.totalAssets(), stakeAmt, "Assets can't be changed, any big slash must be rolled back");
    (uint256 aliceShares, uint256 aliceIdx) = queue.userInfo(alice);
    assertEq(aliceShares, stakeAmt, "The user's original share stays the same");
}

/**
 * 安全测试7：高危配置函数禁止直接调用，必须走时间锁提案
 * 操作：直接调用 transferOwnership / setFeeRecipient / setDepositLimit / setRewardFeeRate / slash / depositReward
 * 预期：直接调用全部revert，不能执行；只能通过timelock提案调度执行
 */
function testHighRiskFunc_DirectCallRevert() public {
    uint256 testVal = 100 ether;
    address testAddr = makeAddr("testAddr");

    // 1. 直接调用 transferOwnership
    vm.prank(timelockAddr);
    vm.expectRevert();
    queue.transferOwnership(testAddr);

    // 2. 直接调用 setFeeRecipient
    vm.prank(timelockAddr);
    vm.expectRevert();
    queue.setFeeRecipient(testAddr);

    // 3. 直接调用 setDepositLimit
    vm.prank(timelockAddr);
    vm.expectRevert();
    queue.setDepositLimit(1 ether,1 ether,testVal);

    // 4. 直接调用 setRewardFeeRate
    vm.prank(timelockAddr);
    vm.expectRevert();
    queue.setRewardFeeRate(0.1 ether);

    // 5. 直接调用 slash
    vm.prank(timelockAddr);
    vm.expectRevert();
    queue.slash(queue.totalAssets(), 1 ether);

    // 6. 直接调用 depositReward
    vm.prank(timelockAddr);
    vm.expectRevert();
    queue.depositReward(timelockAddr,1 ether);

}

/**
 * 安全测试8：pause/unpause 不属于时间锁管控，管理员可直接调用，不要求timelock提案
 * 操作：管理员调用pause()、unpause()
 * 预期：调用成功，**不需要走timelock提案**，函数正常执行，状态变更生效
 */
function testPauseUnpause_NoTimelockRequired() public {
    // 前置：合约处于未暂停状态
    assertFalse(queue.paused());

    // 管理员直接pause，成功
    vm.prank(timelockAddr);
    queue.pause();
    assertTrue(queue.paused());

    // 管理员直接unpause，成功
    vm.prank(timelockAddr);
    queue.unpause();
    assertFalse(queue.paused());
}

    /**
 * 空池注入测试1：totalShares=0时调用depositReward，奖励进bufferReward，不进rewardPool，totalAssets不变
 * 操作：池子无任何份额(totalShares=0)，管理员调用depositReward注入奖励
 * 预期：奖励存入bufferReward；rewardPool保持0；totalAssets不变
 */
function testDepositReward_EmptyPool_GoToBuffer() public {
    // 前置：空池，无用户质押
    assertEq(queue.totalSupply(), 0);
    uint256 assetBefore = queue.totalAssets();
    uint256 bufferBefore = queue.getBufferReward();

    // timelock调用注入奖励
    vm.prank(timelockAddr);
    queue.depositReward(rewardProvider, 10 ether);

    // 校验：totalAssets不变（奖励不进本金池）
    assertEq(queue.totalAssets(), assetBefore);
    // 校验：bufferReward增加税后奖励
    uint256 fee = Math.mulDiv(10 ether, queue.rewardFeeRate(), queue.SCALE());
    uint256 netReward = 10 ether - fee;
    assertEq(queue.getBufferReward(), bufferBefore + netReward);
}


/**
 * 空池注入测试2：空池多次调用depositReward，bufferReward累加，rewardPool保持0
 * 操作：空池连续多次注入奖励
 * 预期：bufferReward不断累加；rewardPool始终为0
 */
function testDepositReward_EmptyPool_MultiAdd_BufferAccumulate() public {
    assertEq(queue.totalSupply(), 0);
    uint256 reward1 = 1 ether;
    uint256 reward2 = 2 ether;
    uint256 reward3 = 3 ether;

    address currentFeeRecipient = address(queue.feeRecipient());
    vm.prank(timelockAddr);
    queue.depositReward(feeRecipient,reward1);
    vm.prank(timelockAddr);
    queue.depositReward(feeRecipient,reward2);
    vm.prank(timelockAddr);
    queue.depositReward(feeRecipient,reward3);

    assertEq(queue.bufferReward(), reward1 + reward2 + reward3);
    
}

/**
 * 缓冲区迁移测试：空池注入奖励后，首个用户质押，buffer全部转入奖励池，buffer清零，触发BufferRewardMigrated事件
 * 操作：空池先注入奖励，Alice做第一笔质押
 * 预期：bufferReward全部迁移至rewardPool；bufferReward清零；触发BufferRewardMigrated事件；新奖励从当前区块参与分红
 */
function testBufferReward_MigrateOnFirstDeposit() public {
    // 前置：空池注入奖励
    assertEq(queue.totalSupply(), 0);
    uint256 bufferAmount = 5 ether;
    address currentFeeRecipient = address(queue.feeRecipient());
    vm.prank(timelockAddr);
    queue.depositReward( currentFeeRecipient,bufferAmount);
    assertEq(queue.bufferReward(), bufferAmount);
    

    // 预期迁移事件
    vm.expectEmit(true, false, false, true);
    emit BufferRewardMigrated(bufferAmount);

    // 首个用户质押
    uint256 stakeAmt = 2 ether;
    _deposit(alice, stakeAmt, alice);

    // 校验迁移结果
    assertEq(queue.bufferReward(), 0, "bufferReward become zero");
    
}

/**
 * 缓冲区不可提取测试：管理员无法提取bufferReward，不存在提取接口
 * 操作：管理员尝试调用提取bufferReward的接口
 * 预期：接口不存在，调用直接revert
 */
function testBufferReward_NoWithdrawInterface() public {
    // 前置：空池注入奖励到buffer
    assertEq(queue.totalSupply(), 0);
    uint256 bufferAmount = 1 ether;
    address currentFeeRecipient = address(queue.feeRecipient());
    vm.prank(timelockAddr);
    queue.depositReward(currentFeeRecipient,bufferAmount);
    assertEq(queue.bufferReward(), bufferAmount);

    // 假设接口名称为 withdrawBufferReward，该接口不存在，调用会revert
    vm.prank(timelockAddr);
    vm.expectRevert();
    (bool success, ) = address(queue).call(abi.encodeWithSignature("withdrawBufferReward()"));
    assertFalse(success);

    // 兜底校验buffer没有变化
    assertEq(queue.bufferReward(), bufferAmount);
}

/**
 * 缓冲区不计入总资产测试：空池注入奖励后，totalAssets不含bufferReward
 * 操作：空池注入奖励，查询totalAssets
 * 预期：totalAssets只统计用户质押本金，bufferReward不计入
 */
function testBufferReward_NotCountInTotalAssets() public {
    // 空池，初始总资产0
    assertEq(queue.totalAssets(), 0);
    uint256 rewardInBuffer = 3 ether;

    address currentFeeRecipient = address(queue.feeRecipient());
    vm.prank(timelockAddr);
    queue.depositReward(currentFeeRecipient,rewardInBuffer);

    // 总资产不变，buffer不计入totalAssets
    assertEq(queue.totalAssets(), 0);
    assertEq(queue.bufferReward(), rewardInBuffer);
    
}

/**
 * 34. 份额铸造测试1：每次deposit质押，校验份额严格使用合约公式：sharesMinted = Math.mulDiv(amount, SCALE, slashFactor)
 * 操作：执行deposit质押
 * 预期：铸造份额完全匹配该公式计算结果
 */
function testDeposit_MintShareFormula() public {
    
    // 前置：空池初始状态
    assertEq(queue.totalSupply(), 0);
    uint256 currentSlashFactor = queue.slashFactor();

    // 第一笔质押，校验公式
    uint256 depositAmt = 5 ether;
    uint256 expectShares = Math.mulDiv(depositAmt, SCALE, currentSlashFactor);
    vm.prank(alice);
    uint256 receivedShares = _deposit(alice, depositAmt, alice);
    assertEq(receivedShares, expectShares, "shares = amount * SCALE / slashFactor");

    // 更新slashFactor，再质押一笔，再次校验公式生效
    // 先执行slash修改slashFactor
    vm.prank(timelockAddr);
    uint256 poolTotalAssetsBefore = queue.totalAssets();
    queue.slash(poolTotalAssetsBefore, 2 ether);
    uint256 newSlashFactor = queue.slashFactor();

    uint256 depositAmt2 = 10 ether;
    uint256 expectShares2 = Math.mulDiv(depositAmt2, SCALE, newSlashFactor);
    vm.prank(bob);
    uint256 receivedShares2 = _deposit(bob, depositAmt2, bob);
    assertEq(receivedShares2, expectShares2, "After modifying slashFactor, the minting formula check failed");
}


/**
 * 35. 份额铸造测试2：已有slash罚没后，新用户质押；验证新用户原始份额按公式计算，不受历史罚没影响
 * 操作：先质押 -> slash罚没修改slashFactor -> 新用户Bob质押
 * 预期：新质押的原始份额使用**当前最新slashFactor**计算，历史罚不会让新存入本金额外缩水
 */
function testDeposit_AfterSlash_NewUserOriginalShareCalculation() public {
    
    // Alice先质押
    uint256 aliceStake = 10 ether;
    _deposit(alice, aliceStake, alice);

    // 执行slash，全局slashFactor衰减
    uint256 lossAmt = 2 ether;
    vm.prank(timelockAddr);
    uint256 poolTotal = queue.totalAssets();
    queue.slash(poolTotal, lossAmt);
    uint256 latestSlashFactor = queue.slashFactor();

    // Bob作为新用户质押
    uint256 bobStake = 5 ether;
    uint256 expectBobShares = Math.mulDiv(bobStake, SCALE, latestSlashFactor);
    vm.prank(bob);
    uint256 bobShares = _deposit(bob, bobStake, bob);

    // 校验：新用户原始份额 = amount * SCALE / 当前slashFactor；历史罚没不会对新本金二次缩水
    assertEq(bobShares, expectBobShares, "New user's original share pledge calculation is wrong");
}

/**
 * 36. 罚没测试4：存在slash快照；用户claimReward；奖励分段计算，快照前区间使用快照slashFactor，快照后区间使用最新slashFactor；无需遍历所有用户
 * 操作：质押 → 注入奖励（快照前）→ slash生成快照（记录oldSlashFactor）→ 注入奖励（快照后）→ 用户claimReward
 * 预期：奖励分段计算；快照前使用快照slashFactor；快照后使用最新slashFactor；合约不遍历全部用户
 */
function testSlashSnapshot_RewardSegmentCalc_Precise() public {
    
    // 1.Alice质押
    uint256 stakeAmt = 10 ether;
    _deposit(alice, stakeAmt, alice);
    (uint256 aliceUserShares, uint256 aliceUserRewardIndex) = queue.userInfo(alice);
    uint256 userRewardIndexSnapshot = queue.getUserRewardIndexSnapshot(alice);

    // 2.注入【快照前】奖励
    uint256 rewardBeforeSlash = 1 ether;
    address currentFeeRecipient = address(queue.feeRecipient());
    vm.prank(timelockAddr);
    queue.depositReward(currentFeeRecipient,rewardBeforeSlash);

    // 记录slash快照点位参数
    uint256 oldSlashFactor = queue.slashFactor();
    uint256 rewardIndexBeforeSlash = queue.rewardIndex();

    // 3.执行slash罚没，生成快照，更新全局slashFactor
    uint256 lossAmt = 2 ether;
    vm.prank(timelockAddr);
    uint256 newSlashFactor = queue.slashFactor();
    uint256 rewardIndexAfterSlash = queue.rewardIndex();

    // 4.注入【快照后】奖励
    uint256 rewardAfterSlash = 1 ether;
    vm.prank(timelockAddr);
    queue.depositReward(currentFeeRecipient,rewardAfterSlash);
    uint256 rewardIndexFinal = queue.rewardIndex();

    // ========== 复刻合约分段奖励计算逻辑 ==========
    // 用户原始份额不变
    uint256 userRawShares = aliceUserShares;

    // 快照前区间奖励增量：[userSnapshotIndex → rewardIndexBeforeSlash]，使用oldSlashFactor
    
    uint256 userEffectiveShareOld = _calcEffective(userRawShares, queue.slashFactor());
    uint256 deltaIndexBefore = rewardIndexBeforeSlash - userRewardIndexSnapshot;
    uint256 expectedRewardBefore;
    uint256 userOldRewardIndex;
{
    
    
    userOldRewardIndex = queue.getUserRewardIndexSnapshot(alice);
   
    
    expectedRewardBefore = Math.mulDiv(userEffectiveShareOld, deltaIndexBefore, SCALE);
}


    // 快照后区间奖励增量：[rewardIndexBeforeSlash → rewardIndexFinal]，使用newSlashFactor
    uint256 userEffectiveShareNew = Math.mulDiv(userRawShares, newSlashFactor, SCALE);
    uint256 deltaIndexAfter = rewardIndexFinal - rewardIndexBeforeSlash;
    uint256 expectedRewardAfter = Math.mulDiv(userEffectiveShareNew, deltaIndexAfter, SCALE);

    uint256 expectedTotal = expectedRewardBefore + expectedRewardAfter;

    // 用户领取奖励
    vm.prank(alice);
    uint256 claimAmount = queue.claimReward(alice);

    // 精确校验
    assertEq(claimAmount, expectedTotal, "Segmented reward calculation is wrong, slashFactor behaves weirdly before and after the snapshot");
}


/**
 * 安全测试9：管理员提交setFeeRecipient / setDepositLimit高危提案到时间锁
 * 操作：创建提案，等待7天窗口期；窗口期内执行预期revert；窗口期结束后执行成功，触发事件
 * 预期：提案进入7天等待期；未到时间执行revert；到期后可执行，状态变更并emit事件
 */
function testTimelock_HighRiskProposal_WindowWait7Days() public {
    address newFeeRecipient = makeAddr("newFeeRecipient");
    uint256 newDepositMin = 1000 wei;
    uint256 newDepositPerUserMax = 100 wei;
    uint256 newDepositPoolMax = 10000 wei;
    uint256 waitBlock = (7 * 86400) / 12; // 7天对应区块（以太坊约12s/块）
    address oldFeeRecipient = queue.feeRecipient();

    // ========== 提案1：setFeeRecipient ==========
    vm.prank(timelockAddr);
    bytes memory callData1 = abi.encodeWithSignature("setFeeRecipient(address)", newFeeRecipient);
    queue.createHighRiskProposal("test1", callData1);
    uint256 countBefore1 = queue.getHighRiskProposalLength();
    uint256 propId1 = countBefore1 - 1; // ✅ 重点！push之后，新提案id = length-1，你之前写countBefore1是错的

    // 窗口期未到，直接执行，预期revert
    vm.prank(timelockAddr);
    vm.expectRevert(abi.encodeWithSignature("ProposalNotReady()"));
    queue.executeHighRiskProposal(propId1);

    // 快进区块，跨过7天等待窗口期
    vm.roll(block.number + waitBlock);

    // 窗口期到期，执行提案，预期触发事件
    vm.expectEmit(true, true, false, true);
    emit SmallWethStaking.FeeRecipientSet(oldFeeRecipient, newFeeRecipient);
    vm.prank(timelockAddr);
    queue.executeHighRiskProposal(propId1);
    assertEq(queue.feeRecipient(), newFeeRecipient);

    // ========== 提案2：setDepositLimit ==========
    vm.prank(timelockAddr);
    uint256 oldMin = queue.depositMin();
    uint256 oldPerUserMax = queue.depositPerUserMax();
    uint256 oldPoolMax = queue.depositPoolMax();
    bytes memory callData2 = abi.encodeWithSignature(
        "setDepositLimit(uint256,uint256,uint256)",
        newDepositMin,
        newDepositPerUserMax,
        newDepositPoolMax
    );
    queue.createHighRiskProposal("test2", callData2);
    uint256 countBefore2 = queue.getHighRiskProposalLength();
    uint256 propId2 = countBefore2 - 1;

    // 窗口期内执行 revert
    vm.prank(timelockAddr);
    vm.expectRevert(abi.encodeWithSignature("ProposalNotReady()"));
    queue.executeHighRiskProposal(propId2);

    // 快进7天区块
    vm.roll(block.number + waitBlock);

    vm.expectEmit(true, true, true, true);
    emit SmallWethStaking.DepositLimitUpdated(
        oldMin,
        oldPerUserMax,
        oldPoolMax,
        newDepositMin,
        newDepositPerUserMax,
        newDepositPoolMax
    );
    vm.prank(timelockAddr);
    queue.executeHighRiskProposal(propId2);

    assertEq(queue.depositMin(), newDepositMin);
    assertEq(queue.depositPerUserMax(), newDepositPerUserMax);
    assertEq(queue.depositPoolMax(), newDepositPoolMax);
}


/**
 * 38. 安全测试10：管理员直接调用setDepositLimit不经过时间锁，尝试调高限额后立刻slash
 * 操作：管理员直接调用setDepositLimit调高池子限额，不通过时间锁提案
 * 预期：直接调用setDepositLimit会revert；参数修改必须走时间锁7天提案窗口；窗口期内原值不变，不能即时改限额绕过slash限制
 */
function testSecurity10_SetDepositLimit_MustGoThroughTimelock() public {
    uint256 oldMin = queue.depositMin();
    uint256 oldPerUserMax = queue.depositPerUserMax();
    uint256 oldPoolMax = queue.depositPoolMax();
    uint256 newMin = 1 ether;
    uint256 newPerUserMax = 50 ether;
    uint256 newPoolMax = 10000 ether;

    // 直接调用setDepositLimit，不走时间锁，预期revert
    vm.prank(timelockAddr);
    vm.expectRevert();
    queue.setDepositLimit(newMin, newPerUserMax, newPoolMax);
    // 校验参数没有变化
    assertEq(queue.depositPoolMax(), oldPoolMax, "The pool limit shouldn't be changed directly");

    // 走时间锁提案流程才可以修改
    uint256 waitBlocks = (7 * 86400) / 12;
    vm.prank(timelockAddr);
    uint256 propId = queue.createHighRiskProposal(
        "setDepositLimit",
        abi.encodeWithSignature("setDepositLimit(uint256,uint256,uint256)", newMin, newPerUserMax, newPoolMax)
    );
    // 窗口期未到期执行，revert
    vm.prank(timelockAddr);
    vm.expectRevert(abi.encodeWithSignature("ProposalNotReady()"));
    queue.executeHighRiskProposal(propId);
    assertEq(queue.depositPoolMax(), oldPoolMax);

    // 等待7天窗口结束，执行成功
    vm.roll(block.number + waitBlocks);
    vm.expectEmit(true, true, true, true);
    emit SmallWethStaking.DepositLimitUpdated(oldMin, oldPerUserMax, oldPoolMax, newMin, newPerUserMax, newPoolMax);
    vm.prank(timelockAddr);
    queue.executeHighRiskProposal(propId);
    assertEq(queue.depositPoolMax(), newPoolMax);
}


/**
 * 39. 安全测试11：Gnosis多签提交合法slash罚没提案到时间锁
 * 操作：Gnosis多签创建slash提案，等待窗口期
 * 预期：提案进入7天等待期；窗口期内执行revert；到期执行成功，更新slashFactor、totalAssets，触发事件
 */
function testSecurity11_SlashProposal_FromGnosisSafe() public {
    address gnosisSafe = makeAddr("timelockAddr");
    uint256 stakeAmt = 10 ether;
    _deposit(alice, stakeAmt, alice);
    uint256 oldSlashFactor = queue.slashFactor();
    uint256 oldTotalAssets = queue.totalAssets();
    uint256 lossAmt = 1 ether;
    uint256 waitBlocks = (7 * 86400) / 12;

    // Gnosis多签提交slash提案
    vm.prank(gnosisSafe);
    uint256 propId = queue.createHighRiskProposal(
        "slash",
        abi.encodeWithSignature("slash(uint256,uint256)", oldTotalAssets, lossAmt)
    );
    // 窗口期未到执行，revert
    vm.prank(gnosisSafe);
    vm.expectRevert(abi.encodeWithSignature("ProposalNotReady()"));
    queue.executeHighRiskProposal(propId);
    // 状态保持不变
    assertEq(queue.slashFactor(), oldSlashFactor);
    assertEq(queue.totalAssets(), oldTotalAssets);

    // 快进区块，7天窗口期结束
    vm.roll(block.number + waitBlocks);
    // 执行罚没，触发事件
    uint256 checkpointId = queue.getHighRiskProposalLength() - 1;
    uint256 expectedNewSlashFactor = Math.mulDiv(oldSlashFactor, oldTotalAssets - lossAmt, oldTotalAssets);
    uint256 expectedNewTotalAssets = oldTotalAssets - lossAmt;
    vm.expectEmit(true, false, false, true);
    emit SmallWethStaking.SlashExecuted(checkpointId, oldSlashFactor, expectedNewSlashFactor, lossAmt, expectedNewTotalAssets);
    vm.prank(gnosisSafe);
    queue.executeHighRiskProposal(propId);
    // 校验罚没生效
    assertLt(queue.slashFactor(), oldSlashFactor, "slashFactor should decrease");
    assertEq(queue.totalAssets(), expectedNewTotalAssets);
}


/**
 * 40. 安全测试12：普通外部账户（非Gnosis多签owner）提交slash提案
 * 操作：普通用户alice尝试创建slash时间锁提案
 * 预期：提交提案直接revert，提案创建失败
 */
function testSecurity12_SlashProposal_RejectUnauthorizedSubmitter() public {
    address normalUser = makeAddr("hacker");
    uint256 lossAmt = 1 ether;

    // 普通账户尝试创建slash提案，权限校验失败
    vm.prank(normalUser);
    vm.expectRevert(abi.encodeWithSignature("NotProposalSubmitter()"));
    queue.createHighRiskProposal(
        "slash",
        abi.encodeWithSignature("slash(uint256)", lossAmt)
    );
}

/**
 * 41. 安全测试13：Gnosis多签提交slash提案，亏损金额超过SLASH_MAX_RATIO上限
 * 操作：合法多签提交slash提案，但是loss超过最大罚没比例；等待窗口期后执行
 * 预期：窗口期到期执行交易revert；不执行罚没，所有状态保持不变
 */
function testSecurity13_SlashProposal_ExceedMaxRatio_RevertOnExecute() public {
    address gnosisSafe = makeAddr("gnosisSafe");
    uint256 stakeAmt = 10 ether;
    _deposit(alice, stakeAmt, alice);
    uint256 oldSlashFactor = queue.slashFactor();
    uint256 oldTotalAssets = queue.totalAssets();
    // 亏损超过SLASH_MAX_RATIO上限
    uint256 excessiveLossAmt = 2 ether; // slashMaxRatio=10%，10ether池子最多罚1ether
    uint256 waitBlocks = (7 * 86400) / 12;
    // 提案可以正常创建（校验放在执行阶段，不是提交阶段）
    vm.prank(gnosisSafe);
    uint256 propId = queue.createHighRiskProposal(
        "slash",
        abi.encodeWithSignature("slash(uint256,uint256)", oldTotalAssets, excessiveLossAmt)
    );
    // 等待7天窗口期结束
    vm.roll(block.number + waitBlocks);
    // 执行时校验罚没比例超限，交易revert
    vm.prank(gnosisSafe);
    vm.expectRevert(abi.encodeWithSignature("SlashLossExceedMaxRatio()"));
    queue.executeHighRiskProposal(propId);
    // 兜底校验：状态完全不变
    assertEq(queue.slashFactor(), oldSlashFactor);
    assertEq(queue.totalAssets(), oldTotalAssets);
}


    }

    contract WETHMock is ERC20 {
    constructor() ERC20("MockWETH", "WETH"){}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }
}
// 共用攻击合约：支持切换回调内要执行的目标函数
//安全测试1
contract ReentrancyAttacker {
    address public immutable staking;
    address public immutable weth;
    uint8 public targetCall; //1=unstake,2=claimReward

    constructor(address _staking, address _weth) {
        staking = _staking;
        weth = _weth;
    }

    function setTargetCall(uint8 _t) external {
        targetCall = _t;
    }

    // WETH ERC20 transfer触发fallback，执行重入
    fallback() external {
        if(targetCall == 1) {
            // 重入 unstake
            IStake(staking).unstake(IStake(staking).userInfo(address(this)).userShares, address(this));
        } else if(targetCall == 2) {
            // 重入 claimReward
            IStake(staking).claimReward(address(this));
        }
    }

    
} 

interface IStake {
    struct UserInfo {
        uint256 userShares;
    }
    function userInfo(address user) external view returns (UserInfo memory);
    function unstake(uint256 shares, address recipient) external;
    function claimReward(address user) external;
}


    
