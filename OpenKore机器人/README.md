# RO 本地服 OpenKore 机器人

当前已完成五个无图形机器人：`KoreHelper`、`EthanRowe`、`MiraVale`、`CalebWren`、`NoraEllis`。每个角色使用独立普通账号，直接从 macOS 连接本机 rAthena，不依赖 Parallels 或 Windows 图形客户端。

## 一键使用

```bash
# 启动 RO 后端和机器人，不启动 Windows 虚拟机
"/Users/wangtaizhi/娱乐/RO本地服/OpenKore机器人/脚本/openkore-control.sh" start

# 查看指定机器人的实时控制台；省略 ID 时默认 bot01
# 退出查看但保持运行：按 Control+A，再按 D
"/Users/wangtaizhi/娱乐/RO本地服/OpenKore机器人/脚本/openkore-control.sh" console
"/Users/wangtaizhi/娱乐/RO本地服/OpenKore机器人/脚本/openkore-control.sh" console bot03

# 只关闭机器人
"/Users/wangtaizhi/娱乐/RO本地服/OpenKore机器人/脚本/openkore-control.sh" stop

# 关闭机器人和 RO 后端，不改变 Windows 虚拟机状态
"/Users/wangtaizhi/娱乐/RO本地服/OpenKore机器人/脚本/openkore-control.sh" stop-all

# 查看完整状态（后端 + 虚拟机 + 机器人进程 + 所有机器人角色信息）
"/Users/wangtaizhi/娱乐/RO本地服/OpenKore机器人/脚本/openkore-control.sh" status
```

调试协议或手动控制时使用：

```bash
"/Users/wangtaizhi/娱乐/RO本地服/OpenKore机器人/脚本/openkore-control.sh" start-manual
```

### 与 RO 启停脚本的联动

`自动化/` 里的三个 `.command`（背后是 `自动化/ro-control.sh`）已与机器人联动：

- 双击 `启动RO.command`：先启动数据库、三服务端和 Windows 虚拟机，随后自动拉起机器人。
- 双击 `关闭RO.command`：先优雅关闭机器人，再关闭三服务端、数据库并暂停虚拟机。
- 双击 `查看RO状态.command`：额外输出机器人进程状态和所有机器人的角色信息。

> 日常只需双击 `自动化/` 里的 `.command` 即可同时管理 RO 服务和机器人，不必分别操作。
> 只想单独控制机器人时，用上面的 `openkore-control.sh` 命令即可。

### 底层子命令

以下命令主要供脚本联动或排查使用，一般无需手动执行：

```bash
# 只启动机器人进程，不碰 RO 后端（由启动RO.command 内部调用）
"/Users/wangtaizhi/娱乐/RO本地服/OpenKore机器人/脚本/openkore-control.sh" start-bot

# 单独启动或关闭一个实例
"/Users/wangtaizhi/娱乐/RO本地服/OpenKore机器人/脚本/openkore-control.sh" start-one bot03
"/Users/wangtaizhi/娱乐/RO本地服/OpenKore机器人/脚本/openkore-control.sh" stop-one bot03

# 只看机器人进程状态（screen 会话是否在运行）
"/Users/wangtaizhi/娱乐/RO本地服/OpenKore机器人/脚本/openkore-control.sh" bot-status

# 只看所有机器人角色信息（实时读数据库）
"/Users/wangtaizhi/娱乐/RO本地服/OpenKore机器人/脚本/openkore-control.sh" bot-info
```

## 当前行为

- 五个实例均由 `world_ai` 按实时等级、职业、攻防、怪物强度、同图风险和免费路线选择练级目标；只用原生刷怪，不修改地图刷怪。
- 评分层排除 MVP/Boss、明显越级和预估超过 20 次攻击才能击杀的目标；实战中长时间零击杀或反复死亡时，会将该怪物@地图冷却 30 分钟后自动重新选择。
- 普攻、自动拾取、小范围巡逻均已开启。
- HP 低于 55% 时使用物品 ID 569/501（Novice Potion / Red Potion）；低于 45% 且没有合适动作时坐下，恢复到 90%。使用 ID 是为了避免 OpenKore 的韩文物品表导致英文名称匹配失败。
- 死亡后使用 OpenKore 默认复活流程，然后返回当前 `world_ai` 目标地图。
- 负重达到 48% 时自动停止打怪，前往 Prontera 室内工具商人出售普通掉落；Red Potion 少于 10 瓶时补到 30 瓶。Archer 的 Arrow 少于等于 200 支时会到同一商人自动补到 1000 支，完全无箭时 `world_ai` 暂停出发。
- 当前出售范围：Jellopy、Clover、Sticky Mucus、Feather，以及超过 20 个的 Apple、超过 10 个的 Carrot。卡片、驯养物、Empty Bottle、药水和所有自有装备均受保护。
- 五条固定职业愿望均会在 Novice Job 10 自动一转、第一职业 Job 50 自动二转并跳过转职任务：Assassin、Knight、Wizard、Hunter、Priest。完整设定见 `角色档案/`。
- 属性按生存与匕首输出分阶段自动成长，最终目标为 STR 90 / AGI 90 / VIT 30 / INT 1 / DEX 50 / LUK 1。
- 技能按各职业完整规划由 `skillsAddAuto` 自然分配；Swordman 优先 Bash、Mage 优先 Fire Bolt、Archer 优先 Double Strafe，不改变原有技能集和最终等级。活动执行期间首次学会基线技能时，`world_ai` 会轻量刷新策略，无需重新选图。
- 已启用共享装备决策器 `autoGear`：登录、转职、拾到装备或装备被卸下后，会根据 rAthena 的完整装备目录判断职业、等级、鉴定状态、基础攻防、精炼和插槽，再选择确实更好的装备。已插卡装备和无法可靠评分的自定义装备默认不会被替换。
- 新建 Novice 首次登录一次性获得 5,000 Zeny、100 个 Red Potion 和 ATK 45 的 Novice Main-Gauche。转职后 `autoGear` 会切换为背包中更适合职业的武器，职业武器保留 1 件不会在新手阶段被卖掉。
- 自动交易、组队和玩家摆摊尚未开启；自动出售、补药、属性成长、技能成长和职业路线已经开启。

## 原生跨地图与按怪选图实验

仓库保留最小实验插件 `world_ai_test` 的源码，启动脚本仍会把它链接到 OpenKore 运行目录，但 bot01 的 `sys.txt` 已不再自动加载它。它只用于历史验证；Step 3B 运行时应只加载正式 `world_ai`，避免两个插件同时清理移动状态。

```text
worldtest nav <map>
worldtest hunt <monster>
worldtest status
worldtest stop
```

当前怪物测试表只有 Poring 和 Rocker。`hunt` 期间会临时切换 `lockMap`，并仅在内存中放行目标怪；`worldtest stop`、失败或卸载插件时会恢复原值。2026-08-31 已实测单跳、多地图连续寻路和 Rocker 击杀，证据见 `文档/TEST_REPORT.md`。

## world_ai 动态练级推荐与受控执行

五个实例已启用正式 `world_ai`。它从 OpenKore 当前 `$char` / `$field` 读取实时角色状态，使用 rAthena Pre-Renewal 静态索引生成可解释的怪物×地图推荐，并用 OpenKore 原生 `Task::CalcMapRoute` 做只读路线预检或受控真实执行：

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

`route` 与 `recommend reachable` 仍然完全只读。`worldai execute` 使用零费用、普通 portal/步行政策选择目标，纯内存覆盖 `lockMap`、目标怪物和匹配技能槽，并把移动与战斗交给 OpenKore 原生流程。自动执行只在当前任务结束、失败或反馈冷却后重新选择；`exec stop`、错误、超时或插件卸载会恢复原状态。

需要单独以 manual AI 测试 bot01 时可执行：

```bash
"/Users/wangtaizhi/娱乐/RO本地服/OpenKore机器人/脚本/openkore-control.sh" start-one bot01 manual
```

## 运行目录

- OpenKore 源码：`/Users/wangtaizhi/Documents/Codex/2026-08-22/j/outputs/ro-local/openkore`
- 本服 overlay：`/Users/wangtaizhi/Documents/Codex/2026-08-22/j/outputs/ro-local/openkore-local`
- Bot 01 配置：`/Users/wangtaizhi/Documents/Codex/2026-08-22/j/outputs/ro-local/openkore-local/instances/bot01/control`
- Bot 01 日志：`/Users/wangtaizhi/Documents/Codex/2026-08-22/j/outputs/ro-local/openkore-local/instances/bot01/logs`
- Bot 02～05 使用相同目录结构：`instances/bot02` 至 `instances/bot05`

账号密码与 PIN 只保存在本机 Bot 配置中。不要把 `control/config.txt` 上传到 Git 或发给他人。

## 已对齐的协议参数

- rAthena：Pre-Renewal
- PACKETVER：`20211103`
- 登录/角色/地图端口：`6900 / 6121 / 5121`
- OpenKore serverType：`kRO_RagexeRE_2021_11_03`
- 实际角色块长度：`175`
- dated recvpackets：`kRO/Ragexe_2021_11_03`

## 已知限制

- OpenKore 的 kRO 表会在自己的终端里显示少量韩文地图别名；这不影响 Windows 客户端，也不影响寻路或战斗。
- OpenKore 的库存变更提示有时显示的是单次变化而非整批出售总数；以出售完成后的背包和 Zeny 为准。
- 角色创建协议在本组合中未稳定完成，因此首个角色由本机数据库按 rAthena 新手默认值创建；日常登录、选角、进地图和移动协议均已验证。
- 尚未完成 8 小时稳定性测试；Windows 图形客户端已确认 Bot 可见。详见测试报告。
- 当前配置 5 个 Bot；已验证并发登录和初始战斗，尚未完成五实例 8 小时稳定性测试。
- `world_ai_test` 源码保留为历史实验，但 bot01 的启动列表只启用正式 `world_ai`，避免两个执行插件互相清理移动状态。
- `autoGear` 第一版保守管理武器、盾牌、衣服、披肩、鞋和头部装备；饰品与复杂脚本特效尚不参与自动比较，以免仅按表面数值误判。
