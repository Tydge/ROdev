# economy

包含独立的 buying store 自动开关功能，以及 Economy V1 总计划实验 2.1 的只读分类器。
两者不等同于普通 Trade 自动收购。

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
自动普通 Trade、报价、队列、Cart 入库与自动售货不在本次实现范围。
