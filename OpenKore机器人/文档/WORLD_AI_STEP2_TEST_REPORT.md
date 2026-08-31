# world_ai Step 2 测试报告

测试日期：2026-08-31（Asia/Hong_Kong）

## 版本与环境

- 项目 Git 基线：`85f6c27`；Step 2 实现随本报告一并提交（以 Git 日志中本文件所在提交为准）。
- OpenKore：`51de1ddfc4449ae5217f6886de702f87ca934030`，运行路径 `/Users/wangtaizhi/Documents/Codex/2026-08-22/j/outputs/ro-local/openkore`。
- rAthena：`9ee78480020d95b30ef22c0c2685de1439e50ff9`，工作树干净。
- Bot：仅 bot01；KoreHelper，Thief，Base 16 / Job 9。
- 测试模式：先以 manual AI 验证只读性，再以正常 AI 验证共存。

## 离线验证

```text
Files=3, Tests=26
Result: PASS

Index.pm syntax OK
Scorer.pm syntax OK
CharacterSnapshot.pm syntax OK
world_ai.pl syntax OK
openkore-control.sh: zsh -n PASS
git diff --check: PASS
```

关键断言：

- schema 2、510 种怪、318 张地图、1,920 个怪物×地图候选。
- Poring 1002 与 Rocker 1052 数据/刷新数正确。
- `Goblin` 返回 5 个重名 ID，不静默选择。
- 损坏 JSON reload 失败后旧 index 仍保留。
- Vocal 对 Base 8 固定快照被过滤，并对 `prt_fild07` 产生共存怪风险。
- Beelzebub 1873 虽然 `is_mvp=false`，仍因 `boss_spawn_maps` 被硬过滤。
- 同一输入重复评分完全一致。

## CPU 与性能

插件没有 `AI_pre` hook、后台线程、轮询或定时任务。`status` 不遍历候选；只有推荐/inspect 命令按需评分，同一次命令中每张地图的风险只计算一次。

```text
离线完整评分：1920 candidates / 318 maps / 22.03 ms
bot01 worldai top 10：28.9 ms、32.3 ms、29.8 ms
bot01 worldai recommend：29.4 ms、32.2 ms、29.5 ms
```

manual AI 短时采样中，插件加载时 OpenKore 进程约 3.2% CPU，卸载后约 2.8%；该差异属于短时采样噪声。更可靠的结构性证据是插件没有任何持续执行入口，完整评分本身约 30 ms。

## 实际 status

```text
[WORLD_AI] [STATUS] plugin_version=2.0.0 mode=RECOMMEND_ONLY movement_control=OFF combat_control=OFF
[WORLD_AI] [STATUS] cpu_model=ON_DEMAND background_hooks=0 max_top_n=20
[WORLD_AI] [STATUS] index=loaded schema=2 monsters=510 maps=318 candidate_pairs=1920
[WORLD_AI] [CHARACTER] base=16 job=9 class=Thief map=prt_fild08 hp=197/197 sp=42/42 atk=38 def=18 hit=26 flee=36
```

## 实际 Top 10

```text
#1  Spore      (1014) @ pay_fild08 score=43.0 risk=LOW    spawn=70
#2  Spore      (1014) @ pay_fild01 score=41.0 risk=LOW    spawn=100
#3  Tarou      (1175) @ prt_sewb2  score=35.8 risk=LOW    spawn=60
#4  Peco Peco  (1019) @ moc_fild02 score=35.4 risk=LOW    spawn=70
#5  Poporing   (1031) @ moc_pryd01  score=34.9 risk=LOW    spawn=20
#6  Tarou      (1175) @ mjo_dun01  score=34.9 risk=LOW    spawn=60
#7  Spore      (1014) @ prt_sewb2  score=34.4 risk=LOW    spawn=20
#8  Mandragora (1020) @ prt_fild02 score=34.4 risk=LOW    spawn=70
#9  Wormtail   (1024) @ pay_fild06 score=33.9 risk=MEDIUM spawn=90
#10 Poporing   (1031) @ gef_fild00 score=32.7 risk=LOW    spawn=10
```

每项均同时输出 `level_fit`、`exp_value`、`spawn_count_score`、`kill_cost`、`target_risk`、`map_risk` 和人类可读原因。所有路线明确显示 `route=UNVERIFIED travel_cost=undef`。

`worldai top 100` 被限制为 20 项：

```text
[WORLD_AI] [TOP] requested=100 capped=20
```

## inspect 证据

Rocker：

```text
[MONSTER] id=1052 name=Rocker aegis=ROCKER level=9 hp=198 atk=24-29 exp=20+16 mvp=no
map=prt_fild04 spawn=70 allowed=yes score=24.1 risk=LOW
map=prt_fild07 spawn=80 allowed=yes score=24.2 risk=LOW
map=prt_maze01 spawn=5 allowed=yes score=-12.7 risk=HIGH
```

`prt_fild07`：

```text
Poporing       spawn=30 danger_contribution=3.6
Rocker         spawn=80 danger_contribution=0.5
Black Mushroom spawn=3  danger_contribution=0.0
Vocal          spawn=1  danger_contribution=5.0
aggregate_danger=9.1
```

重名查询：

```text
worldai inspect monster Goblin
→ ambiguous name; use ID or AegisName
→ 列出 1122～1126 及各自 AegisName
```

## 无控制角色证据

manual AI 前后：

```text
current_map=prt_fild08
ai_action=none
lockMap=prt_fild08
mon_control.txt SHA-256=
310dfe2c304e9a6abeba0d09cc5a5f3a2374893f7d8764a36f2893944bc835e8
```

上述值在 `top`、`recommend`、Rocker inspect、地图 inspect 前后不变。源码静态扫描确认正式插件不存在 `Commands::run`、`configModify`、`%mon_control`、`AI::`、`Task::` 或 `Plugins::addHooks` 调用。

正常 AI 模式下，执行 `status/top/recommend` 前 bot01 已开始攻击 Pupa；命令完成后仍正常完成击杀并拾取两件物品。`mon_control.txt` 前后哈希仍一致，说明推荐命令没有中断原战斗/拾取逻辑。

## 错误恢复

- 模块级临时损坏 JSON 测试通过：reload 返回清晰错误，旧 index 的 510 种怪仍可读取。
- 运行时正常 `worldai reload` 成功，输出 schema、怪物数和地图数。
- 正式 `map_index.json` 未被破坏或替换。

## 已知限制与下一步

- `spawn_count_score` 不包含地图面积和重生时间，不能解释为真实密度或 kill/hour。
- `skill_range` 暂不使用；以后应在读取真实 mob skill 数据后再加入。
- Step 2 只检查 `%maps_lut`，不验证路线可达性和旅行成本。
- 当前评分是通用近战近似模型，没有职业、属性克制、技能与装备专属收益。
- Step 3 执行推荐前必须重新验证路线、安全状态和资源状态，继续复用 OpenKore 原生 MapRoute/Combat。
