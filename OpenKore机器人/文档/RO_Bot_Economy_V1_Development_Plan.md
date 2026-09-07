# RO Bot 经济系统 V1：分阶段实验与开发计划

> 修订日期：2026-09-06。本文已结合当前本地服、OpenKore 配置、`world_ai`、`autoGear`、rAthena Trade/Vending 限制进行可执行性校正。

## 1. 目标

当前服务器已经具备以下能力：

- 多个 OpenKore Bot 可自动打怪
- Bot 可拾取战利品
- Bot 可根据条件回城
- Bot 可向 NPC 出售物品
- Bot 可补给后重新进入练级流程
- world_ai 已开始承担选怪、选图、移动等决策

下一阶段目标不是一次性实现完整市场，而是先构建一个最小、真实、可验证的经济闭环：

```text
怪物掉落
  ↓
战斗 Bot 获得战利品
  ↓
回城分类物品
  ├─ 垃圾 → NPC
  └─ 卡片 / 装备 / 有价值物品 → 商人 Bot
                                   ↓
                               支付 Zeny
                                   ↓
                               商人库存
                                   ↓
                                摆摊
                                   ↓
                           玩家 / 其他 Bot 购买
```

第一版只需要证明：

> 一件真实掉落的物品，能够从怪物 → 战斗 Bot → 商人 Bot → 摊位 → 买家，完整走完一次经济循环。

---

# 2. 总体开发原则

本阶段必须坚持以下原则：

1. **优先使用 RO / OpenKore 已有真实机制**
   - NPC Sell
   - Trade
   - Cart
   - Vending
   - Zeny 转移

2. **不要直接改数据库转移物品**
   - 避免在线角色内存状态与数据库不同步
   - 避免复制物品
   - 保留“机器人真实生活在 RO 世界里”的行为

3. **不要一开始做动态价格**
   - 第一版价格允许写死
   - 第一版目标是验证经济链路，不是构建价格模型

4. **每个实验只验证一个问题**
   - 不要一次改多个系统
   - 每一步都必须有清晰日志
   - 每一步都必须能单独验收

5. **失败时必须能安全恢复**
   - Trade 取消不能卡死
   - 商人离线不能卡死战斗 Bot
   - 商人没钱不能产生凭空 Zeny
   - 库存满必须有明确 fallback

6. **默认保留，NPC 出售必须使用白名单**
   - 无法识别的物品一律 `KEEP`
   - `ETC` 不是“垃圾”的同义词，其中可能包含任务材料、驯养物、制作材料和特殊货币
   - 物品判定以 `nameID`、rAthena 物品类型和装备位置为准，显示名称只用于日志

7. **只有一个物品策略来源**
   - NPC 出售、Merchant 收购和摆摊不能分别维护互相冲突的规则
   - 分类器和固定价格表应由 Combat Bot 与 Merchant Bot 共享
   - Merchant 的实际报价是交易时的最终权威结果

8. **先验证协议能力，再开发自动状态机**
   - 先手工验证 Trade、Zeny、Cart 和 Vending 封包链路
   - 能力探针未通过前，不进入对应自动化阶段

---

# 3. 阶段 0：冻结当前基线

## 实验 0.1：记录当前回城卖货流程

### 目的

明确经济系统应该插入哪里。

### 需要定位

找到当前代码中：

- 什么条件触发回城
- 哪段代码决定向 NPC 卖什么
- 哪段代码执行 NPC Sell
- 卖完后如何补给
- 补给完成后如何重新进入 world_ai
- `items_control.txt`、运行态配置和 README 是否一致
- 哪些装备当前被显式配置为 NPC Sell
- `world_ai` 在 `deal` 或自定义 economy 状态期间是否仍会重新选图 / 移动

### 目标流程

当前大概应为：

```text
打怪
→ 拾取
→ 背包达到条件
→ 回城
→ NPC 卖货
→ 补给
→ world_ai 重新选图 / 选怪
```

### 验收

这一阶段不修改行为。

只需要输出一份日志或代码路径说明，例如：

```text
[BASELINE]
return_to_town: xxx.pm / xxx.cpp / xxx plugin
npc_sell_entry: ...
after_sell_resume: ...
```

同时记录一份“实际策略快照”，不能只引用文档描述。当前基线已经默认保留未列出的物品，且部分卡片受到保护；但仍存在部分重复装备被显式卖给 NPC 的规则。阶段 0 必须先把真实运行行为、版本化配置和 README 的差异列清楚。

---

# 4. 阶段 1：先阻止有价值物品被 NPC 卖掉

## 实验 1.1：只保护卡片

### 目标

任何 Card 类型物品都禁止进入 NPC Sell。

注意：当前系统并非从零开始。已有配置对未列出的物品默认保留，并显式保护了部分卡片。本实验的目标是验证“所有真实 Card 类型”都受到类型级保护，而不是只追加若干卡片名称。

### 示例

背包：

```text
Jellopy x30
Wolf Claw x15
Rocker Card x1
```

预期：

```text
Jellopy      → NPC
Wolf Claw    → NPC
Rocker Card  → 保留
```

### 日志

```text
[ECO][CLASSIFY] Rocker Card → MERCHANT_SELL
[ECO][NPC] skip Rocker Card
```

### 验收标准

- 普通垃圾仍可正常出售
- 卡片不会被 NPC 卖掉
- 不影响补给与回练级流程

---

## 实验 1.2：保护装备

加入：

- Weapon
- Armor
- Accessory

第一版暂时全部保留。

需要先移除或覆盖当前 `items_control.txt` 中会出售部分重复武器、防具的旧规则。不能只在分类器里打印 `MERCHANT_SELL`，却让原生 `sellAuto` 仍按旧表出售。

以下物品始终不得进入 Trade：

- 当前已装备物品
- 已锁定或不可交易物品
- `autoGear` 选中的当前升级品
- 无法可靠识别的自定义装备
- 策略明确要求保留的起步装备

### 预期

```text
垃圾 / 普通材料 → NPC
卡片             → 保留
装备             → 保留
```

### 验收

至少测试：

- 普通武器
- 带孔武器
- 防具
- 卡片

---

# 5. 阶段 2：建立独立经济分类器

## 实验 2.1：实现 classify_item()

建议新增独立逻辑，例如：

```text
classify_item(item)
```

返回：

```text
NPC_SELL
MERCHANT_SELL
KEEP
CONSUME
UNKNOWN
```

第一版规则可极简：

```text
CARD       → MERCHANT_SELL
WEAPON     → MERCHANT_SELL
ARMOR      → MERCHANT_SELL
ACCESSORY  → MERCHANT_SELL（按装备位置识别，不假设它是独立 item type）
NPC_ALLOWLIST → NPC_SELL
USABLE     → KEEP
QUEST / TAMING / CRAFT / CURRENCY → KEEP
UNKNOWN    → KEEP
```

注意：

- 不要立即引入复杂价格判断
- 不要立即判断“好装备 / 坏装备”
- 暂时宁可多留，也不要误卖稀有物品
- NPC Sell 必须是显式 `nameID` 白名单；不能把所有 `ETC` 直接当垃圾
- 与 `autoGear` 的执行顺序固定为：先评估 / 换装，再分类剩余物品

### 第一阶段只打印结果，不执行交易

```text
[ECO][CLASSIFY] Rocker Card      → MERCHANT_SELL
[ECO][CLASSIFY] Jellopy          → NPC_SELL
[ECO][CLASSIFY] Main Gauche [4]  → MERCHANT_SELL
```

### 验收

分类器与 NPC Sell 行为解耦。

必须增加离线单元测试，至少覆盖：

- 普通垃圾白名单
- Card
- 已鉴定 / 未鉴定装备
- 带孔、精炼、插卡装备
- 已装备物品和 `autoGear` 保留品
- 驯养物、药水、任务材料、特殊货币
- 未知 `nameID`

---

## 实验 2.2：前置协议能力探针

> 执行状态（2026-09-06）：已通过。实测并修复 OpenKore 对 PACKETVER 20211103 的 0x0B42 对端报价接收映射；请求、接受、物品、Zeny、锁定、最终确认、取消、单方掉线回滚和重登持久化均通过。等待 30 秒不会自动取消，因此后续自动状态机必须实现显式 watchdog。详细证据见项目内 OpenKore机器人/文档/ECONOMY_V1_STAGE2_TRADE_PROBE.md。

在编写自动交易状态机之前，先使用两个现有 Bot 做最小手工验证；此实验不依赖 Merchant 角色。

依次验证：

```text
Bot A 请求 Trade
→ Bot B 接受
→ A 放入一件可交易物品
→ B 放入固定 Zeny
→ 双方锁定并完成
→ 核对物品、Zeny
→ 双方重登后再次核对
```

还必须单独验证取消、超时、其中一方掉线。任何一项不稳定时，应先修复协议或 OpenKore 处理问题，不继续开发自动报价。

### 验收

- Trade 请求、接受、加物、加 Zeny、锁定、最终确认的封包链路全部可用
- 服务端失败时保持原子性，不出现只扣钱或只移物
- OpenKore 能收到明确的完成 / 取消事件
- 记录当前单笔 Trade 最多 10 个物品条目的限制

---

# 6. 阶段 3：建立中央商人 Bot

## 实验 3.0：完成 Merchant 一次性引导准备

当前启动和部署脚本只管理 `bot01`～`bot05`，而且本组合的角色创建协议尚未稳定。新增中央商人前，必须先定义并完成以下一次性准备：

1. 增加 `bot06` 实例、凭据模板、日志目录、部署和启停 / 状态查询支持。
2. 创建角色；若仍需按现有方式由数据库创建，只允许用于角色初始化，禁止用 SQL 搬运经济物品或模拟日常交易。
3. 转职 Merchant，并准备最低技能链：

```text
Increase Weight Limit 5
→ Pushcart 3
→ Vending 10
```

共需要 18 个 Merchant 技能点，即至少 Job 19。完成这次引导后，Merchant 才进入“不自动练级”的常驻模式。

4. 通过真实 NPC 机制租用 Cart，验证重登后的 Cart 和 Cart 库存状态。
5. 禁用 `world_ai`、自动攻击、随机行走和普通练级配置。

### 验收

- `start / stop / restart / status / deploy-config` 均包含 bot06
- Merchant 可稳定登录并停在指定会合点
- 具备 Cart 和 Vending 10，能手工打开 1 件及 12 件商品的摊位
- Merchant 重登后不会被默认配置带离首都

## 实验 3.1：商人驻扎 Prontera

新增一个专职 Merchant Bot。

第一版要求非常简单：

```text
登录
→ 前往 Prontera 指定区域
→ 停留
```

例如：

```text
prontera 150 180
```

坐标必须经过真人客户端检查，确认不是传送点、NPC、其他固定摊位或阻挡位置。Combat Bot 不应在全地图按名称搜索 Merchant，而应前往固定会合坐标，再从可见 Actor 中按精确角色名确认身份。

### 商人第一版禁止

- 自动练级
- 自动选图
- 主动打怪
- 离开首都
- 复杂经济决策

它只是一个固定的经济节点。

---

## 实验 3.2：给商人真实初始资本

例如：

```text
merchant_initial_cash = 5,000,000z
```

必须是真实角色 Zeny。

推荐由管理员角色通过一次真实 Trade 提供启动资金，并在基线记录中注明来源。不要通过插件修改内存数值，也不要在日常流程中使用 SQL 充值。若确需初始化 SQL，必须明确记为一次性经济注入，而不能把它当作交易机制。

### 验收

- 重登后资金正常
- Trade 支付会真实减少
- 不允许通过插件“凭空支付”而不扣余额
- 资金来源、注入时间和初始余额有审计记录

---

# 7. 阶段 4：第一次真实 Bot ↔ Bot Trade

这是第一个关键里程碑。

## 实验 4.1：手动触发 Trade

实验 2.2 已验证通用 Trade 能力；这里进一步使用准备好的 Merchant 角色验证身份、职业配置和真实资金变化。

准备：

```text
CombatBot:
Rocker Card x1

MerchantBot:
Zeny >= 10,000
```

手动触发：

```text
CombatBot → Trade MerchantBot
```

交易内容：

```text
CombatBot 放：
Rocker Card x1

MerchantBot 放：
10,000z
```

交易完成后：

```text
CombatBot:
Rocker Card -1
Zeny +10,000

MerchantBot:
Rocker Card +1
Zeny -10,000
```

### 验收

必须验证：

- 物品真实转移
- Zeny 真实转移
- 双方库存同步
- 重登后状态一致
- Merchant 正在 Vending、与 NPC 对话、开仓库或已进入另一笔 Trade 时，请求会明确失败
- 非白名单角色无法触发自动接单

---

# 8. 阶段 5：第一次全自动收购

## 实验 5.1：固定价格收一张 Card

不要做价格模型。

第一版：

```text
ANY_CARD_BUY_PRICE = 10,000z
```

### Combat Bot 行为

```text
发现 MERCHANT_SELL 物品
→ 前往固定会合点
→ 按精确角色名确认 MerchantBot
→ 使用带 nonce 的私聊发送 SELL_REQUEST
→ 收到 Merchant READY
→ 发起 Trade
→ 放入 Rocker Card
→ 等待服务端回显
→ 核对 Merchant 放入的 Zeny
→ 仅在报价完全正确时锁定和最终确认
```

### Merchant Bot 行为

```text
收到 Trade
→ 校验卖家精确角色名、距离和当前 nonce
→ 检测服务端回显的 Rocker Card nameID / amount
→ 估值 10,000z
→ 放入 10,000z
→ 等待卖家锁定
→ 确认交易
```

第一版只接受配置中明确列出的 Combat Bot。不能把 `dealAuto` 设置为接受所有玩家，也不能只凭聊天文本认定对方身份。

Trade 的完成判定必须来自服务端完成事件以及交易后库存 / Zeny 快照，不能以“已发送最终确认封包”当作成功。

### 验收

完全无人操作完成一笔交易。

日志建议：

```text
[ECO][SELLER] request merchant trade
[ECO][TRADE] tx=... offered nameID=... item=Rocker Card amount=1
[ECO][BUYER] tx=... quote total=10000z
[ECO][TRADE] tx=... completed
```

### 自动确认安全规则

- Merchant 拒绝不在收购策略内、不可交易或数量异常的物品
- Merchant 在报价前重新检查实际 Zeny、背包空格和可承重
- Combat Bot 在最终确认前检查对方名称和实际 Zeny
- 任一方看到交易内容在锁定前发生变化，应取消整笔交易
- 超时、取消或掉线只记录失败，不修改本地经济余额

---

# 9. 阶段 6：多物品交易

## 实验 6.1：一次出售多个物品

例如：

```text
Rocker Card
Yoyo Card
Main Gauche [4]
Guard [1]
```

第一版允许固定估值：

```text
Rocker Card      10,000z
Yoyo Card        20,000z
Main Gauche [4]   3,000z
Guard [1]         5,000z
```

合计：

```text
38,000z
```

OpenKore 和当前 rAthena 的普通 Trade 单笔最多 10 个物品条目。数量堆叠不等于物品条目；非堆叠装备通常各占一项。

第一版策略：

```text
待售条目 <= 10 → 单笔交易
待售条目 > 10  → 按确定顺序拆成多批，每批最多 10 项
```

每批使用独立 `tx_id`，独立报价、确认和验收。上一批收到服务端成功事件后才能开始下一批；中间失败时，未交易条目继续保留。

### 验收

- 商人正确计算总价
- Trade 中 Zeny 正确
- 所有物品完整转移
- 不重复计价
- 交易失败不会重复付款
- 10、11、20、21 个条目的拆批边界正确
- 同一 `nameID` 的多个库存实例及堆叠数量不会漏算或重复算

---

# 10. 阶段 7：接入现有回城流程

这是第二个关键里程碑。

## 实验 7.1：完整自动流程

将原本：

```text
回城
→ NPC Sell
→ 补给
→ 回练级地图
```

改成：

```text
回城
→ economy 取得流程控制权，暂停 world_ai 新任务
→ classify_inventory()
→ NPC 卖 NPC_SELL
→ 完成药水 / 箭矢补给
→ 检查 MERCHANT_SELL
→ 前往 MerchantBot
→ Trade
→ economy 释放控制权
→ world_ai 恢复运行并重新选图
```

补给应在离开现有 Prontera 室内工具商人前完成，避免去室外交易后再次折返。若最终把 Merchant 会合点设在室内，则仍应明确一次固定顺序。

### 与 world_ai / autoGear 的控制权约定

- `world_ai` 的忙碌判定必须加入 `deal` 和 economy 自定义状态
- economy 启动前等待当前攻击 / 技能动作进入安全边界，不在战斗中强行 Trade
- economy 持有控制权时，`world_ai` 不得更新 `lockMap` 或启动新路线
- `autoGear` 先完成装备评估；进入 Trade 后继续沿用其现有 `deal` 忙碌保护
- 成功、拒绝、超时、取消、掉线和插件卸载都必须走同一个清理函数，且只恢复一次

### 真实测试

让 Combat Bot：

```text
野外打怪
→ 爆出装备 / Card
→ 背包达到回城条件
→ 自动回城
→ 卖垃圾
→ 完成补给
→ 找商人
→ 卖有价值物品
→ 获得 Zeny
→ 再次出城
```

### 验收

全过程无需人工输入。

若 Merchant 离线或交易失败：

```text
保留 MERCHANT_SELL 物品
→ 本轮不再卖给 NPC
→ 若负重低于恢复练级安全线，则记录 DEFERRED 并继续练级
→ 若仍然过重，则停留在城内安全点等待下一次重试
```

禁止在“前往 Merchant → 失败 → world_ai 出城 → 立即因负重回城”之间形成死循环。

---

# 11. 阶段 8：异常处理

在摆摊之前必须先稳定收货。

## 实验 8.1：商人资金不足

若：

```text
merchant_zeny < purchase_total
```

必须：

```text
拒绝交易
```

允许以后扩展：

```text
部分收购
```

第一版建议直接拒绝。

拒绝发生在双方锁定前，并附带可观察的原因和下一次允许重试时间；Combat Bot 不应立即无限重试。

禁止：

```text
余额不足但仍支付
```

---

## 实验 8.2：商人 Inventory / Cart 容量不足

普通 Trade 先把商品放进 Merchant 的人物 Inventory，而不是直接进入 Cart。因此报价前必须分别检查：

- 人物 Inventory 空格
- 人物当前重量和交易后重量
- Cart 空格、堆叠上限和重量
- 收货后从 Inventory 搬入 Cart 是否可完成

如果无法安全接收并入库：

```text
[ECO][BUYER] INVENTORY_FULL
```

Combat Bot：

- 保留物品
- 不丢弃
- 不卖 NPC
- 按阶段 7 的 `DEFERRED / 城内等待` 策略结束本轮

---

## 实验 8.3：多个卖家同时到达

建立卖家队列：

```text
seller_queue:
1. Bot02
2. Bot03
3. Bot04
```

商人同一时间只服务一个卖家。

V1 使用游戏内真实通信完成排队：卖家到达固定会合点后，通过私聊发送带 nonce 的 `SELL_REQUEST`。Merchant 仅响应精确角色名白名单，并在该角色确实位于交易距离内时入队。重复 nonce 不得重复入队。

状态例如：

```text
IDLE
QUEUED
TRADING
```

### 验收

两个 Bot 同时来卖货时：

- 不发生交易冲突
- 不丢物品
- 不重复付款
- 第二个 Bot 可以正常等待
- 重复请求不会生成重复队列项
- 卖家离开、掉线或等待超时会自动出队

---

## 实验 8.4：Trade 中断恢复

测试：

- Combat Bot 掉线
- Merchant Bot 掉线
- Trade 被拒绝
- Trade 被取消
- 角色移动
- 超时
- 网络中断

任何失败必须最终回到安全状态：

```text
SELLER_IDLE / SELLER_DEFERRED
MERCHANT_IDLE / MERCHANT_VENDING
```

不能永远卡在：

```text
WAIT_TRADE
TRADING
WAIT_CONFIRM
```

建议增加 timeout。

不能把进程内状态当成资产账本。OpenKore 重启后应从服务端 Inventory、Cart、Zeny 和 Vending 状态重新构建状态；不允许因为本地记录曾处于 `WAIT_CONFIRM` 就补发付款或假定交易已经完成。

### 验收补充

- 对每种中断都核对双方交易前后 Inventory、Cart 和 Zeny
- 同一个 `tx_id` 不会在失败恢复后重复付款
- 插件卸载或重载能够释放 world_ai 控制权
- Merchant 重启后能重新整理 Inventory → Cart，并按实际资产恢复摆摊

---

# 12. 阶段 9：第一次自动摆摊

到这里才开始碰 Vending。

## 实验 9.1：只卖一种商品

商人收到：

```text
Rocker Card x1
```

然后：

```text
交易物品先进入 Merchant Inventory
→ 校验实际收到的 nameID / amount
→ 原生 Cart 操作搬入 Cart
→ Vending
```

只摆：

```text
Rocker Card 20,000z
```

### 验收

用真人角色购买。

买完后：

```text
MerchantBot:
Rocker Card -1
Zeny +20,000
```

还必须验证：

- Vending 使用真实 `MC_VENDING` 技能和已租用 Cart，不利用绕过技能的开店方式
- 开店商品数量不超过 `2 + Vending 技能等级`，当前默认上限为 12
- 售出事件、Cart 数量和 Zeny 三者一致
- 商品未售出时重开摊不会复制或丢失
- Merchant 接近 Zeny 上限时拒绝继续挂出会造成溢出的商品

---

# 13. 第一个完整经济闭环

实验 9.1 成功意味着：

```text
怪物
↓
Combat Bot
↓
Merchant Bot
↓
Vending
↓
真人玩家
```

已经完整成立。

这是 Economy V1 最重要的里程碑。

这里的“完整闭环”仍包含一次真人购买触发，因此表示链路可重复验证，不表示市场已经完全无人化。其他 Bot 自动消费属于 Economy V2/V3。

---

# 14. 阶段 10：摆摊 / 收货状态机

因为角色摆摊时不能同时进行普通 Trade，所以需要状态切换。

建议 Merchant 状态：

```text
MERCHANT_IDLE
MERCHANT_VENDING
MERCHANT_STOPPING_VENDING
MERCHANT_BUYING
MERCHANT_RESTOCK
MERCHANT_ERROR
```

基本流程：

```text
VENDING
  ↓
收到 SELL_REQUEST
  ↓
关闭摊位并等待服务端确认
  ↓
BUYING
  ↓
处理 seller_queue
  ↓
RESTOCK
  ↓
重新摆摊
```

---

## 实验 10.1：摆摊过程中有人来卖货

初始：

```text
MerchantBot = VENDING
```

Combat Bot 回城并申请出售。

预期：

```text
CombatBot:
SELL_REQUEST
    ↓
MerchantBot:
关闭摊位
等待 shop closed 事件
    ↓
向队首卖家回复 READY
    ↓
接受 Trade
    ↓
收购
    ↓
按服务端实际资产更新库存
    ↓
重新开摊
```

### 验收

全过程自动完成。

- 摊位未确认关闭前不接受 Trade
- 处理队列期间不在每个卖家之间反复开关摊位
- 队列清空或达到本轮服务上限后才重新整理 Cart 并开摊
- 开摊失败时进入可重试的 `MERCHANT_ERROR`，不清空真实库存

---

# 15. Economy V2 候选：扩大摆摊数量

这一阶段不属于 Economy V1，不能成为 V1 验收的阻塞项。

12 个商品槽已经足够验证 Economy V1。

完整经济闭环稳定后，再改：

```text
12 → 20
```

成功后再：

```text
20 → 30
```

---

## 实验 11.1：服务端支持更多 Vending 项目

需要检查：

- `MAX_VENDING`
- Vending 技能等级限制
- Vending 开店校验
- 相关数组大小
- 封包长度

---

## 实验 11.2：OpenKore 支持 30 个商品

确认：

- 能构造 30 项商店
- 能正确收到商店内容
- 能重新开店
- 不发生数组越界

---

## 实验 11.3：客户端显示测试

真人客户端验证：

- 是否显示 30 件
- 是否可以滚动
- 是否能点击购买
- 是否价格错位
- 是否商品错位
- 是否崩溃

如果 30 有问题：

```text
退回 20
```

不要为了数字强改客户端。

---

# 16. Economy V2 候选：库存与货架分离

如果 Vending 最终设置为 30：

```text
Cart:
最多约 100 个库存槽

Vending:
最多 30 个展示槽
```

形成：

```text
总库存
  ↓
货架选择
  ├─ 当前展示
  └─ 后台库存
```

例如：

```text
总库存：72 种
当前摆摊：30 种
后台库存：42 种
```

第一版货架选择可以非常简单：

优先级：

```text
CARD
RARE_EQUIPMENT
SLOTTED_EQUIPMENT
NORMAL_EQUIPMENT
MATERIAL
```

后续再加入销量。

---

## 16.1 公会仓库作为中央仓库的候选方案

公会仓库不纳入 Economy V1。V1 的热库存继续由 Merchant 的人物 Inventory 和 Cart 承担，先证明 Trade 与 Vending 闭环稳定。

Economy V2 可以把公会仓库用于“冷库存 / 溢出库存”，推荐结构：

```text
Combat Bot
→ 真实 Trade 给 Merchant，并收到 Zeny
→ Merchant 将当前货架商品留在 Cart
→ Merchant 将暂不展示的溢出商品存入公会仓库
→ 需要补货时再由 Merchant 取回 Cart
```

不建议让 Combat Bot 直接把待售物品存入公会仓库来代替 Trade，因为“交货”和“付款”会变成两个独立动作，掉线时难以保证原子性，也会削弱本计划要验证的真实经济交易。

### 引入前必须验证

- 所有相关角色的公会成员身份和仓库权限
- OpenKore 对当前服务端公会仓库存取封包的兼容性
- NPC / 仓库对话失败、仓库满、角色掉线后的恢复
- 同一时间只允许一个物流执行者操作仓库，避免并发抢占
- 存入和取出后以服务端 Inventory / Guild Storage 回显核对数量
- 已插卡、精炼、随机属性或不可交易装备的完整属性不会在物流判断中丢失

### 权限建议

- Combat Bot：不直接从公会仓库提款或取货
- Merchant / 专职 Logistics Bot：拥有存取权限
- 公会仓库只保存实物，不承担价格、欠款或交易完成状态
- 所有操作继续使用真实游戏机制，禁止 SQL 直接搬运物品

只有当 Merchant 的 Cart / Inventory 容量成为经过日志证实的实际瓶颈时，才启动这一方案。

---

# 17. Economy V2 候选：真正的价格系统

这一阶段属于 Economy V2，不属于最小闭环。

未来可以建立：

```text
item_price =
base_price
× rarity_factor
× demand_factor
× inventory_factor
× sales_factor
```

考虑：

- NPC 价值
- Monster 掉率
- 当前库存
- 历史销量
- 最近成交速度
- 玩家等级分布
- 职业需求
- 装备强度
- Slot
- 精炼等级
- Card 状态

---

## 可逐步实现的简单动态规则

### 库存积压

```text
库存很多
→ 售价下降
```

### 库存稀缺

```text
库存少
→ 售价提高
```

### 销售速度快

```text
近期快速售出
→ 涨价
```

### 长期无人购买

```text
长期未售出
→ 降价 / 清仓
```

---

# 18. 后续：让其他 Bot 成为消费者

这是 Economy V2/V3 最关键的一步。

以后可以让战斗 Bot 判断：

```text
我的武器是否太差？
```

然后：

```text
检查 Merchant 店铺
↓
发现更好的装备
↓
计算提升
↓
判断价格
↓
是否值得购买
```

形成：

```text
Combat Bot
  ↓ 打怪
生产商品
  ↓
Merchant
  ↓
其他 Combat Bot
  ↓
购买装备
  ↓
战斗效率提升
```

这时服务器经济才真正开始拥有：

- 生产者
- 批发 / 零售者
- 消费者

---

# 19. 推荐里程碑

## Milestone A：Bot 知道什么不能卖 NPC

包含：

```text
实验 0
实验 1
实验 2
```

完成标准：

> 卡片和装备不会再被错误卖给 NPC。

同时要求：未知物品默认保留，现有 `items_control.txt` 与分类器不再出现相互冲突的出售结论。

---

## Milestone B：Bot ↔ Merchant 真实交易

包含：

```text
实验 3
实验 4
实验 5
实验 6
实验 7
实验 8
```

完成标准：

> 战斗 Bot 能在无人操作情况下，将战利品真实卖给 Merchant Bot 并获得 Zeny。

这是下一阶段最优先目标。

---

## Milestone C：形成真正市场

包含：

```text
实验 9
实验 10
使用当前默认 12 格 Vending
```

完成标准：

> 商人能够收购、入库、摆摊，真人或其他 Bot 可以购买。

扩大到 20/30 格、冷库存货架、公会仓库自动物流和动态价格均属于 Economy V2 候选，不阻塞 V1 完成。

---

# 20. 第一轮开发不要做的内容

当前阶段明确禁止提前实现：

- 多商人竞争
- 商人跨城
- 拍卖系统
- 动态市场指数
- 大规模数据库统计
- AI 自动评估所有装备
- 新建另一套复杂自动换装逻辑（保留并兼容现有 `autoGear`）
- 复杂价格预测
- SQL 直接跨角色搬运物品
- 改动当前默认 12 格 Vending 上限
- 公会仓库自动物流（方案见 16.1，待容量成为实际瓶颈后再启用）
- 商人自动练级
- 全职业经济行为

这些都可以后续加。

---

# 21. 推荐的第一个真正开发 Sprint

按以下顺序执行：

```text
1. 冻结实际基线，核对 README、模板和运行态出售规则
2. 用两个现有 Bot 做手工 Trade / Zeny / 取消 / 重登能力探针
3. Card 和 Equipment 禁止进入 NPC Sell；NPC Sell 改为 nameID 白名单
4. 实现并离线测试 classify_item()
5. 新建 bot06，完成 Merchant 职业、Vending 10、Cart 和启动资金引导
6. 将 bot06 纳入部署、启停和状态查询，固定驻扎 Prontera
7. 使用 Merchant 再做一次手工 Trade 和一件商品手工 Vending
8. 实现卖家 / 买家状态机，自动完成一张 Rocker Card 的收购
9. 验证超时、拒绝、容量不足和 world_ai 控制权释放
```

Sprint 完成后的目标画面：

```text
CombatBot 打怪
   ↓
获得 Rocker Card
   ↓
回 Prontera
   ↓
卖垃圾给 NPC
   ↓
补充药水 / 箭矢
   ↓
找到 MerchantBot
   ↓
自动 Trade
   ↓
Merchant 支付 10,000z
   ↓
CombatBot 回练级地图
```

只要这一条跑通，下一步再做：

```text
Merchant Cart
→ Vending
→ 真人购买
```

---

# 22. 推荐日志格式

统一使用：

```text
[ECO][CLASSIFY]
[ECO][SELLER]
[ECO][BUYER]
[ECO][TRADE]
[ECO][QUEUE]
[ECO][VENDING]
[ECO][PRICE]
[ECO][ERROR]
```

例如：

```text
[ECO][CLASSIFY] Rocker Card → MERCHANT_SELL
[ECO][SELLER] seller=bot02 merchant=merchant01
[ECO][TRADE] tx=... offer nameID=... item=Rocker Card amount=1
[ECO][BUYER] tx=... quote total=10000z inventory_ok=1 cart_ok=1
[ECO][TRADE] tx=... completed seller=bot02 buyer=merchant01
```

每笔交易日志必须包含：`tx_id`、双方角色名、`nameID`、数量、单价 / 总价、交易前后 Zeny、完成或失败原因。显示名称只用于阅读，不能作为唯一资产标识。

这样后续查问题会非常方便。

---

# 23. 第一版成功判定

Economy V1 只有满足以下条件才算完成：

- [ ] 卡片不会被 NPC 误卖
- [ ] 装备不会被 NPC 误卖
- [ ] 未知、任务、驯养、制作和特殊货币类物品默认保留
- [ ] Combat Bot 能前往固定会合点并按白名单身份确认 Merchant Bot
- [ ] Bot ↔ Bot Trade 可自动完成
- [ ] Zeny 是真实转移
- [ ] 单笔最多 10 个条目，超过时能安全拆批
- [ ] Merchant 资金不足时不会凭空付款
- [ ] Merchant 人物 Inventory 或 Cart 容量不足时不会接收超量商品
- [ ] Trade 失败可以恢复
- [ ] 多个卖家不会冲突
- [ ] Trade 期间 world_ai 不会抢占路线，结束后可以恢复
- [ ] Merchant 可以把收到的商品放入 Cart
- [ ] Merchant 使用真实技能和 Cart 自动 Vending，最多使用当前默认 12 格
- [ ] 真人玩家可以购买 Bot 生产的商品
- [ ] 商品售出后 Merchant 获得真实 Zeny
- [ ] 在真人购买触发下，整个闭环可以连续重复验证

最终链路：

```text
怪物
→ Combat Bot
→ Merchant Bot
→ Vending
→ 玩家 / Bot
→ Zeny 回到 Merchant
```

这就是机器人正式加入服务器经济活动的第一版骨架。
