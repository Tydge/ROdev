# Economy V1 实验 2.1 / Sprint 4：共享只读分类器

2026-09-07 完成。前置提交 ec669f0 已推送 origin/main。

## 实现与边界

- 新增 `plugins/economy/lib/Economy/Classifier.pm`，纯函数式判定，无游戏连接依赖，不修改输入实例。
- 元数据由本服 6,169 条 pre-re 物品及 import 覆盖生成；支持递归合并覆盖，导入自定义物品保守保留。
- NPC 白名单继续使用原生 `%items_control` 的数字规则，不新增平行名单或复制价格规则。
- 卡片、可识别的已鉴定 Weapon/Armor 为 MERCHANT_SELL；饰品使用 Armor 的 Locations 判断。
- 已装备、起步、锁定/收藏/绑定、租赁、不可交易、未知/自定义、未鉴定、损坏、待 autoGear 评估及保留升级品 KEEP。
- 普通消耗品、驯养物、非白名单材料和货币 KEEP。未知使用 KEEP + UNKNOWN 原因，不产生消耗指令。
- 带孔、精炼、插卡装备按实例分类，不改属性、不合并实例；未来实际交易仍需重新校验和报价。

autoGear 仍是唯一装备评估者。安全 tick 先执行既有 choose_one_upgrade：有装备请求则直接返回；
后续评估没有升级请求时才触发 `autoGear_evaluation_complete`，economy 随后读取当前背包。
新增 equip 忙碌保护；autoGear 禁用或目录缺失时不发分类事件。
观察器只输出变化的分类/数量，支持 `economy classify` 重置缓存并等待安全评估。
`economy_classify_enabled 0` 可禁用观察器。分类不触发普通 Trade，也不改变原生 NPC Sell。

## 检查

复现命令：

```sh
sh OpenKore机器人/plugins/economy/t/run_npc_allowlist.sh 服务端运行目录/openkore 服务端运行目录/rathena
```

95 项通过：

- 原生 NPC 白名单回归 27 项，完整服务端物品目录。
- 分类器 62 项，包括名称无关性、已鉴定/未鉴定、带孔精炼插卡、饰品、装备/升级保留、未知、驯养/药水/材料/货币、禁止交易/出售、绑定/租赁及输入不变。
- autoGear 真实入口配合装备请求桩 6 项：忙碌不评估、发装备请求不发布分类事件、评估稳定后才发布、禁用后不发布。
- economy / autoGear Perl 语法检查及 git diff --check 通过。

## 实机

bot01 于 14:05:23 热加载后记录：

```text
nameID=4001 amount=4 -> MERCHANT_SELL reason=CARD (read_only)
nameID=4006 amount=1 -> MERCHANT_SELL reason=CARD (read_only)
nameID=2301 amount=1 -> KEEP reason=STARTER_GEAR (read_only)
nameID=2305 amount=1 -> KEEP reason=EQUIPPED (read_only)
nameID=2402 amount=1 -> KEEP reason=UNIDENTIFIED (read_only)
nameID=909 amount=8 -> NPC_SELL reason=NPC_ALLOWLIST (read_only)
```

14:05:29 捡到 Jellopy 后仅更新该数量变化；分类日志均为只读。
热加载 economy 和 autoGear 到 bot01–bot07；分类输出依赖角色启用 autoGear 并进入安全评估时机。
原有 buying store 功能保留，插件重载只重置进程内会话统计，不修改服务端资产。

## 下一步

Sprint 7：补齐 Merchant 本人普通 Trade 的专项验收（含引导证据核对），然后才实施 Sprint 8 的自动单卡收购。
此前 STAGE4_BUYING_STORE 是额外能力探针，不作为该普通 Trade 验收的替代。
