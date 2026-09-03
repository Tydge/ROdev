# RO 本地服 AI / 开发者接手说明

最后更新：2026-09-03（Asia/Shanghai）

## 1. 当前结论

这是在 Apple Silicon Mac 上运行的可游玩本地 RO：

- macOS 宿主运行 rAthena Pre-Renewal、MariaDB 和三个服务端进程。
- Parallels Desktop 中的 Windows 11 ARM 运行 kRO 客户端。
- Windows 客户端通过 Parallels Shared Network 访问宿主 `10.211.55.2`。
- 当前客户端可登录、选角、进入地图、打怪、查看装备和正常存档。
- 经验倍率为打怪 Base 2×、打怪 Job 2×、任务 2×。
- 约束：不得直接修改地图刷怪脚本（例如给 `prt_fild08` 补怪）。早期测试的 `npc/custom/bot_training_spawns.txt` 已删除。

接手时不要重新搭建，也不要替换整个客户端。优先在现有可玩基线上做单点修复。

## 2. 关键路径

macOS：

```text
项目管理目录：/Users/wangtaizhi/娱乐/RO本地服
运行根目录：/Users/wangtaizhi/Documents/Codex/2026-08-22/j/outputs/ro-local
rAthena：/Users/wangtaizhi/Documents/Codex/2026-08-22/j/outputs/ro-local/rathena
MariaDB 数据：/Users/wangtaizhi/Documents/Codex/2026-08-22/j/outputs/ro-local/database
服务端日志：/Users/wangtaizhi/Documents/Codex/2026-08-22/j/outputs/ro-local/logs
开发工作区：/Users/wangtaizhi/Documents/Codex/2026-08-22/j/work
自动化：/Users/wangtaizhi/娱乐/RO本地服/自动化
```

Windows 11：

```text
客户端：C:\Gravity\Ragnarok
游戏程序：C:\Gravity\Ragnarok\LocalRO.exe
桌面快捷方式：Local Classic RO
客户端备份：C:\Gravity\Ragnarok\LocalRO.exe.pre-lang
             C:\Gravity\Ragnarok\LocalRO.exe.broken-lang
语言修复备份：C:\Gravity\Ragnarok\_codex_backup_20260823_quest_nav
```

不要在公开记录中复制 `conf/import/inter_conf.txt` 和服务器互联配置中的口令；接手者可在本机直接读取。

## 3. 组件与端口

| 组件 | 位置 | 端口/状态 |
|---|---|---|
| MariaDB 11.4 | macOS | 127.0.0.1:3307 |
| rAthena login-server | macOS | 6900 |
| rAthena char-server | macOS | 6121 |
| rAthena map-server | macOS | 5121 |
| Windows 11 ARM | Parallels | Shared Network |
| RO 客户端 | Windows | 连接宿主 10.211.55.2 |

另有系统 MySQL 运行在 `/usr/local/mysql`；自动化只能关闭本项目 `database` 目录对应的 MariaDB，不能误杀系统 MySQL。

## 4. 主要部署流程回顾

1. 下载并编译 rAthena，使用 Pre-Renewal 数据库和脚本。
2. 在项目目录初始化独立 MariaDB 数据目录，监听 3307，导入 rAthena 数据库。
3. 设置 login/char/map 的数据库连接、互联账号和 Parallels 网络地址。
4. 在 Parallels Windows 11 中安装 2021-11 kRO 客户端资源，客户端目录为 `C:\Gravity\Ragnarok`。
5. 使用 Nemo 对 2021-11-03 Ragexe 重新打补丁，生成 `LocalRO.exe`。
6. 部署 ROenglishRE Pre-Renewal 英文资源，并针对当前客户端所读取的精确文件名补齐 `System` 文件。
7. 创建 Windows 桌面快捷方式并测试登录、角色、地图、装备与存档。

原始安装包在 `服务端运行目录/client-assets/RAG_SETUP_211105.exe`。Nemo 和 ROenglishRE 也保存在 `client-assets` 与开发工作区中。

## 5. 当前客户端基线

`C:\Gravity\Ragnarok\LocalRO.exe` SHA-256：

```text
B4CBFB979EE992AD28F32BCD0C597D2B8D90734CE9035E5ACF43DB6A183D9A80
```

该版本由原始 2021-11-03 客户端应用 17 个 Nemo 补丁生成：

```text
9, 13, 35, 36, 44, 65, 230, 231, 232,
271, 273, 276, 277, 278, 313, 326, 351
```

已确认客户端实际读取的关键路径：

```text
System/itemInfo_true.lub
system/mapInfo_true.lub
System/monster_size_effect_new.lub
system/PetEvolutionCln.lub
system/OngoingQuestInfoList_True
system/RecommendedQuestInfoList_True
System/PrivateAirplane_true.lub
```

路径大小写在 Windows 上不敏感，但下划线、后缀和 `_True` 变体必须与补丁读取路径匹配。

## 6. 已解决的问题

- 黑屏/窗口恢复：客户端和 Parallels 显示状态已能稳定进入游戏。
- `fail to connect to server`：宿主 IP、端口和 Shared Network 已配置正确。
- `ItemInfo file Init`：修复 itemInfo 精确路径与客户端补丁组合。
- `cannot open system\\mapInfo_sak.lub`：改为并部署正确 mapInfo 读取路径。
- `PetEvolutionCln_sak.lub`、`monster_size_effect_sak_new.lub` 等缺失弹窗：修正 Nemo 精确路径。
- 装备消失/变成其他装备：回退错误语言层并重建客户端后恢复；角色数据库未损坏。
- 地图名、装备名乱码：部署相符的英文 MapInfo 和 ItemInfo。
- 推荐任务 `renew_questui/reco_76.bmp` 弹窗：将仅用于宣传卡片的 `RecommendedQuestInfoList` 置空；正常任务日志独立存在。
- 正常任务日志：`questid2display.txt` 与 `OngoingQuestInfoList_True.lub` 已使用英文资源。

## 7. 当前待办

### world_ai Step 4A.1（职业技能成长顺序与五职业验收）

状态：**配置和代码已完成；五职业最终技能实战矩阵随自然成长继续**。需求来源为
`ROdev_world_ai_STEP4A1_职业技能成长顺序与五职业验收_开发任务.md`，测试记录见
`OpenKore机器人/文档/WORLD_AI_STEP4A1_TEST_REPORT.md`。

已完成：

1. 只重排技能学习顺序，不改变技能集合和最终目标等级：bot02 提前
   `SM_BASH`，bot03 转 Mage 后优先 `MG_FIREBOLT`，bot04 提前
   `AC_DOUBLE`；bot01 保持现状，bot05 做回归验证。
2. 保留 `skillsAddAuto` 为唯一正常学习入口，不直接改数据库、不使用 GM
   命令补技能。
3. ACTIVE / MOVING 期间监听 OpenKore `packet_charSkills`，仅在基线技能启用签名实际变化时重算并同步 CombatPolicy，不在每次 `AI_pre` 全量重算。
4. 新增 `SKILL_PROGRESS`、配置离线测试、实机验收矩阵和 Step 4A.1 测试报告。
5. 解决 Archer 无箭问题：现有 bot04 一次性恢复 1000 Arrow；长期使用 `buyAuto 1750`，低于等于 200 自动补到 1000。

2026-09-02 实机基线：

- bot01 Thief Job 15：`TF_DOUBLE 10`，现有普攻基线正常。
- bot02 Swordman Job 20：`SM_SWORD 10 / SM_TWOHAND 9 / SM_BASH 0`；已投入点
  不可回退，重排后从后续技能点开始学习 Bash。
- bot03 Novice Job 8：`NV_BASIC 7 / MG_FIREBOLT 0`；须先自然达到 Job 10 并
  完成既有自动转职，才能进行 Mage / Fire Bolt 实机验收。
- bot04 Archer Job 16：`AC_OWL 10 / AC_VULTURE 5 / AC_DOUBLE 0`；已投入点
  不可回退。当前另有“没有箭矢”运行问题，解决补箭/装备箭矢前无法完成
  Double Strafe 实战验收。
- bot05 Acolyte Job 10：`AL_DP 7 / AL_HEAL 2 / AL_HOLYLIGHT 1`，可用于
  Holy Light、Heal 与 world_ai 动态目标回归。

三项基线主动技能在本服 Pre-Renewal 技能树中均可直接学习，没有新增前置冲突。
完整五职业 PASS 依赖自然获得后续 Job 经验，因此 bot02 的 Bash、bot03 转 Mage 后的 Fire Bolt、bot04 的 Double Strafe 仍需随角色成长补齐实战验收。不能把“代码完成”误记为“最终验收完成”。

### 小地图标记悬停乱码

表现：地图名称正常，但鼠标放到小地图的某些标记上，提示文字仍乱码。

已经做过：

- 覆盖完整 18 个 `data/luafiles514/lua files/navigation/` 文件，包括 `krpri` 和 `krsak` 两套。
- 覆盖 `signboardlist.lub`。
- 确认 `msgstringtable.txt`、`exceptionminimapnametable.txt`、两套 `msgstring_kr*.lub` 与英文覆盖源哈希一致。
- 上述覆盖未完全解决悬停文字。

下一步建议：

1. 先取得“具体标记 + 完整乱码内容”的截图，确定是 NPC 导航名、世界地图点、任务导航点还是招牌资源。
2. 检查客户端 `data.ini` / GRF 优先级，确认松散 `data` 文件是否对该模块生效。
3. 对照具体文字，在 GRF、`navi_*`、quest navigation、viewpoint/signboard 表中反查来源。
4. 若乱码形如 `¾ÆÀÌÅÛ`，可在备份后用“非 Unicode 程序语言 = 韩语”做诊断；这可能让资源路径恢复但会显示韩文，不应直接视为最终英文化方案。
5. 不要再次整体替换 `System` 目录，否则容易重现装备 ID 映射错误和大量缺文件弹窗。

### 其他低优先级

- 少量 UI 按钮仍是韩文。
- 推荐任务宣传卡片当前为空，这是为了稳定性主动关闭，不影响经典 RO 主循环。
- 若要中文化，应先完成稳定英文基线，再按资源模块逐步翻译并逐项回归测试。

## 8. 服务端配置

Pre-Renewal 与经验倍率：

```text
conf/import/battle_conf.txt
base_exp_rate: 200
job_exp_rate: 200
quest_exp_rate: 200
castrate_dex_curve: 50
aspd_stat_curve: 80
item_rate_common: 200
item_rate_heal: 200
item_rate_use: 200
item_rate_equip: 200
item_rate_card: 3000
item_rate_mvp: 200
drops_by_luk: 0
drops_by_luk2: 100
```

Boss/MVP 对应的 common/heal/use/equip 分类也为 200，card_boss/card_mvp 为 3000。卡片优先按卡片类别统一 30×，其他 Boss/MVP 掉落与直接 MVP 奖励为 2×。LUK 使用相对倍率，不使用会抬高稀有物品基础概率的绝对加算模式。

自 2026-08-25 起，Pre-Renewal 的 DEX 咏唱改为递减收益公式：

```text
T = T0 × 50 / (50 + DEX)
```

实现位于 `src/map/skill.cpp`；可配置常数 `castrate_dex_curve` 定义在 `src/map/battle.hpp` 与 `src/map/battle.cpp`。DEX 不再单独产生零咏唱，装备、卡片和状态的咏唱增减仍在 DEX 曲线之后照常计算。

Fire Ball 的 Pre-Renewal 倍率已改为 `100% + 20% × (技能等级 - 1)`，即 Lv1 100%、Lv10 280%。实现位于 `src/map/skills/mage/fireball.cpp`，范围边缘目标原有的 75% 伤害衰减保留。

Pre-Renewal 玩家基础攻速属性曲线已设为 `c = 0.8`。有效攻速属性仍为 `AGI + DEX / 4`，在 0～200 之间应用 `T = 0.2 + 0.8 × (1 - x) / (1 + 0.8x)`，其中 `x = 有效攻速属性 / 200`；达到 200 时仍保留原版 20% 基础间隔。实现位于 `src/map/status.cpp`，配置项 `aspd_stat_curve: 80` 位于 `conf/import/battle_conf.txt`。攻速药、技能、装备修正与 190 ASPD 上限保持原样。

账号 `test`：

- AID 2000000，CID 150000。
- Group 0 普通玩家，不是 GM。
- 日志登录行会显示 `Group '0'`。
- 默认不能使用 `@resetstat`。

内置 `npc/custom/resetnpc.txt` 已在 `npc/scripts_custom.conf` 中启用。Reset Girl 位于 Prontera `(150,193)`，可重置技能（5,000 Zeny）、属性（5,000 Zeny）或两者（9,000 Zeny），不限次数。普通账号仍不能使用 `@resetstat`，也没有必要升级为 Group 99。

## 9. 启停与诊断

日常优先使用：

```text
/Users/wangtaizhi/娱乐/RO本地服/自动化/启动RO.command
/Users/wangtaizhi/娱乐/RO本地服/自动化/关闭RO.command
/Users/wangtaizhi/娱乐/RO本地服/自动化/查看RO状态.command
```

底层脚本：

```bash
/Users/wangtaizhi/娱乐/RO本地服/自动化/ro-control.sh status
/Users/wangtaizhi/娱乐/RO本地服/自动化/ro-control.sh start
/Users/wangtaizhi/娱乐/RO本地服/自动化/ro-control.sh stop
```

服务端采用独立 `screen` 会话：`ro-login`、`ro-char`、`ro-map`。如果发现同一个服务出现两个进程，先用端口和 PID 精确确认，不能对整个工作区使用宽泛 kill。

## 10. 回归测试清单

任何客户端资源改动后至少检查：

1. 启动时没有 Lua/Lub/资源缺失弹窗。
2. 登录、选角、进入地图正常。
3. 原角色装备 ID、图标、名称没有变化。
4. 地图名、装备名、任务名可读。
5. 打一只怪、换图、退出重登后存档正常。
6. 小地图标记悬停文字是否改善。

稳定性优先级高于完整汉化。每次只修改一个资源模块，修改前在 Windows 客户端目录保留可识别的备份。

## 11. Parallels 许可证

本机为 Parallels Desktop 20.4.2，当前许可证检测结果为 Pro trial，到期时间 `2026-09-05 23:59:59`。

- 官方 14 天试用不可延长。
- 购买正式完整版并激活后无需重装 Parallels、Windows 或 RO。
- 从试用版购买不能使用仅面向旧版用户的 Upgrade 许可证，必须购买 full license。
- Standard 性能够运行本项目，但官方把命令行界面列为 Pro 功能；当前自动化使用 `prlctl`。若用户购买 Standard，应复测自动化，必要时改为 GUI 启停虚拟机。
- 详见 `文档/Parallels试用到期说明.md`。

## 12. 2026-08-25 客户端非 UI 英文化复查

本轮只处理会直接显示给玩家的韩文，不处理按钮、窗口等 UI 文案，也不改贴图、音效、卡片图和武器动作等必须保持韩文的内部资源名。

已逐项备份并部署以下 7 个文件：

```text
System\Towninfo.lub
System\PrivateAirplane_true.lub
System\mapInfo_true.lub
System\itemInfo_true.lub
System\achievement_list.lub
data\luafiles514\lua files\stateicon\stateiconinfo.lub
data\lua files\stateicon\stateiconinfo.lub
```

处理结果：

- 小地图城镇标记名称由韩文替换为英文，来源是 `Towninfo.lub`。
- 成就名称与说明替换为英文；保留当前客户端完整的 361 个成就条目，没有用旧文件整体覆盖。
- 清理 1 个地图显示名、24 行物品显示文字、27 条状态效果说明和 1 个私人飞机道具显示名中的韩文。
- 物品贴图、音效、精灵、卡片图和动作文件引用中的韩文名称原样保留；这些是资源索引，不是界面文字，翻译会导致资源缺失。
- 当前 Pre-Renewal 实际脚本引用的任务与残留韩文任务表交集为 0。任务表中仍有 680 个 Renewal／旧活动韩文条目，但它们不属于当前启用的经典服任务，因此未冒险整体替换。
- `tipbox.lub` 等帮助/UI 内容仍含韩文，按“UI 不处理”的要求保留。

本次 Windows 客户端原文件备份：

```text
C:\Gravity\Ragnarok\_codex_backup_20260825_nonui_en
```

部署后 7 个文件均通过 Lua 5.1 语法检查，Mac 暂存文件与 Windows 目标文件的 SHA-256 哈希逐一一致。`LocalRO.exe` 启动后保持运行，没有出现启动即退出。仍需进入角色后人工确认小地图标记悬停、成就窗口、装备名称与状态说明的实际显示效果。
