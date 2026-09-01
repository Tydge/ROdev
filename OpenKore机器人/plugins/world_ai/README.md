# world_ai — Step 3B：bot01 受控真实执行器

`world_ai` 是 OpenKore 上层的练级决策器。Step 3B 保留原有只读评分和路线预检，并增加只由用户手动启动的真实执行模式。执行器选择第一条符合安全政策的推荐，临时修改运行态 `lockMap` 与目标怪物控制，创建受约束的 OpenKore 原生 `Task::MapRoute`；到达后仍由 OpenKore 原有战斗、拾取、卖货、补药、复活和 lockMap 返回流程工作。

Step 3B 只在 bot01 启用；没有定时重选地图，也没有五机器人自动换图。

## 命令

```text
worldai status
worldai top [N]
worldai recommend
worldai route <map>
worldai recommend reachable
worldai execute
worldai exec status
worldai exec stop
worldai inspect monster <Name|AegisName|ID>
worldai inspect map <map>
worldai reload
```

`top` 默认输出 5 项，最多 20 项。排序固定为分数降序、怪物 ID 升序、地图名升序。原 `recommend` 行为保持不变，仍输出纯静态评分第一名和 `route=UNVERIFIED`。

`route <map>` 从当前 `$field->baseName` 与 `$char->{pos_to}` 计算路线，返回 `REACHABLE / UNREACHABLE / UNKNOWN` 三态及路线步数、累计权重、Zeny、票券和特殊路线类型。当前地图会直接返回 `REACHABLE / hops=0`，避免向同地图寻路传入缺失的目标坐标。

`recommend reachable` 先完成原有静态排序，再按顺序验证唯一地图，选择第一条明确 `REACHABLE` 的候选。不可达地图跳过，超时或异常按 `UNKNOWN` 处理；原始分数不修改。

`execute` 会重新评分并使用执行专用路线约束验证候选。若当前正在卖货、买药、仓库、NPC 对话、传送、事件宏或坐下恢复，命令安全拒绝；若正在战斗，则等待当前目标死亡后再出发。命令只决策一次，之后不会因升级或评分变化自动换图。

`exec status` 输出 `IDLE / SELECTING / VALIDATING / WAITING_SAFE / MOVING / ACTIVE / ERROR`、目标、地图、AI action、攻击与击杀计数。`exec stop` 立即恢复运行态配置；若正在正常战斗、卖货、补药或死亡恢复，不清空这些原生流程，等它结束后再由恢复后的 lockMap 接管。

## 目录

```text
world_ai/
├── world_ai.pl
├── map_index.json
├── lib/WorldAI/
│   ├── Index.pm
│   ├── CharacterSnapshot.pm
│   ├── Scorer.pm
│   ├── RouteProbe.pm
│   ├── ExecutionPolicy.pm
│   └── RuntimeOverride.pm
├── t/
│   ├── index.t
│   ├── scorer.t
│   ├── performance.t
│   ├── route_probe.t
│   ├── execution_policy.t
│   └── runtime_override.t
└── tools/gen_index.py
```

- `Index.pm`：加载和校验索引，建立名称与 ID 查询表；reload 失败时保留旧数据。
- `CharacterSnapshot.pm`：从 OpenKore `$char`、`$field` 读取实时状态。
- `Scorer.pm`：无 OpenKore 副作用的纯评分模块。
- `RouteProbe.pm`：局部执行 `Task::CalcMapRoute`，解析三态与路线元数据；不加入 AI queue。
- `ExecutionPolicy.pm`：定义执行阶段允许的路线及拒绝原因。
- `RuntimeOverride.pm`：保存、应用和精确恢复纯内存配置覆盖。
- `world_ai.pl`：命令、状态机、原生 MapRoute 创建、运行路线复核和错误隔离。

## CPU 约束

评分和路线推荐仍只在用户执行命令时运行；`status` 不遍历候选，也没有定时重算。插件有一个轻量 `AI_pre` 状态监控钩子，但在 `IDLE / ERROR` 时立即返回，只在执行活动期间检查地图变化、超时和实际 MapRoute 的路线元数据。

路线计算使用 30 ms 的 `CalcMapRoute maxTime` 时间片、单地图 1000 ms 外层 deadline、整条 `recommend reachable` 2000 ms 总预算，并最多验证 8 张唯一地图。达到限制会输出 `route_probe_limit_reached` 或 `route_command_budget_reached`。由于 OpenKore 内部路径函数为同步调用，该上限是当前配置下的工程保护和实测预算，不宣称为可抢占任意内部调用的硬实时保证。

## 安全边界

- 执行专用 CalcMapRoute 固定 `budget=0`，并设置 `noGoCommand / noTeleSpawn / noWarpItem / noAirship`。
- 第一版还拒绝任何 NPC step、票券、收费、command、airship、save teleport 和 warp item 路线。
- 执行政策默认限制路线最多 3 跳（`exec_max_hops=3`），让角色先在附近练级；超过跳数的候选会以 `route_hops_exceeded` 跳过。后续稳定后可调整 `$EXEC_MAX_HOPS`。
- 实际 MapRoute 设置 `noGoCommand / noTeleSpawn / noAirship`，运行态把 `route_maxWarpFee / route_warpByItem / saveMap_warp` 设为 0；每次 MapRoute 重算后再次检查路线元数据。
- 背包存在 Kafra 免费传送券（7060）时拒绝执行，避免实际 MapRoute 使用票券分支。
- `lockMap`、`lockMap_x/y/randX/randY`、三项路线开关和目标怪物条目都保存原值并精确恢复。
- 上述覆盖只直接修改 `%config / %mon_control`；不调用会写 `config.txt` 的 `configModify`。
- `exec stop`、路线失败、超时、监控异常和插件卸载都会恢复；进程崩溃或重启则天然重新读取磁盘原配置。
- 多图免费步行路线允许 900 秒，避免首次发现 portal 时 OpenKore 重建 portal LOS 表造成误超时。

- MVP 或候选地图属于 `boss_spawn_maps` 时硬排除。
- 明显超出等级、单击伤害或预估击杀次数阈值的怪物硬排除。
- `skill_range` 暂不评分，因为当前数据几乎都是默认值，不能证明怪物实际拥有远程技能。
- `attack_range` 参与远程风险。
- 当前 schema 2 只有刷新数量，没有地图面积和重生时间，因此评分项叫 `spawn_count_score`，不是严格的刷新密度。
- Top 榜只使用 `%maps_lut` 已知地图；路线仍标为 `UNVERIFIED`，Step 3 执行前必须重新验证。
- `CANNOT_LOAD_FIELD` 和 `CANNOT_CALCULATE_ROUTE` 归类为 `UNREACHABLE`；超时、角色状态不足、异常或未知 Task 错误一律归类为 `UNKNOWN`。
- 路线 `walk`、Zeny 和票券是 OpenKore 最后一步的累计值，不把每一步重复相加；当前阶段不把路线成本加入 score。
- 普通显示名可能重名；歧义时命令会列出 ID/AegisName，而不是擅自选择。

## 离线测试

在项目根目录执行：

```bash
prove -I"OpenKore机器人/plugins/world_ai/lib" \
  "OpenKore机器人/plugins/world_ai/t/index.t" \
  "OpenKore机器人/plugins/world_ai/t/scorer.t" \
  "OpenKore机器人/plugins/world_ai/t/performance.t" \
  "OpenKore机器人/plugins/world_ai/t/route_probe.t" \
  "OpenKore机器人/plugins/world_ai/t/execution_policy.t" \
  "OpenKore机器人/plugins/world_ai/t/runtime_override.t"
```

正式启用前还应使用 OpenKore 的 `src` 和 `src/deps` 路径执行 `perl -c`。部署只允许 bot01 的 `sys.txt` 加载正式 `world_ai`；实验插件 `world_ai_test` 不应和 Step 3B 同时加载。

## 第 1 步索引生成

`map_index.json` 仍由纯标准库 Python 生成：

```bash
python3 "OpenKore机器人/plugins/world_ai/tools/gen_index.py" \
  --rathena-root "/Users/wangtaizhi/Documents/Codex/2026-08-22/j/outputs/ro-local/rathena"
```

数据来自 `db/pre-re/mob_db.yml` 与三个怪物脚本配置实际启用的静态刷怪文件。必需输入缺失时默认失败且不覆盖旧索引；只有显式传 `--allow-partial` 才允许生成部分数据。

当前 schema 2 包含 510 种有静态刷新点的怪物、318 张地图。内部关联始终使用怪物 ID，避免 Name/AegisName/刷怪脚本别名不一致。

已知边界：不索引 NPC 动态召唤；不计算真实 EXP/hour、掉落收益、路线成本、地图面积或实际重生率；不修改 rAthena 原生刷怪。
