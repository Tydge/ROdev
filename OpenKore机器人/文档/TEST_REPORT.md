# OpenKore Bot 01 测试报告

测试日期：2026-08-30～2026-08-31

| ID | 项目 | 当前结果 | 证据/备注 |
| --- | --- | --- | --- |
| T0 | OpenKore 原生启动 | 通过 | Apple Silicon 原生编译，OpenKore 可加载 control/tables/fields |
| T1 | 登录 Login Server | 通过 | 独立普通账号认证成功，正确取得服务器列表 |
| T2 | 进入 Char Server | 通过 | PIN 验证通过，正确识别 `KoreHelper` |
| T3 | 进入 Map Server | 通过 | 正确进入地图、读取坐标、HP/SP、NPC 与物品状态 |
| T4 | Windows 客户端看到 Bot | 通过 | 玩家已从 Windows 图形客户端在同地图看到 `KoreHelper` |
| T5 | 手工移动 | 通过 | AI manual 下从 `(53,111)` 移动到 `(55,110)`，坐标回报一致 |
| T6 | 白名单自动攻击 | 通过（短测） | 当前优先攻击 Poring；Drops/Fabre/Lunatic 按 Base 等级解锁，其他怪物由 `all 0` 默认忽略 |
| T7 | 自动拾取 | 通过（短测） | Lunatic 死亡后连续拾取 3 件掉落物 |
| T8 | 喝药/坐下恢复 | 通过（短测） | HP 低时会使用物品 ID 569/501；坐下阈值保留为后备 |
| T9A | 装备公开 | 通过 | 地图服回报 `Your Equipment information is now open to the public.` |
| T9B | 初期战斗强化 | 通过（短测） | 合法分配已有 64 属性点，换普通新手装备；对 Poring 单击约 20–36、承伤约 3，连续击杀未死亡 |
| T11 | 自动卖货 | 通过 | 负重阈值自动触发，能从 `prt_fild08` 到 `prt_in (126,76)` 出售白名单物品并安全保留卡片、装备、驯养物和 Empty Bottle |
| T12 | 自动补药 | 通过 | 首轮出售后自动购买 30 瓶 Red Potion；已有 30 瓶时会正确跳过购买 |
| T13 | 卖货后返回 | 通过 | 交易结束后自动穿过 Prontera 返回 `prt_fild08` 并恢复打怪 |
| T14 | MariaDB 后台持久化 | 通过 | 数据库已改为独立 `ro-db` screen 会话，自动化命令结束后仍持续运行 |
| T15 | 角色愿望与自动一转 | 通过 | 固定路线为 `Novice → Thief → Assassin`；实测 Novice Job 10 自动补齐 Basic Skill 9 并直转 Thief，提示下一目标 Assassin |
| T16 | 自动技能成长 | 通过（短测） | 转职后 Thief Job 2 自动把第 1 点加入 Double Attack；跨职业技能序列与全部前置关系已校验 |
| T17 | 自主装备决策 | 通过（短测） | 人工卸下右手后，`autoGear` 排除职业不符的 Novice Main-Gauche 和未鉴定装备，自动选择并装备 Thief 可用的 Knife [3] |
| T18A1 | 原生单跳跨地图 | 通过 | `worldtest nav prt_fild07`：`prt_fild08 → prt_fild07`，22.5 秒；插件只调用 `Commands::run("move …")`，实测任务为 `Task::MapRoute` |
| T18A2 | 原生多地图连续寻路 | 通过 | `worldtest nav prt_fild04`：`prt_fild08 → prt_fild07 → prt_fild05 → prt_fild04`，114.4 秒；未提供中间地图或 Portal 坐标 |
| T18B1 | 按怪选图并确认击杀 | 通过 | 从 `prt_fild08` 执行 `worldtest hunt Rocker`；按刷新量 80/70 选择 `prt_fild07`，16.0 秒到图，随后发现并开始攻击 Rocker，91.7 秒时收到 `KILL_CONFIRMED` |
| T18R | 实验状态恢复 | 通过 | `worldtest stop` 后 `lockMap` 恢复为 `prt_fild08`，`mon_control.txt` 没有残留 Rocker 条目；临时怪物放行仅存在于内存 |
| T9 | 死亡复活 | 通过（短测） | 两次死亡均在约 4 秒后回固定地图并继续战斗 |
| T10 | 8 小时稳定性 | 未开始 | 先观察一次短时战斗，再进行 soak |

## 本次兼容修正

1. OpenKore 构建脚本加入 Homebrew readline 与当前 macOS SDK 的 Perl CORE 路径。
2. 构建过程强制使用原生 `python3`，避免误用 x86_64 Anaconda Python 生成错误架构的 XSTools。
3. 为 2021-11-03 kRO receiver 绑定 `0x0AC4` 登录成功包。
4. 使用 2021-11-03 dated recvpackets，解决登录包长度无法识别。
5. 按 rAthena 当前 `CHARACTER_INFO` 结构将 `charBlockSize` 校正为 175。
6. 新增仅绑定角色 ID `150002` 的职业路线脚本；Job 10 自动一转、Thief Job 50 自动二转，并在门槛处补齐规划技能以避免残留技能点。
7. OpenKore 改用内部技能代号配置完整 Novice、Thief、Assassin 技能序列，避免 kRO 韩文技能名导致匹配失败。
8. 新增共享 `autoGear` 插件及由 Pre-Renewal 装备库生成的 2017 条评分目录，供当前与后续机器人自主换装。

## 下一步验收

继续观察 10–20 分钟，确认初期阶段能持续战斗、喝药且不再频繁死亡；再从 Windows 客户端右键确认装备列表可见。短测通过后再安排 8 小时稳定性测试。跨地图实验已经通过，但正式动态练级系统仍应在后续阶段再接入自动生成的怪物地图索引与风险/收益评分。
