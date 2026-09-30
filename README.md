# 开发小额staking 产品

## 目标用户及相关质押规则

### 目标用户
小额散户用户：持有零散主网代币，无大额本金，追求低门槛 + 资产流动性

### 核心使用场景
1. 主场景 1：用户连接钱包授权→输入质押数量→确认交易→到账质押份额<br>
2. 主场景 2：用户解除质押→本金及奖励返还至用户钱包<br>
3. 异常场景：链上 Gas 异常交易失败<br>

### 主要参数
选定：质押资产 = WETH (ERC20 标准包装 ETH)<br>
代币类型：标准 ERC20，18 位小数精度<br>
固定代币地址<br>
Ethereum 主网 WETH：0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2<br>
Sepolia测试网 WETH：以实际部署地址为准，合约内由构造函数传入<br>
核心流程强制规范：必须先 approve → 再 transferFrom<br>
所有数量单位：18 位小数精度,wei <br>
禁止重复领取：用户领取奖励后，本地待领奖励清零，同时将用户记账点位对齐至当前全局累计奖励点位，标记该用户已结算至当前计息节点，防止重复申领 <br>
精度误差：统一使用 1e36 放大系数，整除运算无浮点误差、无累积舍入<br>
Slashing：资产缩水不影响历史已累计奖励，仅影响后续分红权重 <br>
claimReward() 函数质押用户本人调用领取奖励 <br>
用户实际资产 = Math.mulDiv (Math.mulDiv (userShares, slashFactor, SCALE), totalAssets, Math.mulDiv (totalShares, slashFactor, SCALE) ) <br>
凭证是内部记账变量<br>

### 业务流程
1. 用户钱包授权合约调用WETH代币 → 发起质押交易 → 合约划转代币 → 记录质押份额与池总量，即刻开始计息（质押最小金额为1个代币，且不能为0，设置单个地址最大质押额50个代币，质押池总质押额5000代币）<br>
2. 系统开始计算收益<br>
3. 用户可随时领取奖励<br>
4. 按总收益抽取手续费<br>
5. 用户可随时解质押取回本金<br>
6. 罚没计算：contractWethBalance：合约当前实际持有的 WETH 余额（链上真实余额）；totalAssets：账面总资产，totalAssets 仅统计用户质押本金；合约实际 WETH 余额 = 质押本金 (totalAssets)+bufferReward 缓冲区资金 + 未分发奖励，因此合约余额不等于 totalAssets，发现区块出现罚没时，亏损 WETH 划转至运营账户，计算资产亏损比例，更新全局 slashFactor 衰减因子<br>
7. 用户解质押时自动结算未领奖励（防重入，避免重复领取本金和奖励）<br>
8. 更新账面总资产<br>
9. 如果当前无用户质押，调用 depositReward 产生的奖励存入 bufferReward 缓冲区；bufferReward 暂存期间不计入 totalAssets、不参与分红。当发生第一笔用户质押，totalShares > 0 时，缓冲区全部暂存奖励一次性转入正式奖励池，bufferReward 清零并触发 BufferRewardMigrated 事件；转入的奖励进入奖励池用于分红，不并入 totalAssets（totalAssets 仅统计用户质押本金）。<br>

### 质押奖励规则
1. 计息基准规则:按区块计息，交易上链当前区块即刻生效，新质押/追加质押：当前区块开始累计奖励，部分/全部解质押：赎回区块停止新增奖励，已累计奖励保留<br>
2. 公式：单用户可领取奖励 = 用户有效质押份额 × 对应区间累计总奖励/全网有效总份额 <br>  有效质押份额 = Math.mulDiv (userShares, slashFactor, SCALE) 全网有效总份额：所有用户有效份额之和，= 全网原始总份额 × slashFactor <br>  
3. 奖励来源：传入税前总收益，合约在链上自动扣除 10% 固定比例手续费；扣除的手续费划转至手续费接收地址，剩余金额进入质押奖励池。<br>
4. 奖励注入方式：调用 depositReward(uint256 amount)，传入税前总收益，合约自动完成手续费拆分，将税后部分注入奖励池。注入即时生效，从当前区块开始参与全网分红。如果当前无用户质押，本次注入奖励(bufferReward)暂存合约奖励池，暂存期间不参与分红、不计入待分发收益、不计入质押池`totalAssets`；管理员不可提取暂存缓冲区资金。当发生第一笔用户质押，totalShares > 0时，缓冲区全部暂存奖励一次性转入正式奖励池，从该质押对应的区块开始参与全网分红。depositReward 属于管理员高危操作，已纳入7天时间锁调度与 RateLimit 提案频率限制，无法即时大额注入奖励，彻底规避奖励池剧烈波动、刷奖励风险。<br>
5. 奖励结算时点：1、用户解质押时计算奖励并结算；2、单独结算奖励部分：用户可随时主动调用 claimReward() 提取累计待领奖励，操作不减少自身质押份额，质押状态保持不变；领取后自动完成记账点位对齐，已发放奖励不会重复计算；无待领奖励时调用函数，不会产生转账，仅静默返回；该接口与解质押结算相互独立<br>
6. 查询奖励：快照模式，查询奖励时实时计算，不实时修改用户数据<br>
7. 已固化的历史奖励，按罚没前旧 slashFactor 快照计算，不受后续 slashFactor 变化影响 <br>  


### 罚没规则
1. 仅管理员触发，通过全局衰减因子实现用户有效份额同比例缩水<br>
2. 缩水资产计算：
- `totalAssets`：账面总资产（用户质押本金）
- `lossAmount`：亏损金额（必须 ≤ totalAssets）
- `SCALE = 1e36`（精度放大系数）
- newTotalAssets ：罚没执行之后新的账面总资产
- totalAssetsBeforeSlash ：罚没执行之前的账面总资产
- 用户存储记录`userShares`为原始份额
- 用户计算：`effectiveShares = Math.mulDiv(userShares, slashFactor, SCALE)`<br>
3. 人工每15天检查节点份额并留存记录，当出现亏损，进行上报并进行罚没，亏损金额必须 ≤ 当前质押池总质押量，禁止超量上报<br>
4. Slashing 执行前，需统一结算全网点位，所有用户已产生的奖励全部固化。rewardIndex：全局奖励累计点位（放大 1e36 精度）;slashCheckpoint[]：数组存储每一次 slash 快照：(snapshotRewardIndex, snapshotSlashFactor, timestamp)，每一条快照 = 罚没发生那一刻的(全局奖励点位 + 当前 slashFactor)<br>
4.1 先读取当前全局rewardIndex，写入一条新 slashCheckpoint, 固化所有用户截至当前区块的奖励<br>
4.2 更新slashFactor、更新totalAssets<br>
4.3 触发 Slash 事件，写入快照索引、旧/新 slashFactor、亏损金额、区块号<br>
4.4 Slashing 执行前固化奖励，采用全局奖励检查点快照机制，不遍历用户存储。在 slash 触发时记录全局 rewardIndex 与当前 slashFactor 作为快照。用户后续操作时，基于快照区间分段计算奖励；快照区间内的奖励使用快照对应的 slashFactor，不受后续 slashFactor 变更<br>
5. Slashing 执行后，记录罚没数据<br>
6. Slashing 触发前：固化奖励快照，更新全局奖励累计参数，冻结本次罚没区间内的奖励，不循环遍历用户结算奖励。<br>
7. 触发slash，计算新的slashFactor, slashFactor_new = Math.mulDiv(slashFactor_old, newTotalAssets, totalAssetsBeforeSlash)。用户操作时实时有效份额 = Math.mulDiv(userShares, slashFactor, SCALE) <br>
8. 计算罚没后的新`slashFactor`，仅更新全局`slashFactor`、全局总资产`totalAssets`；不修改任意用户的 userShares。<br>
9. 用户在后续 deposit/withdraw/claimReward 操作时，自动基于当前 slashFactor 懒计算有效份额与可提取奖励。<br>
10. 所有读取用户有效份额、计算奖励的地方，都必须带上`slashFactor`做 mulDiv 计算。<br>
11. 多次罚没场景：slashFactor为累积乘法，仅记录最新全局值；本金有效份额随多次罚没连续衰减。每次罚没触发前会固化截至该时点已产生奖励，已固化奖励不受后续任何罚没缩水影响。

### 安全架构
1. 防重入：全局引入 ReentrancyGuard，所有资金交互函数统一加锁<br>
2. 访问控制：基于 Ownable + 函数级 onlyOwner，区分普通用户 / 管理员<br>
3. 紧急暂停：全局开关，故障 / 攻击时暂停核心业务；紧急暂停/启动开关：基于 Pausable 提供 pause()/unpause() <br>
4. 基础入参校验：零地址、零金额、越界数值 全场景拦截<br>
5. 资金转移容错：统一使用 SafeERC20，兜底 ERC20 转账失败<br>
6. 管理员风控：1、调用频率对管理员接口增加 RateLimit 调用频率限制：RateLimit 作用于【时间锁提案提交】动作，仅统计提交提案次数，提案到期执行动作不计入频率计数；设置单位时间最大提交提案次数，防止短时间批量提交高危提案；2、配置单次操作金额上限阈值，管理员单次资金类操作不可超过阈值；3、部署时，将 owner 设置为 Gnosis Safe 多签钱包地址，大额操作必须通过多签确认（合约仅定义单一 owner 角色，owner 地址部署为 Gnosis Safe 多签钱包（如 2/3），多签校验在钱包层实现，合约内部不内置多签逻辑。）；4、所有涉及资金、配置变更的管理员接口默认经过时间锁（7天）调度，禁止管理员即时执行高危动作；例外豁免清单：pause ()、unpause ()。豁免接口不经过时间锁，豁免接口不受 RateLimit 频率限制。以下还需要时间锁控制：transferOwnership()：转移合约 owner 权限；setFeeRecipient()：修改手续费接收地址 feeRecipient；setDepositLimit()：修改质押参数（单地址质押上限、池子总上限、最小质押金额）；setRewardFeeRate()：修改奖励手续费比例；depositReward ()<br>
7. claimReward() 函数质押用户本人调用领取奖励，禁止代领奖励；<br>
8. 状态变更规范：严格遵循 Checks-Effects-Interactions(CEI) 模式<br>

### 份额铸造
1. 用户质押输入 WETH 本金 amount，合约计算存入原始记账份额：userShares = Math.mulDiv(amount, SCALE, slashFactor)<br>
2. 原始记账份额`userShares`永久存储在用户记录，不会随 slash 修改<br>
3. 有效参与分红份额：effectiveShares = Math.mulDiv(userShares, slashFactor, SCALE)<br>
4. 当 slashFactor = SCALE（从未罚没），userShares = amount，和常规 1:1 份额行为保持一致<br>
5. 新用户质押时，历史罚没仅影响存量质押用户，新质押本金不受历史 slashFactor 衰减<br>

### 全局风控参数表
| 参数名称 | 符号 | 推荐值 | 业务含义 | 谁能修改 | 修改流程 |
|---|---|---|---|---|---|
| Timelock等待窗口期 | TIMELOCK_DELAY | 50400 区块（约7天，以太坊主网1区块≈12s） | 所有需要时间锁的提案，提交后必须等待该区块数才能执行；豁免接口不受该延迟约束 | Owner（Gnosis多签） | 时间锁调度，不可即时改 |
| 管理员接口频率限制窗口 | RATE_LIMIT_WINDOW | 86400 区块（约12天） | RateLimit统计周期，仅作用于非豁免管理员接口 | Owner（Gnosis多签） | 时间锁调度 |
| 管理员窗口内最大调用次数 | RATE_LIMIT_MAX_CALLS | 3次 / 窗口 | 管理员高危接口（slash/setFeeRecipient/setDepositLimit/setRewardFeeRate/transferOwnership/depositReward）在窗口内最多提交3次；超过直接revert | Owner（Gnosis多签） | 时间锁调度 |
| Slash单次最大扣减比例 | SLASH_MAX_RATIO | 10%（SCALE=1e36） | 单次slash最多只能罚没当前totalAssets的10%；单次亏损不能超过该比例，防止一次性掏空池子 | Owner（Gnosis多签） | 时间锁调度 |
| 管理员单次资金操作金额上限 | ADMIN_SINGLE_MAX_AMOUNT | 500 WETH（wei） | 管理员资金类操作（slash）单次操作金额上限；超过直接revert | Owner（Gnosis多签） | 时间锁调度 |
| 奖励手续费比例 | REWARD_FEE_RATE | 10%（SCALE=1e36） | depositReward自动扣取手续费比例 | Owner（Gnosis多签） | 时间锁调度 |
| 单地址质押上限 | DEPOSIT_PER_USER_MAX | 50 WETH | 单个用户最大质押额度 | Owner（Gnosis多签） | 时间锁调度 |
| 池子全局质押上限 | DEPOSIT_POOL_MAX | 5000 WETH | 质押池本金总上限 | Owner（Gnosis多签） | 时间锁调度 |
| 最小质押金额 | DEPOSIT_MIN | 1 WETH | 单笔质押最低门槛 | Owner（Gnosis多签） | 时间锁调度 |

### 测试
1. 测试范围：功能测试、边界测试、异常测试、安全测试、奖励计算测试、Slashing 罚没测试、集成流程测试<br>
2. 测试环境：本地测试网<br>
3. 测试类型：单元测试、集成测试、链路测试、安全攻防测试<br>
4. 测试条件：合约正常部署，构造函数传入合法 WETH 地址、手续费接收地址；测试账户持有足量 WETH，已完成钱包 approve 授权；手续费固定比例：10%；单笔最小质押：1 WETH；单地址最大质押：50 WETH；质押池全局上限：5000 WETH；精度放大系数：1e36；所有资金函数启用 ReentrancyGuard、全局暂停开关、SafeERC20<br>

#### 测试流程
1. 首次质押：操作：用户 approve 授权 → 质押 1 WETH（最小值）；预期结果：交易成功、用户质押份额正确、全局池总量累加、Staked 事件触发、当前区块开始计息<br>
2. 追加质押：操作：已有质押用户再次追加质押；预期结果：追加前自动结算历史奖励，旧份额算旧奖励、新份额新区块计息，数据隔离正确<br>
3. 用户部分解质押：操作：质押多笔后赎回部分本金；预期结果：自动结算全部未领奖励、剩余份额继续计息、本金+奖励正常退回<br>
4. 用户全额解质押：操作：全额解质押；预期：所有收益结清、质押份额清零、全局总量扣减正确<br>
5. 边界测试1：操作：质押；预期：质押金额不为0<br>
6. 边界测试2：操作：质押；预期：质押金额不超50<br>
7. 边界测试3：操作：质押：预期：质押池总量不超5000，若超过，质押失败<br>
8. 边界测试4：操作：解质押；预期：解质押金额小于等于质押金额，若超过，解质押失败<br>
9. 管理员测试1：操作：记录快照并更新收益；预期：有收益，调用depositReward，并记录；无收益，记录全局状态；亏损：进行罚没操作，并记录<br>
10. 管理员测试2：操作：进行罚没；预期：执行前全局奖励点位全部结算固化；用户原始份额不变，有效份额通过 slashFactor 正确衰减；历史待领奖励完全不变；后续奖励按新有效份额重新分；<br>
11. 管理员测试3：操作：用户操作；预期：用户无法操作管理员函数<br>
12. 奖励测试1：操作：用户解质押；预期：不同质押额的用户有按比例获得奖励<br>
13. 奖励测试2：操作：领取奖励；预期：没有重复领取奖励<br>
14. 奖励测试3：操作：奖励来源计算；预期：管理员调用 depositReward，传入税前总收益，合约自动完成手续费拆分，将税后收益转入合约奖励池<br>
15. 精度测试：操作：基于1e36进行质押、解质押操作，没有精度漂移造成的亏损或质押池资产损失<br>
16. 罚没测试1：操作：传入合法大于 0 的亏损金额执行罚没；预期：slashFactor 正确更新，totalAssets 扣减，用户原始 userShares 不变<br>
17. 罚没测试2：操作：罚没；预期：罚没金额小于等于质押池总量<br>
18. 罚没测试3：操作：罚没；预期：质押池总额大于0，有可罚没资产<br>
19. 安全测试1：操作：用户操作函数；预期：防重入函数生效，嵌套调用全部拦截<br>
20. 安全测试2：操作：管理员暂停函数；预期：函数生效，暂停后所有质押/解质押/领奖励/罚没/注入奖励全部冻结，解除暂停业务恢复正常<br>
21. 安全测试3：操作：与地址相关的函数；预期：拦截所有0地址<br>
22. 安全测试4：操作：转账；预期：余额不足，进行revert， 无静默<br>
23. 事件测试：操作：进行函数操作；预期：相关事件触发并完整记录信息<br>
24. 异常测试：操作：gas不足无法操作；预期：交易失败，回滚<br>
25. 安全测试5：操作：管理员在 RateLimit 窗口（86400 区块）内向时间锁连续提交≥4 条高危提案（slash/setFeeRecipient 等）；预期：提交第 4 条提案时直接 revert，无法创建提案；窗口内最多允许提交 3 条提案；提案到期执行动作不受该频率计数约束。<br>
26. 安全测试6：操作：调用 slash，传入亏损金额 > 500 WETH，预期：revert操作<br>
27. 安全测试7：操作：直接调用transferOwnership () /setFeeRecipient () /setDepositLimit () /setRewardFeeRate () /slash/ depositReward ()，预期： 不允许直接调用，交易 revert，必须提交提案走时间锁调度，等待窗口期结束后方可执行<br>
28. 安全测试8：操作：管理员调用pause ()、unpause ()，预期 不触发timelock()<br>
29. 空池注入测试 1：操作：totalShares=0 时调用 depositReward；预期：奖励进入 bufferReward，不进入 rewardPool，不参与分红，totalAssets 不变<br>
30. 空池注入测试 2：操作：空池多次调用 depositReward；预期：bufferReward 累计累加，rewardPool 仍为 0<br>
31. 缓冲区迁移测试：操作：空池注入奖励后，首个用户执行质押；预期：bufferReward 全部转入奖励池，bufferReward 清零，触发 BufferRewardMigrated 事件，迁移后奖励从当前区块参与分红<br>
32. 缓冲区不可提取测试：操作：管理员尝试调用任何接口提取 bufferReward；预期：不存在该接口，无法提取<br>
33. 缓冲区不计入总资产测试：操作：空池注入奖励后查询 totalAssets；预期：totalAssets 仅含质押本金，不含 bufferReward<br>
34. 份额铸造测试1：操作：每次 deposit（质押）都强制使用这个铸造公式；预期：有使用这个公式<br>
35. 份额铸造测试2：操作：已有 slash 罚没后，新用户质押，验证有效份额等于存入本金，不会被历史罚没缩水；预期：新质押份额不被历史罚没影响<br>
36. 罚没测试4：操作：存在 slash 快照；用户 claimReward；预期：奖励分段计算，快照前区间使用快照 slashFactor，快照后区间使用最新 slashFactor；无需遍历所有用户<br>
37. 安全测试9：操作：管理员提交 setFeeRecipient /setDepositLimit 提案到时间锁；预期：提案进入等待窗口期（7天）；窗口期未到执行则 revert；窗口期结束后可执行，状态变更触发事件<br>
38. 安全测试10：操作：管理员尝试直接调用 setDepositLimit 调高单次金额上限，不经过时间锁，随后立刻执行 slash；预期：参数修改调用直接 revert；参数修改必须提交时间锁提案，等待 7 天窗口；窗口期内参数维持原值，无法即时调高限额来绕过 slash 金额限制<br>
39. 安全测试11：操作：Gnosis 多签钱包提交合法 slash 罚没提案至时间锁；预期：提案进入等待窗口期（7 天）；窗口期未到执行则 revert；窗口期结束后可正常执行罚没逻辑、更新 slashFactor 与 totalAssets，触发对应事件<br>
40. 安全测试12：操作：普通外部账户（非 Gnosis 多签 owner）尝试向时间锁提交 slash 提案；预期：提案提交校验失败，直接 revert，无法创建时间锁提案<br>
41. 安全测试13：操作：Gnosis 多签钱包提交 slash 提案，提案内亏损金额超过 SLASH_MAX_RATIO 上限；预期：窗口期到期执行时交易 revert，不执行罚没、状态无变更<br>

### 验收标准
1. 以上测试全部通过<br>
2. 合约正确继承OpenZeppelin函数<br>
3. 自定义函数修饰器逻辑运行正常、校验生效<br>
4. 所有状态变更操作均正常触发对应链上事件<br>
5. 合约实现安全合规<br>
6. 代码gas开销优化到位、执行高效<br>
