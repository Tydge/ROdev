# Economy V1 · 阶段 5（总计划）/ Sprint 8：普通 Trade 自动收购一张 Card

> 对应总计划 §8「阶段 5：第一次全自动收购」实验 5.1。
> 在阶段 4 手工 Trade 验收通过的基础上，实现完全无人操作的卖家/买家普通 Trade 状态机。

> 后续更新（2026-09-07）：本文为 Sprint 8 历史实机记录。单卡配置和协议已由阶段 6 多物品实现替代；当前实现、测试及实机待验收范围见 `ECONOMY_V1_STAGE6_MULTI_TRADE.md`。

## 一、结论

通过。bot07（Penny，seller）与 bot06（Cartwright，buyer）在无人操作下完成一笔
Baby Desert Wolf Card（4023）@ 10,000z 的自动收购，资产守恒、重登持久化均核对通过。

- 全自动成交（无人工输入）✅
- 卡片真实转移：4023 ×1 Penny → Cartwright ✅
- Zeny 真实转移：10,000z Cartwright → Penny ✅
- nonce 私聊握手（SELL_REQUEST/READY）与精确角色名白名单接单 ✅
- 卖家核对商人报价（仅接受等于 10,000z 的报价）✅
- 重登持久化 ✅

## 二、实现

### 新文件

- `OpenKore机器人/plugins/economy/lib/Economy/Trade.pm`：纯状态机，无 OpenKore 依赖，可离线单测。
- `OpenKore机器人/plugins/economy/t/trade.t`：52 项断言。

### 消息协议（私聊，空格分隔）

```text
seller -> buyer : SELL_REQUEST <nonce> <itemID>
buyer  -> seller: READY <nonce>
```

### 状态机

```text
seller: idle --(has_card)--> wait_ready --(READY nonce 匹配)--> initiating
        --(engaged)--> engaged --(报价==price)--> quoted --(对方锁定)--> committing --(complete)--> done
buyer : idle --(SELL_REQUEST 白名单+物品+nonce)--> ready_sent --(incoming deal 匹配)--> accepting
        --(engaged)--> engaged --(卡片 amount==1)--> quoted --(对方锁定)--> committing --(complete)--> done
```

安全规则：
- buyer 只响应白名单卖家 + 期望 itemID + 未见过的 nonce（防重放）。
- seller 只认配置商人回 READY，且 nonce 必须匹配。
- 报价/数量不符时 `reject_deal`（锁定前取消）。
- 每状态 30s watchdog，超时进入 error，冷却 15s 后自愈回 idle。

### economy.pl 接线

- 钩子：`packet_privMsg` / `incoming_deal` / `engaged_deal` / `finalized_deal` /
  `complete_deal` / `cancelled_deal` / `error_deal` 驱动 `Economy::Trade`，
  `AI_pre/manual` 每 1s tick 轮询对方报价/物品与 watchdog。
- 动作执行映射：`send_pm`→`sendMessage($messageSender,…)`、`accept/reject`→`sendDealReply(3/4)`、
  `initiate_deal`→`main::deal()`、`add_item`→`main::dealAddItem()`、`add_zeny/finalize/commit`→
  `$messageSender->sendDealAddItem/sendDealFinalize/sendDealTrade`。

### 配置（config.txt）

```text
economy_trade_enabled 1     # 总开关
economy_trade_role seller|buyer
economy_trade_item 4023     # 交易物品 nameID
economy_trade_price 10000
economy_trade_merchant Cartwright   # seller 用
economy_trade_sellers Penny         # buyer 用白名单（逗号分隔）
economy_trade_timeout 30
economy_trade_cooldown 15
```

## 三、实机验收过程中修复的三个缺陷

1. **$net vs $messageSender**：`send_pm`/`sendDealReply` 等发送操作误用了 `$net`（Receive 对象），
   导致 `sendPrivateMsg` 方法缺失、bot07 直接掉线退出。改为 `$messageSender`（Send 对象）。
2. **启动时序**：插件加载早于 config.txt，导致 `_build_trade()` 在 `%config` 为空时构建失败。
   改为在 `postloadfiles`（config 已就绪）再构建一次。
3. **锁定竞态**：买家先看到物品并锁定，卖家通过 tick 轮询报价较慢，收到 `finalized_deal` 事件时
   尚在 `engaged` 态而漏掉；卖家之后锁定时无人再触发提交，双方卡死直到 watchdog。
   修复：tick 轮询 `$currentDeal{other_finalize}`，在 `engaged→quoted` 时若对方已锁定则直接
   「锁定+提交」，并在 `quoted` 态兜底提交。

## 四、实机交易日志（摘要）

```text
[buyer  bot06] (From: Penny) : SELL_REQUEST e4623b69 4023
               [TRADE] buyer accepted SELL_REQUEST from Penny; sent READY
               [TRADE] buyer accepting deal from whitelisted Penny
               Penny added Item to Deal: 데저트울프 새끼 카드 x 1
               [TRADE] buyer saw itemID=4023 amount=1; paying 10000z and finalizing
               [TRADE] counterpart finalized; committing
               [TRADE] complete: counterpart=Penny itemID=4023 price=10000z nonce=e4623b69

[seller bot07] (To Cartwright) : SELL_REQUEST e4623b69 4023
               (From: Cartwright) : READY e4623b69
               [TRADE] seller verified quote 10000z and counterpart already locked; finalizing+committing
               You gained 10,000 zeny.
               [TRADE] complete: counterpart=Cartwright itemID=4023 price=10000z nonce=e4623b69
```

## 五、资产守恒与重登持久化

| 角色 | 交易前 | 交易后 | 变化 |
| --- | --- | --- | --- |
| Cartwright zeny | 20,000z | 10,000z | -10,000z |
| Cartwright 4023 | 0 | 1 | +1 |
| Penny zeny | 11,030z | 21,030z | +10,000z |
| Penny 4023 | 1 | 0 | -1 |

双方 `relog` 后 DB 复核一致，`online=1`，卡片/Zeny 持久化无误。

## 六、关于卡片种类

计划 §8 以「Rocker Card」为示例；实机使用 **4023 = Baby Desert Wolf Card（데저트울프 새끼 카드）**。
原因：Rocker Card 的 nameID 是 4021，当前 grind 机器人没有掉落该卡；而 4023 是 bot05 NoraEllis
真实掉落的卡片（持有 6 张）。状态机按 nameID 判定，与卡片种类无关，改用 4021 只需改配置
`economy_trade_item` 一行。

## 七、一次性经济注入（审计）

- Penny 注入 4023 ×1（测试品）。
- Cartwright zeny 8,970 → 20,000（Sprint 8 收购留余量）。
两者均为 SQL 一次性注入，非交易机制；交易本身走真实 Trade 封包。

## 八、测试

- `trade.t`：52 项断言（全流程、白名单/物品/nonce 校验、错误报价/数量拒绝、watchdog、冷却自愈、锁定竞态）。
- 既有全量回归：`npc_allowlist.t`(27) + `classifier.t`(62) + `autogear_order.t`(6) + `trade_request_error.t`(10) 全绿。

## 九、遗留 / 下一步

- 阶段 6（多物品交易）：单笔最多 10 条目的拆批与定价，本状态机目前固定单物品、单数量。
- 阶段 7（接入回城流程）：把 seller 侧接进战斗 bot 的真实回城流，并为 world_ai 增加 deal/economy 忙碌保护。
- 阶段 8（异常处理）：资金不足 / 背包容量不足 / 多卖家排队 / Trade 中断恢复的完整清理。
- `dealAuto` 保持 0，接单完全由状态机按白名单驱动（不依赖原生 dealAuto）。
