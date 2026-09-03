# world_ai Step 4A.1 技能成长与运行安全测试报告

## 结论

2026-09-03 完成 Step 4A.1 配置与代码层开发：

- bot02 / bot03 / bot04 仅重排原有 `skillsAddAuto_list`，使 Bash / Fire Bolt / Double Strafe 成为转职后优先技能，未改变技能集或最终等级。
- `packet_charSkills` 在执行或移动期间检测基线技能启用状态变化，只在策略签名改变时重新应用 CombatPolicy，不在 `AI_pre` 重算。
- `worldai status` 输出 `SKILL_PROGRESS`，`exec status` 补充死亡计数。
- Archer 使用 OpenKore 原生 `buyAuto 1750` 在箭数少于等于 200 时到 Prontera 工具商补到 1000；无箭时 `world_ai` 停止开始/继续出发。
- 普通职业的预估击杀上限收紧为 20 次，并增加长时间零击杀、反复死亡的 30 分钟目标@地图冷却。

代码层完成。经 2026-09-03 22:15 实机复核，bot02 / bot03 / bot04 的 Bash / Fire Bolt / Double Strafe 均已自然习得并实际施放（见「实机施法证据」），三项由 PARTIAL 升级为 PASS。

## 实机矩阵

| 实例 | 2026-09-03 职业/等级 | 本轮结果 | 状态 |
|---|---|---|---|
| bot01 | Thief Base 25 / Job 18 | 原有 Double Attack 被动与普攻路线保持 | PASS |
| bot02 | Swordman Base 39 / Job 28 | 已学 SM_BASH Lv8，实机对 Wolf 施放 Bash 253–294 伤害 | PASS |
| bot03 | Mage Base 14 / Job 7 | 已自然转 Mage，MG_FIREBOLT Lv6，实机对 Baby Desert Wolf 施放 72–96 伤害 | PASS |
| bot04 | Archer Base 27 / Job 20 | 已学 AC_DOUBLE Lv4，实机对 Peco Peco / Drops 施放 Double Strafe 150–204 伤害 | PASS |
| bot05 | Acolyte Base 20 / Job 15 | Holy Light 策略保持，实杀 Baby Desert Wolf；死亡已记入反馈计数 | PASS |

## 实机施法证据（22:15 复核）

技能名在 OpenKore 控制台以韩文显示，括注英文对照。`[ 56/ 34]` 为 `SP/HP` 百分比，施法消耗 SP 证明为真实技能释放而非普攻。

### bot02 · EthanRowe（Swordman）— Bash（배쉬）

DB `skill` 表 id=5（SM_BASH）lv=8；`world_ai` 切到 `SINGLE_TARGET`，`SYNC slot=0 handle=SM_BASH changed=yes`（把 Wolf 注入攻击槽）。

```text
[2026.09.03 22:06:50.31] [ 56/ 34] You use 배쉬 (Lv: 8) on Monster Wolf (0) (Dmg: 253) (Delay: 427ms)
[2026.09.03 22:08:13.84] [ 58/ 29] You use 배쉬 (Lv: 8) on Monster Wolf (0) (Dmg: 294) (Delay: 427ms)
[2026.09.03 22:14:18.39] [100/ 82] You use 배쉬 (Lv: 8) on Monster Wolf (1) (Dmg: 294) (Delay: 427ms)
[2026.09.03 22:14:19.49] [100/ 65] You use 배쉬 (Lv: 8) on Monster Wolf (1) (Dmg: 284) (Delay: 427ms)
```

对照普攻约 40–80，Bash 稳定 253–294，且 SP 从 88 一路降到 29，确为施法。

### bot03 · MiraVale（Mage）— Fire Bolt（화이어 볼트）

DB `skill` 表 id=19（MG_FIREBOLT）lv=6；`world_ai` 切到 `SINGLE_TARGET`，`SYNC slot=0 handle=MG_FIREBOLT changed=yes`。

```text
[2026.09.03 21:55:59.96] [ 78/ 82] You use 화이어 볼트 (Lv: 6) on Monster Baby Desert Wolf (0) (Dmg: 72) (Delay: 683ms)
[2026.09.03 22:04:16.58] [ 68/ 82] You use 화이어 볼트 (Lv: 6) on Monster Drops (0) (Dmg: 96) (Delay: 683ms)
[2026.09.03 22:09:39.72] [ 68/ 82] You use 화이어 볼트 (Lv: 6) on Monster Baby Desert Wolf (1) (Dmg: 84) (Delay: 683ms)
```

### bot04 · CalebWren（Archer）— Double Strafe（더블 스트레이핑）

DB `skill` 表 id=46（AC_DOUBLE）lv=4；`world_ai` 切到 `SINGLE_TARGET`，`SYNC slot=0 handle=AC_DOUBLE changed=yes`。

```text
[2026.09.03 18:13:01.88] [ 90/ 63] You use 더블 스트레이핑 (Lv: 3) on Monster Peco Peco (0) (Dmg: 150) (Delay: 520ms)
[2026.09.03 22:08:47.44] [ 90/ 81] You use 더블 스트레이핑 (Lv: 3) on Monster Drops (1) (Dmg: 180) (Delay: 520ms)
[2026.09.03 22:11:39.85] [ 71/ 82] You use 더블 스트레이핑 (Lv: 4) on Monster Peco Peco (3) (Dmg: 166) (Delay: 519ms)
[2026.09.03 22:11:45.54] [ 58/ 47] You use 더블 스트레이핑 (Lv: 4) on Monster Peco Peco (1) (Dmg: 182) (Delay: 519ms)
```

### 技能自然成长时间线（`skillsAddAuto` 重排生效）

每次升级触发 `packet_charSkills` 轻量刷新（`COMBAT_REFRESH reason=learned_skill_state_changed`），无需重新选图：

- bot02：11:35 SM_BASH Lv4 → 12:13 Lv5 → 12:52 Lv6 → 16:49 Lv7 → 17:42 Lv8（现 Lv8）
- bot03：15:54 转 Mage 后 MG_FIREBOLT Lv2 → 15:55 Lv3 → 16:17 Lv4 → 16:45 Lv5 → 17:52 Lv6（现 Lv6）
- bot04：10:23 AC_DOUBLE Lv1 → 12:27 Lv2 → 12:57 Lv3 → 22:11 Lv4（现 Lv4）

四步链路「已学 → 策略切换 SINGLE_TARGET → 攻击槽注入 → 实际施放造成伤害」在三个角色上均已完整走通。

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
Files=9, Tests=147
Result: PASS
world_ai.pl syntax OK
ro-control.sh syntax OK
openkore-control.sh syntax OK
git diff --check PASS
```

## 未使用的捷径

未直接修改数据库技能、未使用 GM 命令补技能、未自动洗点，也未在 `world_ai` 里重新实现技能树或施法 AI。
