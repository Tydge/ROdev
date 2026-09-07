# economy

包含共享只读分类器、独立 buying store 控制，以及总计划阶段 5–6 的安全普通 Trade / 多物品拆批。

## 只读分类

`lib/Economy/Classifier.pm` 无 OpenKore 依赖，Combat Bot 与 Merchant 可共享。
`classify_item(item, gear_ready => 1, reserved => 0)` 返回 `{decision, reason}`。

- 已装备、锁定/收藏/绑定、租赁、autoGear 保留、起步装备、未知/自定义覆盖物品优先 KEEP。
- 不可交易物品 KEEP；未完成 autoGear 评估、未鉴定、损坏或缺装备位置的装备 KEEP。
- Card → MERCHANT_SELL；Weapon / Armor → MERCHANT_SELL，饰品按 Armor 的装备位置识别。
- Etc 只有命中调用方提供的 `items_control` 数字 ID 出售规则，且服务端允许出售，才为 NPC_SELL。
- 消耗品、驯养物、任务材料、制作材料、特殊货币和其他未命中物品 KEEP。
- UNKNOWN 通过 `decision=KEEP, reason=UNKNOWN` 表示；V1 不输出自动消耗指令 CONSUME。
- 精炼/插卡/带孔信息保留在原始物品实例，不修改、合并或定价；分类不是交易授权，未来报价需重新核对真实实例。

`item_catalog.json` 是本服 Pre-Renewal 元数据快照，不含价格或 NPC 白名单。
更新服务器物品表后，重新生成并验证：

```sh
ruby OpenKore机器人/plugins/economy/tools/generate_item_catalog.rb 服务端运行目录/rathena OpenKore机器人/plugins/economy/item_catalog.json
sh OpenKore机器人/plugins/economy/t/run_npc_allowlist.sh 服务端运行目录/openkore 服务端运行目录/rathena
```

运行时复用 `%items_control` 为唯一 NPC 出售策略；目录不可用时未知物品默认保留。
原生 NPC 出售仍由上一阶段的白名单负责，分类观察器不改其结果或发送任何封包。

`autoGear` 安全评估且无待执行升级后发出 `autoGear_evaluation_complete`，economy 才分类。
若发出了装备请求，本轮不分类，等后续评估；缺目录、禁用 autoGear 或忙碌期间不分类。
日志仅输出变化的实例/数量/分类，删除的实例移出缓存。
`economy classify` 清理日志缓存并请求下次安全评估，不绕过 autoGear。
`economy_classify_enabled 0` 可禁用日志观察（默认开启），不改变买店开关。

起步装备保留 ID 为 1101、1201、1243、1501、1601、1701、2101、2301；
纯模块调用者可通过 `keep_ids` 提供明确策略。当前运行接入使用上述共享默认值。

## 收购店控制

原有 `economy status|open|close|reset` 和 `economy_buy_store_enabled/reserve` 保持兼容。
启用 `economy_trade_enabled` 时暂停收购店自动开店，避免争抢角色；已开的店需先关闭。
卖家队列、Cart 自动入库、自动售货和回城流程接入仍属后续阶段。


## 普通 Trade（阶段 5–6）

双方使用同一份 `trade_prices.json`：nameID → 每件固定 Zeny。旧的
`economy_trade_item / economy_trade_price` 不再生效；未标价物品不进入自动 Trade。
默认价格：4001 Poring Card / 4004 Drops Card / 4031 Peco Peco Card 各 10,000、
4021 Rocker Card 10,000、4023 Baby Desert Wolf Card 10,000、
4051 Yoyo Card 20,000、1208 Main Gauche [4] 3,000、2102 Guard [1] 5,000。
分类器判定 KEEP 的物品，即使有价格也不会出售。

```text
economy_trade_enabled 1
economy_trade_role seller             # 商人为 buyer
economy_trade_merchant Cartwright     # seller 设置
economy_trade_sellers Penny           # buyer 精确白名单，逗号分隔
economy_trade_timeout 30
economy_trade_cooldown 15
```

当前仅用于已在会合点、距离不超过 2 格的静止探针；
`world_ai_auto_execute` 必须关闭，战斗 / 路线 / NPC / 仓库等忙碌时不启动。
不会自动寻找商人或接管回城（阶段 7）。装备还需先有 autoGear 完成评估的有效快照；
bot07 默认关闭 autoGear，因此默认只会卖符合价格表的卡片。

每批最多 10 个真实库存条目，按 nameID、binID 排序。堆叠按实际数量计价；
同 ID 多件装备保持独立条目，使用精炼、插卡、随机属性等生成指纹。
逐项加物，收到服务端 ACK 后才发下一项，避免原生 `lastItemAmount` 覆盖。
对端逐项记录来自 `packet/deal_add_other`，不使用已按 nameID 合并的原生报价判断装备。

私聊协议已升级，双方必须同时使用新版本：

```text
SELL_REQUEST <tx_nonce> <entry_count>
SELL_ITEM <tx_nonce> <ordinal_from_0> <nameID> <amount> <sha256>
READY <tx_nonce> <total>
VERIFIED <tx_nonce>
```

manifest 每条私聊间隔至少 1 秒，每条消息小于 240 字符。
私聊清单只用于预告；付款仍以服务端实际物品报价为准。
rAthena 的加 Zeny 操作只向卖家回显，买家等卖家核价并锁定后再锁定，
双方均收到自己的锁定确认和对端锁定确认后才提交。

成交要同时满足服务端完成事件、交易开始后的真实 `zeny_change`、
完整 Inventory/Zeny 差额及 Cart 未变化。卖家还要收到买家 VERIFIED 才可开始下一批。
下一批从当前库存重建，使用新 nonce；不重放旧付款。

报价前、锁定前检查资金、人物空格/重量、Cart 空格/重量与堆叠限制。
人物容量按保守的基础 100 槽计算；重量多留 1 单位余量（OpenKore 显示重量向下取整）。
Cart 同时预留人物背包内尚未入车的已标价库存，避免多批连续收购重复使用同一份容量。
槽位按每个条目预留，可能保守拒绝可合并的堆叠；V1 优先避免超收。
本阶段只检查可入车容量，不执行 Cart 搬运。

超时主动取消：活动交易用 `sendCurrentDealCancel`，未接受请求用 `sendDealReply(4)`。
收到取消并核对回滚后才进入冷却。资产差异、缺失取消确认、掉线等不确定结果进入 `halted`，
不补款、不修改本地资产、不自动开始新交易。重新登录取得新资产后可运行
`economy trade reconcile`；只有资产与交易前或预期交易后完全一致才解除暂停。
历史交易缺少完成事件时，仅记录资产重建，不补记 VERIFIED 成交。
`economy trade reset` 不会丢弃正在处理或尚未核对的会话。

```sh
sh OpenKore机器人/plugins/economy/t/run_all.sh 服务端运行目录/openkore 服务端运行目录/rathena
```

新代码已完成离线状态机、容量、接线与旧逻辑回归。bot06/bot07 已同步部署；
三种卡片自动成交、资金不足、超时回滚和重登持久化已实机通过，
跨 10 项拆批、装备实例及真实满容量边界仍待实机验收。
详见 `OpenKore机器人/文档/ECONOMY_V1_STAGE6_MULTI_TRADE.md`。
