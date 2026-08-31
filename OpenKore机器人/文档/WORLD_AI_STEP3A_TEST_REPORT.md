# world_ai Step 3A 测试报告

测试日期：2026-08-31（Asia/Hong_Kong）

## 版本与环境

- 项目 Git 基线：`c87c6f1`；Step 3A 实现以本报告所在提交为准。
- OpenKore：`51de1ddfc4449ae5217f6886de702f87ca934030`，运行路径 `/Users/wangtaizhi/Documents/Codex/2026-08-22/j/outputs/ro-local/openkore`。
- OpenKore 部署工作树包含本服既有构建、协议、配置、表与插件改动；`src/Task/CalcMapRoute.pm` 和 `src/Task/MapRoute.pm` 本身未修改。
- rAthena：`9ee78480020d95b30ef22c0c2685de1439e50ff9`。
- Bot：仅 bot01 参与 Step 3A 实测；KoreHelper，Thief，Base 17 / Job 10，初始地图 `prt_fild08`。
- bot02～bot05 在集成测试前关闭；测试结束后再恢复日常运行。

## 实现方式与实际 API

新增 `WorldAI::RouteProbe`，局部构造 `Task::CalcMapRoute`，调用：

```text
new(map, sourceMap, sourceX, sourceY, budget, maxTime, suppressDebug)
activate()
iterate()
getStatus()
getError()
getRoute()
getRouteString()
stop()
```

局部 Task 从未加入 OpenKore TaskManager 或 AI queue。源码未创建 `Task::MapRoute`，未调用 `Commands::run`、`configModify` 或 `AI::queue`。

结果使用 `REACHABLE / UNREACHABLE / UNKNOWN` 三态：

- `CANNOT_LOAD_FIELD`、`CANNOT_CALCULATE_ROUTE` → `UNREACHABLE`。
- timeout、异常、角色状态不足、未知 Task 状态 → `UNKNOWN`。
- 当前地图在构造 CalcMapRoute 前直接短路为 `REACHABLE / hops=0`。这是因为本机 `Task::Route::getRoute` 会拒绝缺少目标 x/y 的同地图调用。

路线元数据约定：`route_hops` 是 `getRoute()` step 数量；`route_weighted_cost`、Zeny 和票券取最后一步的累计值，不把每步累计值重复相加。

## 时间与数量保护

```text
CalcMapRoute maxTime slice: 30 ms
单地图外层 deadline: 1000 ms
recommend reachable 总预算: 2000 ms
每条命令最多唯一地图: 8
```

达到单图 deadline 返回 `UNKNOWN/TIMEOUT`；达到整条命令预算或地图数量限制会明确输出 `route_command_budget_reached` 或 `route_probe_limit_reached`。

OpenKore 内部路径函数为同步调用，因此这些值是当前配置下的工程保护与实测预算，不宣称为可以抢占任意内部函数的硬实时保证。当前 `route_warpByItem=0`、`saveMap_warp=0`，`portals_commands.txt` 的 `@go` 条目全部被注释，没有启用会启动额外特殊分支的路线。

## fail_calc_map_route hook 审计

全量搜索实际 OpenKore 的 `src`、`plugins`、`control`、实例配置与 tables，唯一结果是 `src/Task/CalcMapRoute.pm` 中的 hook 发出点；没有监听者。因此只读预检计算失败不会触发其他插件移动、重试或修改状态。

## 离线测试

```text
Files=4, Tests=33
Result: PASS

Index.pm syntax OK
Scorer.pm syntax OK
CharacterSnapshot.pm syntax OK
RouteProbe.pm syntax OK
world_ai.pl syntax OK
git diff --check: PASS
```

`route_probe.t` 覆盖：当前地图、成功路线、累计元数据、明确不可达、timeout、异常、候选 fallback、同地图去重和最大 probe 数量。

静态扫描确认正式插件不存在：

```text
Task::MapRoute
Commands::run
configModify
AI::queue / AI::clear
Plugins::addHook
lockMap / mon_control 修改
```

## Integration A：当前地图

manual AI 清空既有测试 route 后，执行前后均为：

```text
map=prt_fild08
pos=51,251
AI Sequence=[]
```

输出：

```text
[ROUTE] source=prt_fild08 (51,251) target=prt_fild08 status=REACHABLE engine=Task::CalcMapRoute elapsed_ms=0
[ROUTE] hops=0 weighted_cost=0 zeny=0 tickets=0 npc=0 command=0 airship=0 save_teleport=0 warp_item=0
[ROUTE] route=prt_fild08
```

## Integration B：已知单跳地图

```text
[ROUTE] source=prt_fild08 (51,251) target=prt_fild07 status=REACHABLE engine=Task::CalcMapRoute elapsed_ms=28
[ROUTE] hops=1 weighted_cost=56 zeny=0 tickets=0 npc=0 command=0 airship=0 save_teleport=0 warp_item=0
[ROUTE] route=prt_fild08 (16,239) [walk 56] -> prt_fild07
```

角色没有执行该路线。

## Integration C：已知多跳地图

```text
[ROUTE] source=prt_fild08 (51,251) target=prt_fild04 status=REACHABLE engine=Task::CalcMapRoute elapsed_ms=44
[ROUTE] hops=3 weighted_cost=600 zeny=0 tickets=0 npc=0 command=0 airship=0 save_teleport=0 warp_item=0
[ROUTE] route=prt_fild08 (16,239) [walk 56] -> prt_fild07 (248,376) [walk 227] -> prt_fild05 (14,141) [walk 600] -> prt_fild04
```

路线与此前真实 MapRoute 成功路径一致，角色仍停在 `prt_fild08 (51,251)`。

## Integration D：不存在地图

```text
[ROUTE] source=prt_fild08 (51,251) target=this_map_should_not_exist_999 status=UNREACHABLE engine=Task::CalcMapRoute elapsed_ms=3
[ROUTE] error=CANNOT_LOAD_FIELD message=Cannot load field 'this_map_should_not_exist_999'.
```

没有 crash，OpenKore 与原 AI 保持运行。

## Integration E：validated recommendation

```text
[RECOMMEND_REACHABLE] static_score_ms=32.5 route_elapsed_ms=47 probes=1
[VALIDATE] static_rank=1 Spore (1014) @ pay_fild08 score=43.6 risk=LOW route=REACHABLE cached=no action=SELECTED
[SELECTED] Spore (1014) @ pay_fild08 score=43.6 risk=LOW static_rank=1
[SELECTED_ROUTE] hops=3 weighted_cost=683 zeny=2000 tickets=0 npc=1 command=0 airship=0 save_teleport=0 warp_item=0
[SELECTED_ROUTE] route=prt_fild08 (170,378) [walk 150] -> prontera (151,29) [walk 557] -> payon (267,89) [walk 683] -> pay_fild08
```

该路线由 OpenKore 选择了一次需 2000 Zeny 的 NPC warp，元数据正确显示 `npc=1`。没有执行 NPC 对话或移动。

原 `worldai recommend` 兼容性复测：

```text
[RECOMMEND] elapsed_ms=31.2
#1 Spore (1014) @ pay_fild08 score=43.6 risk=LOW ... route=UNVERIFIED travel_cost=undef
```

## Integration F：绝对无移动副作用

干净 manual AI 复测前后：

```text
map/pos: prt_fild08 (51,251) -> prt_fild08 (51,251)
AI Sequence: [] -> []
lockMap: prt_fild08 -> prt_fild08
mon_control.txt SHA-256:
310dfe2c304e9a6abeba0d09cc5a5f3a2374893f7d8764a36f2893944bc835e8
```

连续执行当前地图、单跳、多跳、不存在地图和 validated recommendation 后，以上状态与哈希全部不变。

## Integration G：性能

manual AI 实测：

```text
当前地图: 0 ms
单跳: 28 ms
多跳: 44 ms
不存在地图: 3 ms
validated recommendation: 32.5 ms scoring + 47 ms route
```

正常 AI 移动中另一次多跳为 57 ms。所有实际探测远低于单图 1000 ms 和整条命令 2000 ms 预算。

## Integration H：战斗中调用

南门短时没有可见白名单怪，因此使用已验证的 `world_ai_test hunt Rocker` 作为明确区分移动来源的测试夹具。该插件负责前往 `prt_fild07` 和放行 Rocker；Step 3A 只在战斗期间执行路线预检。

关键时序：

```text
22:40:57.24 You are now attacking Monster Rocker
22:40:57.90 worldai route prt_fild04 -> REACHABLE, 38 ms
22:40:58.25 worldai recommend reachable -> REACHABLE, route 64 ms
22:41:02.17 You are now attacking Monster Rocker
22:41:03.76 onward: normal attacks continue
22:41:10.40 Target Monster Rocker died
```

首次目标因 OpenKore 自己无法计算 meetingPosition 在路线命令输出前已经丢弃；RouteProbe 返回后正常 AI 重新取得 Rocker 并完成击杀，期间喝药逻辑也正常运行。之后还连续完成多次 Rocker 击杀。

执行 `worldtest stop` 后：

```text
[WORLDTEST][STOP] ... restored=1
lockMap=prt_fild08
mon_control.txt SHA-256=310dfe2c304e9a6abeba0d09cc5a5f3a2374893f7d8764a36f2893944bc835e8
```

由测试夹具产生的移动和临时内存放行均已恢复；Step 3A 本身没有产生移动或配置修改。

测试清理完成后 bot01 已返回 `prt_fild08`，bot02～bot05 已恢复日常运行。

## 特殊路线情况

- 本次 validated recommendation 使用 NPC warp，`uses_npc=1`、`route_zeny=2000`。
- 普通 portal 路线正确显示所有特殊标志为 0。
- 当前没有启用 `@go`、save teleport、warp item 或 airship 路线，因此未做这些类型的实机执行验证；解析逻辑按字段存在性防御，并有纯单元测试基础。

## 已知限制与下一步

- 预检结论只代表当前起点、Zeny、道具、保存点、配置和路由表，不持久化为永久可达性事实。
- 同步 OpenKore API 不能提供可抢占任意内部路径函数的严格硬实时保证；当前使用小时间片、单图 deadline 和总命令预算降低风险。
- 当前没有把 travel cost 加入 Step 2 score；评分和路线状态保持独立。
- Step 3A 仍为 `RECOMMEND_ONLY`。下一步进入 Step 3B 前，应另行设计允许切图的安全状态与实际 MapRoute 执行策略。
