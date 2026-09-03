# world_ai Step 4A.1 技能成长与运行安全测试报告

## 结论

2026-09-03 完成 Step 4A.1 配置与代码层开发：

- bot02 / bot03 / bot04 仅重排原有 `skillsAddAuto_list`，使 Bash / Fire Bolt / Double Strafe 成为转职后优先技能，未改变技能集或最终等级。
- `packet_charSkills` 在执行或移动期间检测基线技能启用状态变化，只在策略签名改变时重新应用 CombatPolicy，不在 `AI_pre` 重算。
- `worldai status` 输出 `SKILL_PROGRESS`，`exec status` 补充死亡计数。
- Archer 使用 OpenKore 原生 `buyAuto 1750` 在箭数少于等于 200 时到 Prontera 工具商补到 1000；无箭时 `world_ai` 停止开始/继续出发。
- 普通职业的预估击杀上限收紧为 20 次，并增加长时间零击杀、反复死亡的 30 分钟目标@地图冷却。

代码层完成，但 bot02–04 尚未自然获得对应新技能，所以五职业的最终技能实战矩阵仍是随角色成长持续项，不虚报为全部 PASS。

## 实机矩阵

| 实例 | 2026-09-03 职业/等级 | 本轮结果 | 状态 |
|---|---|---|---|
| bot01 | Thief Base 22 / Job 16 | 原有 Double Attack 被动与普攻路线保持 | PASS |
| bot02 | Swordman Base 27 / Job 20 | 新评分已排除多次致死的 Savage，改选 Wolf 并击杀；Bash 等待后续技能点 | PARTIAL |
| bot03 | Novice Base 12 / Job 9 | 等待自然转 Mage；新手武器后已实杀 Lunatic | PARTIAL |
| bot04 | Archer Base 21 / Job 16 | 一次性恢复 1000 Arrow，自动装备并实际发射；Double Strafe 等待后续技能点 | PARTIAL |
| bot05 | Acolyte Base 16 / Job 11 | Holy Light 策略保持，实杀 Baby Desert Wolf；死亡已记入反馈计数 | PASS |

## 新手启动资源验证

MiraVale 作为现有 Novice 首次触发新规则：

- 服务端日志确认发放 100 Red Potion、5,000 Zeny 和 Novice Main-Gauche（物品 1243，ATK 45）。
- 实时背包为 99 Red Potion（已正常消耗 1）、6,923 Zeny。
- `autoGear` 已装备 Novice Main-Gauche，实时 ATK 为 47，同场战斗对 Lunatic 最高观察到 42 伤害并完成击杀。
- Rod [3] 仍保留在背包，转 Mage 后可由 `autoGear` 换上。
- 角色变量 `RODEV_NOVICE_STARTER_V1` 保证重登与 reload 不会重复发放。

## 弓箭补给验证

- CalebWren 登录时收到一次性迁移用 1000 Arrow。
- OpenKore 自动装备 Arrow，对 Peco Peco 造成 35–54 伤害。
- 随后背包显示 995 Arrow，证明已实际消耗 5 支，不是仅收到物品。
- 长期补给由 `buyAuto 1750` 负责，一次性迁移脚本不会重复补箭。

## 自动测试

从项目根目录执行：

```bash
prove -I"OpenKore机器人/plugins/world_ai/lib" "OpenKore机器人/plugins/world_ai/t"/*.t
```

测试包含评分回归、职业策略、运行时恢复、技能学习顺序、弓箭自动购买和新手资源脚本的静态验证。

```text
Files=9, Tests=145
Result: PASS
world_ai.pl syntax OK
ro-control.sh syntax OK
openkore-control.sh syntax OK
git diff --check PASS
```

## 未使用的捷径

未直接修改数据库技能、未使用 GM 命令补技能、未自动洗点，也未在 `world_ai` 里重新实现技能树或施法 AI。
