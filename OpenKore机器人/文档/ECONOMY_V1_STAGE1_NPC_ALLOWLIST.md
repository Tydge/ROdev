# Economy V1 总计划阶段 1：NPC 防误卖白名单

日期：2026-09-07。对应总计划实验 1.1 / 1.2、Sprint 第 3 项。

## 实现

删除原有 1,644 条解析后的历史规则，统一为默认 KEEP 与 5 条 nameID 出售白名单：
705 Clover、909 Jellopy、920 Wolf Claw、938 Sticky Mucus、949 Feather。
Wolf Claw 来自总计划实验 1.1；其余四种来自既有 README 的普通掉落范围。
这些普通材料是明确批准的例外，不代表所有具有制作或任务用途的 Etc 都可出售。
Apple、Carrot 也改为保留，遵循总计划的消耗品保留策略。

单一策略来源为 `instances/shared-control/items_control.txt`。
移除英文名称出售规则，消除 OpenKore 名称优先于 nameID 的语言依赖。
卡片、武器、防具、饰品、未鉴定/带孔/精炼/插卡装备、重复装备、自定义未知物品均默认保留。
所有 storage / cart 开关为 0；保持现有原生 NPC Sell、buyAuto 及 world_ai 流程。
本步不提前实现 classify_item，也不打开自动 Trade。

原生 `AI/CoreLogic.pm` 在 `AI_sell_auto` 后生成 sellList，先检查 equipped/sellable，
再调用 `Misc::items_control(name, nameID)` 检查 sell 和 keep。
本次直接修复该函数使用的唯一出售表，避免只输出“保留”日志却仍被旧表出售。
无需修改 OpenKore 核心或新增第二份出售策略。

## 离线验证

执行：

```sh
sh OpenKore机器人/plugins/economy/t/run_npc_allowlist.sh 服务端运行目录/openkore 服务端运行目录/rathena
```

使用本机 OpenKore 的真实 FileParsers 和 Misc 模块，不模拟解析器。
加载当前 pre-re 三类物品表及 import 覆盖，27 项检查通过。
覆盖 6,169 条物品，其中 Card 538、Weapon 707、Armor 1,216；
检查中文/韩文等显示语言无关性（数据库名称、Aegis 名称和替代显示名称）、
未知 ID、药水、食物、箭矢、许可证、普通/带孔武器、防具、饰品及卡片。

白名单变更及服务端物品类型变更后可重复执行该检查。
它验证本次 NPC 策略，不替代下一步分类器要求的物品属性单元测试。

## 部署及实机验收

13:57:55 将唯一策略文件复制到 bot01–bot07，逐个 `reload items_control`。
七实例均返回 Loading 对应路径及 All files were loaded；逐字节核对与模板一致。
只热加载物品表，未重启 Bot，也未覆盖运行态 config.txt。
旧表备份位于 `日志与备份入口/logs/economy_stage1_20260907_135755/`（不提交）。

对 bot01 手工触发一次原生 `autosell`，用于验证现有自动回城链路：

- 13:58:17 Initiating auto-sell，前往 prt_in 126,76。
- 13:59:02 实际出售 Jellopy ×71、Sticky Mucus ×6、Clover ×41、Feather ×5。
- 收入 678z，Sold 4 items / Sell completed。
- 同秒 Auto-sell sequence completed / Auto-buy sequence completed。
- 随即恢复 prt_fild08 的 lockMap 路线。

出售前背包确有 5 种卡片（合计 11 张）、普通武器/防具、重复未鉴定 Sandals [1]、
Rod [4] 和 Knife [4]；真实出售清单只有上述四种白名单掉落。
13:59:56 再查背包，上述 11 张卡片和全部 12 件装备仍在；Apple ×68、Red Potion ×30 均保留。
Zeny 从 32,145 增至 32,823，差值正好 678z；重量由约 30.2% 降至 26.9%。
13:59:31 已回到 prt_fild08，13:59:54 恢复原生随机路线。
补给时已有 30 瓶 Red Potion，因此验证了补给流程完成，未产生额外药水购买。
本次未注入物品、未使用 SQL 转移资产、未开启普通自动 Trade。

## 边界与下一步

回图后 13:59:37 world_ai 重新选图返回 `route_probe_limit_reached`，候选均超出路线跳数上限；
这不影响已完成的出售/补给及返回原地图，但本报告不宣称动态选图健康。此独立问题未在本步修改。

默认保留范围扩大后，长期库存和负重可能增长。商人交货与过重 DEFERRED / 城内等待
是总计划后续阶段 7 的任务，不能据本次单次回城成功宣称完整长期经济闭环完成。

下一步是总计划 Sprint 第 4 项：共享 classify_item() 和对应离线测试。
完整阶段对照见 ECONOMY_V1_PROGRESS.md。
