# world_ai Step 4A 职业战斗策略测试报告

## 结论

2026-09-02（Asia/Shanghai）完成 Step 4A 代码、离线测试和可用角色的灰度实机验证。

已确认的完整链路为：

```text
world_ai 最终执行目标 Baby Desert Wolf
-> Acolyte 职业族 + 运行时已学 AL_HOLYLIGHT Lv1
-> 匹配现有 attackSkillSlot_0
-> 内存中将 Baby Desert Wolf 追加到 monsters
-> OpenKore 原生 Attack AI 施放 Holy Light
-> 击杀目标
-> exec stop / plugin unload 恢复原 monsters
```

没有自实现施法、吟唱、距离追踪、SP 判断、冷却或战斗状态机。`attackAuto 2` 与 `attackUseWeapon 1` 保持不变。

## 版本与环境

- 项目基线 commit：`7ee24ae`（Step 4A 为当前未提交工作树）。
- world_ai 版本：`3.3.0`。
- OpenKore commit：`51de1ddfc4449ae5217f6886de702f87ca934030`。
- rAthena 运行时报告 commit：`9ee78480020d95b30ef22c0c2685de1439e50ff9`。
- 模式：Pre-Renewal；5 个 OpenKore 实例与服务端均在本机运行。

## 实现核对

已阅读本机 OpenKore 实现：

- `FileParsers::parseConfigFile` 将技能块解析为 `attackSkillSlot_0`、`attackSkillSlot_0_monsters` 等扁平运行时键。
- `AI::Attack` 依次检查已配置技能槽、self condition、`maxUses`、`maxAttempts`、`monsters`、`notMonsters` 和 target condition，不匹配时保留 weapon attack fallback。
- `$char->{skills}` 以 skill handle 为键，`lv > 0` 代表当前角色真实已学。
- `Misc::configModify` 会写回 `config.txt`，因此本实现只直接修改 `%config`，不调用该 API。

## 角色与技能现状

| 实例 | 职业 / 等级（测试时） | 运行时已学技能 | 策略判定 |
|---|---|---|---|
| bot01 | Thief, Base 19 / Job 14 | `NV_BASIC 9`, `TF_DOUBLE 10`, `TF_MISS 3` | `THIEF_FAMILY / NORMAL_ATTACK_BASELINE`，不生成主动技能 |
| bot02 | Swordsman, Base 24 / Job 18 | `NV_BASIC 9`, `SM_SWORD 10`, `SM_TWOHAND 7`；未学 `SM_BASH` | Bash 槽已配置，但策略以 `skill_not_learned` 拒绝启用 |
| bot03 | Novice, Base 9 / Job 7 | `NV_BASIC 6`；未转 Mage，未学 `MG_FIREBOLT` | `UNSUPPORTED / NORMAL_ATTACK_BASELINE` |
| bot04 | Archer, Base 20 / Job 16 | `NV_BASIC 9`, `AC_OWL 10`, `AC_VULTURE 5`；未学 `AC_DOUBLE` | 现有 Double Strafe 槽保留，策略以 `skill_not_learned` 拒绝启用 |
| bot05 | Acolyte, Base 13 / Job 6 | `NV_BASIC 9`, `AL_DP 5`, `AL_HOLYLIGHT 1` | `AL_HOLYLIGHT` 成功匹配并实机施放 |

bot05 当时未学 `AL_HEAL`，因此无法做 Heal 实际施放验收；代码和运行时覆盖均未读写任何 `useSelf_skill` 键。

## 原始与应用后的技能槽

bot05 原始：

```text
attackSkillSlot_0 = AL_HOLYLIGHT
attackSkillSlot_0_sp = > 25%
attackSkillSlot_0_dist = 8
attackSkillSlot_0_maxDist = 9
attackSkillSlot_0_maxAttempts = 4
attackSkillSlot_0_monsters = Poring, Pupa, Fabre, Lunatic, Drops, Chonchon, Willow, Roda Frog
```

`worldai execute` 选中 `Baby Desert Wolf (1107) @ moc_fild01` 后：

```text
attackSkillSlot_0_monsters = Poring, Pupa, Fabre, Lunatic, Drops, Chonchon, Willow, Roda Frog, Baby Desert Wolf
```

只有 `monsters` 在内存中改变；SP、距离、技能等级和其他条件未由 world_ai 改写。如果槽的 `monsters` 原本为空（代表允许全部目标），运行时层不会反向把它缩窄为单目标。

## 实机战斗证据

- bot05 到达 `moc_fild01` 后进入 `ACTIVE`。
- 日志记录 `target_attack_started monster=Baby Desert Wolf`。
- OpenKore 原生战斗日志记录 Holy Light Lv1 造成 28 / 38 / 39 / 31 / 32 等伤害。
- 首只动态目标被 Holy Light 击杀，world_ai 记录 `target_kill_confirmed ... kills=1`。
- 目标攻击打断过长吟唱时，原槽曾连续重试。为满足保守失败回退，bot02–05 的基线主动技能槽均增加原生 `maxAttempts 4`。
- 重启 bot05 加载新槽后，对 Lunatic 实测为 3 次 Holy Light 成功 + 1 次吟唱失败，随后 OpenKore 自动切换普通攻击并完成击杀，证明 fallback 有效。

## 恢复验证

### exec stop

执行活动时运行 `worldai exec stop`：

- 输出 `restored=yes`。
- `combat inspect` 显示 `runtime_override=OFF`。
- `attackSkillSlot_0_monsters` 精确恢复为原 8 种怪列表。
- 当时已在进行的 OpenKore 战斗没有被清空；技能不再匹配动态目标后转为普攻。

### plugin unload

在 `MOVING` 且动态技能覆盖活动时执行 `plugin unload world_ai`：

- 输出 `runtime_restored=yes`。
- OpenKore 原生 `conf attackSkillSlot_0_monsters` 随后显示原 8 种怪列表，没有残留 `Baby Desert Wolf`。
- 重新加载 world_ai 3.3.0 成功。

## 自动测试

```text
prove -I"OpenKore机器人/plugins/world_ai/lib" OpenKore机器人/plugins/world_ai/t/*.t

Files=8, Tests=133
Result: PASS
```

新增覆盖：

- Mage 已学 / 未学 Fire Bolt。
- Archer Double Strafe、Acolyte Holy Light、Swordman Bash。
- Thief 纯普攻基线。
- 已学但未配置技能槽时不自动发明技能。
- `notMonsters` 冲突时不擅自解除排除。
- 过滤器追加、去重、空过滤不缩窄、重复 apply 拒绝和精确恢复。
- 无主动技能策略的完整 apply / restore 生命周期。

另外已通过：

```text
perl -c OpenKore机器人/plugins/world_ai/world_ai.pl
git diff --check
```

`perl -c` 使用了本机 OpenKore `src` 与 `src/deps` 依赖路径。

## 当前限制与剩余实机验收

任务文档对角色现状的四个前提与实际运行状态不符：

1. bot03 仍是 Novice，尚未转 Mage，因此不能进行“Fire Bolt 对新动态目标”实战验收。
2. bot04 尚未学 `AC_DOUBLE`，因此不能实战验收 Double Strafe 动态目标。
3. bot02 尚未学 `SM_BASH`，因此不能实战验收 Bash 动态目标。
4. bot05 尚未学 `AL_HEAL`，当前模板也没有非空 Heal 自疗槽，因此不能验收文档所述的“原有 Heal 自疗”。world_ai 本次不触及 `useSelf_skill`，所以不会破坏未来加入的辅助槽。

按最高原则，本次没有为了测试而改技能加点、用 GM 强制授予技能或从数据库假定技能。这些项目应在角色按原成长系统学会对应技能后重跑；在此之前，代码层 Definition of Done 已满足，但“bot02–04 各自实战使用技能”和“原有 Heal 自疗”的运行前提尚未满足。

## 本次明确未做

没有实现元素克制选技能、其他 Bolt、范围技能、箭矢属性切换、陷阱、Heal Bomb、自动技能加点、伤害模拟、战斗遥测或动态重新选图。
