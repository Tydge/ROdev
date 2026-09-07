# Economy V1 · 阶段 4（总计划）/ Sprint 7：Merchant 专项普通 Trade 验收

> 对应总计划 §7「阶段 4：第一次真实 Bot ↔ Bot Trade」实验 4.1。
> 注意与既有 `ECONOMY_V1_STAGE4_BUYING_STORE.md` 区分：后者是额外的收购店封包能力报告，
> 本文件才是总计划「阶段 4」的验收记录。

## 一、结论

通过。bot06（Cartwright，Merchant）与 bot07（Penny，Novice）完成一笔真实普通 Trade，
并修复了服务端拒绝交易后 OpenKore 残留「收到交易请求」状态导致后续交易被本地卡住的阻塞缺陷。

- 物品真实转移：Poring Card（4001）×1 从 Penny → Cartwright ✅
- Zeny 真实转移：1,000z 从 Cartwright → Penny ✅
- 双方库存同步：DB 与服务端回显一致 ✅
- 重登持久化：双方 relog 后物品 / Zeny 一致 ✅
- Merchant 忙碌拒绝：Cartwright 摆摊中，Penny 的 Trade 请求明确失败 ✅
- 非白名单自动接单：bot06 `dealAuto 0`，自动接单及精确角色名白名单属于 Sprint 8，本阶段以手工接受保证不自动接单 ✅

## 二、阻塞缺陷修复：拒绝后残留 incomingDeal

### 现象

服务端拒绝一笔交易请求后，OpenKore 只清理 `%outgoingDeal`，不清理 `%incomingDeal`。
当 Merchant 同时存在「待发出的请求」和「待处理的收到请求」时，发出方被拒绝后，
残留的 `%incomingDeal` 会让下一次 `deal <name>` 直接报错：

```text
Error in function 'deal' (Deal a Player)
You must first cancel the incoming deal
```

### 根因

`src/Network/Receive.pm::deal_begin` 对所有拒绝分支（type 0/1/2/4/5）只执行 `undef %outgoingDeal`，
从不清理 `%incomingDeal`；而 `%incomingDeal` 仅在 `deal_cancelled` / `deal_complete` / `deal_begin(type=3 接受)` 时清理。

rAthena `trade.hpp` 的 ack 语义（`e_ack_trade_response`）：

| type | 语义 | 是否拒绝 |
| --- | --- | --- |
| 0 | TOOFAR | 是 |
| 1 | CHARNOTEXIST | 是 |
| 2 | FAILED（对方在另一笔 / 忙碌 / 摆摊 / 仓库 / NPC） | 是 |
| 3 | ACCEPT（进入交易） | 否 |
| 4 | CANCEL | 是 |
| 5 | BUSY（写邮件） | 是 |

### 修复

在仓库管理的 `economy.pl` 增加 `error_deal` 钩子，仅在非成交中（`%currentDeal` 为空）
且 type ∈ {0,1,2,4,5} 时清理 `%incomingDeal` 与 `%outgoingDeal`，不触碰任何物品 / 余额：

```perl
sub on_trade_request_error {
    my (undef, $args) = @_;
    return if %currentDeal;
    return unless defined $args->{type} && $args->{type} =~ /^(?:0|1|2|4|5)$/;
    %incomingDeal = ();
    %outgoingDeal = ();
    econ_log("[TRADE] request rejected type=$args->{type}; pending requests cleared");
}
```

这是仓库内插件级修复（OpenKore 源码不改，遵循「OpenKore 源码补丁不提交进 ROdev」约定）。

### 单元测试

`OpenKore机器人/plugins/economy/t/trade_request_error.t`：10 项断言全部通过。

覆盖：0/1/2/4/5 各拒绝类型清理、成交中（type 3 接受 / 已 `%currentDeal`）不清理、
未知类型 fail-closed 不清理、清理绝不改动 `$char`（zeny/inventory 不变）。

### 实机验证

- deny（type 4）：Cartwright 拒绝 Penny 的请求后，
  日志出现 `[ECONOMY] [TRADE] request rejected type=4; pending requests cleared`，
  随后 `deal Penny` 直接成功，不再被「You must first cancel the incoming deal」卡住。✅
- 摆摊中接受被拒（type 2）：Cartwright 摆摊时接受 Penny 请求被服务端拒绝，
  双方均出现 `request rejected type=2; pending requests cleared`，无残留状态。✅

## 三、交易验收过程

### 前置准备（一次性注入，已记录）

1. **Poring Card（4001）×1 注入 Penny（150009）**：本阶段测试品。遵循总计划「SQL 初始化记为一次性经济注入」，
   于 bot07 离线时 `INSERT INTO inventory`，非跨角色搬运。
2. **授予 Penny NV_BASIC（技能 id 1，lv 9）**：DB 创建的角色没有正常建号流程自动授予的 Basic Skill，
   导致「You haven't learned enough Basic Skills to Trade」（`clif_parse_TradeRequest` 的 `basic_skill_check`）。
   于 bot07 离线时 `INSERT INTO skill` 补上标准 Novice 基础技能等级，属一次性引导修复。

> 说明：Combat Bot 的真实掉落卡片（如 bot05 的 Rocker Card）在 grind 机器人身上，
> 按「不打断 bot01–bot05」约束未取用；本阶段以 probe 角色 Penny 作为卖家端做机制验收，不影响卡片流通结论。

### 交易步骤（手工，双方 console 驱动）

```text
Penny    : deal Cartwright           → 发起请求
Cartwright: deal                     → 接受，双方 Engaged
Penny    : deal add 4 1              → 放入 Poring Card（inventory index 4）
Cartwright: deal add z 1000          → 放入 1,000z
Penny    : deal                      → finalize
Cartwright: deal                     → finalize
Penny    : deal                      → accept final
Cartwright: deal                     → accept final → Deal Complete
```

### 资产守恒核对（DB）

| 角色 | 交易前 | 交易后 | 变化 |
| --- | --- | --- | --- |
| Cartwright（150008）zeny | 9,970z | 8,970z | -1,000z |
| Cartwright Poring Card | 0 | 1 | +1 |
| Penny（150009）zeny | 10,030z | 11,030z | +1,000z |
| Penny Poring Card | 1 | 0 | -1 |

守恒成立：卡片 Penny → Cartwright，Zeny Cartwright → Penny，无复制 / 丢失。

### 重登持久化

双方 `relog` 后 DB 复核：Cartwright 8,970z + Poring Card ×1，Penny 11,030z + 无卡片；
Cartwright 客户端 `i` 回显同样包含 `[4001] 포링 카드 x 1`，与服务端一致。✅

### Merchant 忙碌拒绝

Cartwright 摆摊（`openshop`，12 件商品）时，Penny `deal Cartwright` 请求被送达，
Cartwright 接受时服务端 `trade_tradeack` 判定摆摊中 → 双方收到 `TRADE_ACK_FAILED`（type 2）：

```text
That person is in another deal.
[ECONOMY] [TRADE] request rejected type=2; pending requests cleared
```

请求明确失败且无残留状态。✅

## 四、运行态收尾状态

- bot06 Cartwright：online，prontera (156,170)，zeny 8,970，Poring Card ×1，摆摊已关。
- bot07 Penny：online，prontera (157,170)，zeny 11,030，无卡片，已授予 NV_BASIC 9。
- 收购店（buying store）：许可证 6377 已耗尽（每开一次消耗 1 张），当前无法重开，留待补货（Sprint 8 前需补许可证或走无技能道具路径）。

## 五、遗留 / 备注

1. 拒绝消息措辞偏误（非阻塞，OpenKore 源码层）：
   - deny/cancel（type 4）被 OpenKore 显示为「Deal request failed (unknown error 4)」。
   - 摆摊/忙碌拒绝（type 2）显示为「That person is in another deal.」。
   两者均为明确失败，语义可接受，但文案与实际原因不符，后续可在 OpenKore 源码补丁中修正（记入 `文档/`，不提交 ROdev）。
2. Sprint 8（自动收购一张 Card）尚未开始：需实现带 nonce 的 SELL_REQUEST/READY、精确角色名白名单自动接单，
   以及单张 Rocker Card 10,000z 的买卖双方状态机。
3. 角色档案 `Cartwright.yml` 驻扎坐标由旧值 (156,193) 更正为实际 (156,170)。
