# Economy V1 阶段 0：NPC Sell / 补给 / world_ai 基线

记录时间：2026-09-06（Asia/Hong_Kong）

## 1. 阶段结论

阶段 0 已完成，只做了只读检查和文档固化，没有改变 Bot 行为或运行态配置。

当前真实流程是：

```text
负重 >= 48% 或背包条目 >= 99
且背包中存在 items_control 判定为可出售的物品
→ OpenKore 清除当前移动 / 路线 / 攻击 / 拾取动作
→ 排入原生 sellAuto
→ 路由到 prt_in 126 76
→ Tool Dealer，NPC 步骤 s
→ 根据 items_control 生成 sellList
→ 发送真实 NPC Sell 封包
→ sellAuto 完成后自动排入 buyAuto
→ 在同一个 Tool Dealer 补充药水，Archer 还会补箭
→ buyAuto 结束
→ OpenKore 按当前 lockMap 恢复路线
→ world_ai 保留原执行目标并继续观察 / 控制
```

Economy V1 的正确插入位置不是“替换整个回城流程”，而是：

1. 在 `sellList` 形成前提供统一的安全分类结果。
2. 在 `AI_buy_auto_completed` 后、恢复练级路线前接入 Merchant 交货。
3. 在 Trade / economy 状态期间扩展 `world_ai` 的忙碌保护。

## 2. 冻结点

### Git 与关键源码

```text
repository HEAD: 4506554152c0b540340db13ddcb0d4ad925e04a0
branch: main
tracking: origin/main
阶段 0 开始时工作区：clean

items_control.txt SHA-256:
463bdd666772a43dbf42a7dc0abfe9c8609ffeb1bfd37751e42cdcb2904367eb

world_ai.pl SHA-256:
3e6ee69ae34cc0193cc35b574589e7c2994f3b80130f361855793dd41dae5cd4

autoGear.pl SHA-256:
6c396eb0559d9d4cf2c536684595253632915aff233dff15e2d24d6a32fe59ee
```

OpenKore 和 rAthena 运行源码位于仓库外：

```text
OpenKore:
/Users/wangtaizhi/Documents/Codex/2026-08-22/j/outputs/ro-local/openkore

rAthena:
/Users/wangtaizhi/Documents/Codex/2026-08-22/j/outputs/ro-local/rathena
```

在线日志确认当前 rAthena Git Hash 为：

```text
8702554f66b1f9043f965138bd51939985ade3b0
```

### 在线快照

2026-09-06 21:30（Asia/Hong_Kong）检查时：

- MariaDB、login-server、char-server、map-server 均运行中。
- Windows 11 VM 运行中。
- bot01～bot05 均在线，`world_ai_auto_execute 1`。
- 五个运行态 `items_control.txt` 与仓库版本逐字节一致。
- 五个实例的本节关键运行参数与各自版本化模板一致。

角色快照：

| Bot | 角色 | 职业 | Base / Job | 地图 | Zeny |
|---|---|---|---:|---|---:|
| bot01 | KoreHelper | Thief | 41 / 29 | prt_fild08 | 12,514 |
| bot02 | EthanRowe | Swordman | 41 / 30 | prt_fild08 | 21,917 |
| bot03 | MiraVale | Mage | 38 / 28 | mjolnir_09 | 16,481 |
| bot04 | CalebWren | Archer | 40 / 28 | pay_fild02 | 11,813 |
| bot05 | NoraEllis | Acolyte | 29 / 22 | pay_gld | 43 |

这些余额和位置只是检查时快照，不作为后续测试的固定前置条件。

## 3. 当前关键配置

五个 Bot 的公共值：

```text
itemsMaxWeight 89
itemsMaxWeight_sellOrStore 48
itemsMaxNum_sellOrStore 99

sellAuto 1
sellAuto_npc prt_in 126 76
sellAuto_npc_steps s
storageAuto 0

shopAuto_open 0
dealAuto 0
dealMaxItems 10
world_ai_auto_execute 1
```

补给：

- bot01、bot02、bot04、bot05：Red Potion ID 501，少于等于 10 时补到 30，单价基线 50z。
- bot03：Red Potion ID 501，`minAmount 9999 / maxAmount 30`；实际效果是低于 30 就尝试补到 30。
- bot04：Arrow ID 1750，少于等于 200 时补到 1000，单价基线 1z。
- `world_ai` 有低资金守卫：余额低于所需物品最低单价时阻止无意义的 buyAuto 循环。

## 4. 真实代码路径

### 4.1 回城 / 出售触发

OpenKore：

```text
src/AI.pm
  ai_sellAutoCheck()        约 505 行
  StorageSellBuy_aiClear()  约 654 行
  shouldStartAutoSell()     约 773 行
```

`shouldStartAutoSell()` 的真实条件：

```text
sellAuto 已开启
AND sellAuto_npc 已配置
AND (
  percent_weight >= itemsMaxWeight_sellOrStore
  OR inventory size >= itemsMaxNum_sellOrStore
)
AND ai_sellAutoCheck() 找到至少一项可卖物品
```

开始时 `StorageSellBuy_aiClear()` 会清除：

```text
move, route, attack, items_take, take, items_gather
```

然后排入 `sellAuto`。

### 4.2 决定卖什么

OpenKore：

```text
src/Misc.pm
  items_control()           约 3642 行

src/AI/CoreLogic.pm
  processAutoSell()         约 1835 行
  形成 sellList            约 1977 行
```

`items_control()` 的匹配优先级是：

```text
小写显示名称
→ nameID
→ all
→ 空规则
```

进入 `sellList` 的条件是：

```text
未装备
AND 服务端 / OpenKore 标记为 sellable
AND items_control.sell == 1
AND amount > items_control.keep
```

卖出数量为：

```text
amount - keep
```

重要影响：当前终端物品名主要显示为韩文，因此很多英文名称规则不会命中，会继续按 `nameID` 或 `all` 回退；如果以后切换物品名称表，英文名称规则可能优先于同一物品的数字 ID 规则。Economy 分类器不能依赖这一偶然行为，必须以 `nameID` 为主。

### 4.3 执行 NPC Sell

OpenKore：

```text
src/AI/CoreLogic.pm
  路由到 sellAuto_npc     约 1880～1953 行
  生成并提交 sellList     约 1977～1999 行

src/Misc.pm
  completeNpcSell()        约 6735 行

src/Network/Send.pm
  sendSellBulk()           约 2639 行
```

NPC Sell 使用真实 NPC 对话和批量出售封包，不直接改数据库。

### 4.4 卖完补给

`processAutoSell()` 完成后：

```text
AI::dequeue sellAuto
→ hook: AI_sell_auto_completed
→ AI::queue buyAuto { forcedBySell => 1 }
→ hook: AI_buy_auto_queued
```

随后 `processAutoBuy()` 按各实例的 `buyAuto` 槽位在同一 NPC 补给。当前 `storageAuto 0`，所以补给后不会进入仓库存取。

### 4.5 补给后恢复 world_ai

`buyAuto` 完成后会出队；由于当前 `storageAuto 0`，没有后续原生经济任务。OpenKore 随即按当前 `lockMap` 恢复路线。

正式 `world_ai`：

```text
OpenKore机器人/plugins/world_ai/world_ai.pl
  _transaction_in_progress() 约 282 行
  _advance_execution()       约 747 行
  on_ai_pre()                约 874 行
```

当 `world_ai` 的动态目标仍处于 ACTIVE / MOVING 时，原生卖货只是一次 detour。插件在日志中记录 `native_detour`，运行时 `lockMap` 覆盖仍保留；补给完成后原生路线返回该目标。

当前忙碌列表为：

```text
storageAuto, buyAuto, sellAuto, teleport, NPC, skill_use, eventMacro
```

这里尚未包含 `deal` 或未来的 economy 自定义状态，这是接入 Merchant 前必须补齐的控制边界。

`autoGear` 当前会在 action 匹配以下内容时暂停换装检查：

```text
attack, skill, npc, sell, buy, storage, deal
```

因此它已经具备基础 `deal` 避让，但 Economy V1 仍需确保 autoGear 在分类前先完成一次装备评估。

## 5. 实际物品策略快照

共享文件：

```text
OpenKore机器人/instances/shared-control/items_control.txt
```

按 OpenKore 解析语义统计当前最终键值：

```text
effective keys: 1644
sell = 1:       465
storage = 1:     10
keep-only:     1169
fallback all: all 0 0 0
```

结论：未列出物品默认不卖也不存，这是安全的；但当前规则绝不是 README 所描述的少量垃圾白名单。文件包含大量历史默认装备和材料出售规则。

已确认的例子：

```text
Jellopy (909)           → sell all
Clover (705)            → sell all
Sticky Mucus (938)      → sell all
Feather (949)           → sell all
Bill of Birds (925)     → sell all
Empty Bottle (713)      → sell all
Apple (512)             → keep 20, sell excess
Carrot (515)            → keep 10, sell excess

Guard（英文名称规则）    → keep 1, sell excess
Guard (2101, ID rule)   → keep all
Main Gauche（英文名称规则）→ sell all；当前韩文名下回退为 keep
Knife [4] (1202)        → sell all
Wand [2] (1604)         → sell all
Wand [3] (1605)         → sell all
Poring Card (4001)      → keep all
未匹配的 Card            → 由 all 0 0 0 回退，当前保持
```

由于名称匹配优先于 ID，同一物品存在名称规则与 ID 规则冲突时，最终结果可能随物品名称表语言改变。这是阶段 1 必须消除的隐患。

## 6. 历史实机证据

bot01 日志在 2026-09-05 18:43～18:46 记录了一次完整流程：

```text
18:43:44  Auto-selling due to itemsMaxWeight
18:43:46  route → prt_in 126 76
18:46:34  Ready to start selling items
18:46:37  移除 6 类物品，获得 14,235z
18:46:37  Auto-sell sequence completed
18:46:37  对同一 Tool Dealer 启动 buy
18:46:41  花费 1,500z，买入 30 Red Potion
18:46:43  Auto-buy sequence completed
18:46:43  重新计算当前 lockMap 路线
```

当次实际卖出的 6 类物品：

```text
Jellopy x191
Clover x2
Soft Fur x1
Bill of Birds x401
Empty Bottle x60
Sticky Mucus x18
```

它证明：

- 负重 48% 触发链路有效。
- NPC Sell 和 Zeny 增加是真实服务端行为。
- Sell 完成后会立即接 Buy。
- Buy 完成后会恢复 `lockMap` / `world_ai` 目标。
- README 的“当前出售范围”遗漏了实际会卖出的 Soft Fur、Bill of Birds、Empty Bottle 等物品。

历史日志未发现 `Did not received the sell result from server`。bot05 曾出现 2 次 `Npc did not respond`，其中一次随后立即重新触发卖货并成功，说明原生流程可以恢复，但 Economy 状态机仍应显式处理同类失败。

## 7. README / 配置差异

`OpenKore机器人/README.md` 当前描述：

- 出售范围只有 Jellopy、Clover、Sticky Mucus、Feather、超额 Apple / Carrot。
- Empty Bottle 和所有自有装备受保护。

真实配置与历史日志显示：

- 共有 465 个有效 `sell = 1` 键，不是六类物品。
- Empty Bottle ID 713 明确配置为出售，且实机确实卖出。
- 大量武器、防具和饰品名称规则被配置为出售；原生逻辑只天然跳过“当前已装备”的物品。
- 部分本地 ID 保护规则可能因名称优先级而被英文名称规则覆盖。

README 关于以下状态与运行配置一致：

- `sellAuto 1`
- `storageAuto 0`
- `dealAuto 0`
- `shopAuto_open 0`
- 自动 Trade 和 Vending 尚未开启

README 的出售范围应在阶段 1策略修改完成后再更新，避免先把目标状态写成当前状态。

## 8. Economy V1 插入建议

后续实现保持以下边界：

```text
原生触发条件和回城路由：保留
NPC 对话与真实 Sell 封包：保留
buyAuto 补药 / 补箭：保留

items_control 历史大表：收敛为明确 NPC 白名单
classify_item：新增，nameID 为主
AI_sell_auto：在最终 sellList 形成前做安全复核
AI_buy_auto_completed：作为 Merchant 交货入口候选
world_ai busy guard：加入 deal 和 economy 状态
```

不应在阶段 1直接修改 OpenKore 上游核心源码。优先把 Economy 逻辑放在仓库管理的独立插件 / 共享模块中，并通过现有 hook 接入；原生 `sellAuto` 继续负责路线、NPC 对话和封包发送。

## 9. 阶段 0 验收

- [x] 定位负重 / 背包数量触发条件
- [x] 定位物品出售决策来源和匹配优先级
- [x] 定位 NPC Sell 路由、对话和封包发送路径
- [x] 定位 Sell → Buy 串联路径
- [x] 定位 Buy 完成后恢复 `lockMap` / `world_ai` 的方式
- [x] 核对五个版本化模板与运行态关键配置
- [x] 核对五个运行态 `items_control.txt` 与仓库版本
- [x] 用历史实机日志验证一次完整卖货 / 补给 / 恢复链路
- [x] 记录 README 与真实策略差异
- [x] 全程未改变服务器或 Bot 行为

下一步是 Sprint 第 2 步：用两个现有 Bot 手工验证 Trade、Zeny、取消和重登能力。该步骤会涉及真实角色资产变化，执行前应选择测试物品、交易金额和参与 Bot，并记录交易前快照。
