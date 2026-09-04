# world_ai Step 4A.2 职业感知评分 测试报告

- 日期：2026-09-04（Asia/Shanghai，代码/离线测试完成）
- 仓库 commit：`a8c9e44`（工作区已含本步骤改动，待提交）
- world_ai version：`3.4.1 → 3.5.0`

## 1. 本步骤一句话

把“所有职业按同一普通攻击模型选怪、最多走 3 张图”升级为“按职业实际战斗方式选怪、免费步行最多 6 hops”，并让 DEF / MDEF / 元素 / 怪物 Mode 进入评分。

## 2. 修改前后对比

| 项 | 修改前 | 修改后 |
|---|---|---|
| 执行路线上限 | 写死 `$EXEC_MAX_HOPS = 3` | 配置 `world_ai_exec_max_hops`，默认 6，合法 1..10 |
| Mage / Acolyte 选怪 | 用法杖物理 ATK 算 `estimated_hits`，>20 硬过滤 | 用 MATK + 技能代理值，魔法阈值 24 |
| Scorer | 除 Novice 外一套统一物理公式 | `ClassProfile` + `CombatEstimate` 职业感知 |
| DEF / MDEF | 未进入评分 | 物理怕 DEF、魔法怕 MDEF（封顶归一化） |
| 元素 | 未进入评分 | Fire/Holy 走 `attr_fix.yml` 权威克制表 |
| 怪物 Mode | 索引无 | schema 3 加入 `mode`，被动 co-spawn 降险、Cast Sensor 对施法职业提险 |
| index schema | 2 | 3 |

## 3. 离线测试结果

`prove -I"OpenKore机器人/plugins/world_ai/lib" <11 个 t/*.t>` 全部通过：

```text
Files=11, Tests=236, Result: PASS
```

新增/更新用例：

- `index.t`：schema 3、`mode`（Poring 被动 / Scorpion 主动）、`element_factor`（Fire→Earth 150 / Fire→Water 50 / Holy→Undead 150）、旧 schema 2 明确拒绝且保留旧索引。
- `class_profile.t`：五职业族映射、伤害类型、战斗风格、基线技能/元素、被动技能、技能可用性（已学+槽+notMonsters）。
- `combat_estimate.t`：Mage 用 MATK 而非物攻、MATK 缺失降级为 `MAGIC_DEGRADED` 且不回退物攻、DEF 惩罚物理/MDEF 惩罚魔法、元素有利>中性>不利、无箭禁用 Double Strafe、未学技能不伪装魔法、Thief Double Attack 有限期望加成（≤1.5×）。
- `scorer.t`：新增 Mage 关键回归（低物攻+MATK+Fire Bolt 不再被 block）、DEF/MDEF 趋势、元素趋势、MELEE 远程风险 > RANGED 且 RANGED 仍为正。
- `execution_policy.t`：3/4/6 hops 通过、7 拒绝、自定义 4、`normalize_max_hops` 非法值（0/负/字符串/>10/空/undef）回退。

性能：全量 1920 候选 + 318 图 profile 评分 `elapsed_ms ≈ 58`（修改前约 22ms），仍远低于 1 秒上限。

## 4. Mage physical-ATK bug 回归证据

离线用例（`scorer.t` / `combat_estimate.t`）：

- 快照：Base 30、`attack_total=30`（法杖物攻低）、`attack_magic_avg=150`、Fire Bolt Lv6、目标 HP 1000。
- 修改前：`estimated_hits = 1000/30 ≈ 33 > 20` → 被硬过滤。
- 修改后：`estimate_mode=MAGIC_SKILL`、`raw_power=150`、`effective_power=330`、`estimated_kill_cost≈3.0` → 放行。

MATK 缺失时不回退物攻，而是 `MAGIC_DEGRADED`（等级代理 + 降级标记）。

## 5. 五机器人实机验收（已部署，初始观察通过）

已执行 `deploy-config` + `restart`，五个 bot 全部在线并确认运行 `3.5.0`。初始观察（2026-09-04 00:49，`worldai status` / `worldai top`）：

- 五个 bot 均：`plugin_version=3.5.0`、`index=loaded schema=3`、`exec_max_hops=6`、`route_budget_zeny=0 special_routes=OFF`、`degraded=no`。

| Bot | 职业 | 关键实机读数 | 结论 |
|---|---|---|---|
| bot01 | Thief (Base 25/Job 18) | `TF_DOUBLE` Lv10 被动；`matk=2 mdef=2`；普攻基线 | 3.5.0 生效 |
| bot02 | Swordman (Base 41/Job 30) | `estimate=PHYSICAL_SKILL power=217.8`（Bash） | 技能加成进入评分 |
| bot03 | Mage (Base 20/Job 16) | `atk=20` → `matk=66.5`；`estimate=MAGIC_SKILL power=199.5 kill_cost≈2.66` | **物攻误判已修复** |
| bot04 | Archer (Base 29/Job 21) | `estimate=PHYSICAL_SKILL power≈162.1`（Double Strafe） | 技能加成进入评分 |
| bot05 | Acolyte (Base 20/Job 16) | `atk=19` → `estimate=MAGIC_SKILL power=75`（Holy Light） | 魔法模型生效 |

关键回归证据（实机）：bot03 Mage 物理 ATK 仅 20，修改前按 `hp/20` 会被 20-hit 上限硬过滤；修改后按 MATK 66.5 × Fire Bolt Lv10 得 `power=199.5`，Peco Peco `kill_cost≈2.66` 正常进入 Top 1。

尚待长时观察：4/5/6-hop 实际路线到达、修改前后 Top 10 全量对比、失败 cooldown 数量变化趋势（需运行一段时间后补录）。建议按文档第 35 节灰度继续观察。

## 6. 已知限制

- `estimated_kill_cost` 是静态“kill-cost proxy”，不是真实所需攻击次数。
- 技能倍率/被动期望是保守代理值（可调 `CombatEstimate.pm` `%DEFAULTS`），不是完整伤害公式。
- 元素克制只对 Fire Bolt / Holy Light 生效，物理武器元素未跟踪。
- 怪物 Mode 解析基于 `Ai`（`MONSTER_TYPE_*`）+ `Modes` 覆盖；`Ai` 类型表硬编码在 `gen_index.py`，rAthena 若新增类型需同步。
- `spawn_count_score` 仍不是严格刷新密度（无地图面积/重生时间）。
- 本报告第 5 节实机部分待部署后补录；未提前实现 Runtime Telemetry。

## 7. 下一步建议

- 部署到 OpenKore 运行目录并逐个 bot 灰度验收，补录第 5 节实机矩阵与 cooldown 变化。
- 若 4/5/6-hop 实机出现 900 秒超时或前 8 个候选因路线政策失败，再单独调整 MapRoute 超时与 `MAX_ROUTE_PROBES_PER_COMMAND`。
- 进入 Step 4B：Runtime Combat Telemetry，用真实 TTK / EXP·min 继续校正静态模型。
