# World AI Step 3B 测试报告

日期：2026-09-01

## 范围

Step 3B 只为 bot01 增加手动一次性真实执行：

```text
worldai execute
worldai exec status
worldai exec stop
```

本阶段不定时重新评分，不让 bot02～bot05 自动换图，也不修改职业评分模型。

## 自动化测试

```text
Files=6, Tests=83
Result: PASS
```

覆盖索引、评分、性能、路线三态、执行路线参数、政策拒绝、候选回退、纯内存覆盖和精确恢复。完整评分 1920 个怪物×地图候选约 23 ms。

使用 OpenKore `src`、`src/deps` 和插件 `lib` 路径执行 `perl -c`，`world_ai.pl syntax OK`。

## 路线政策

执行预检固定：

```text
budget=0
noGoCommand=1
noTeleSpawn=1
noWarpItem=1
noAirship=1
```

并拒绝 NPC、Zeny、票券、command、airship、save teleport、warp item。实际 MapRoute 使用同类约束，运行态把 `route_maxWarpFee`、`route_warpByItem`、`saveMap_warp` 固定为 0，并在 MapRoute 每次产生或重算 mapSolution 时再次复核。

实测从南门执行时，普通推荐仍是 `Spore @ pay_fild08`。此前 Step 3A 的默认路线会选一次 2000z NPC warp；Step 3B 的约束计算改为找到一条六跳免费路线：

```text
hops=6 zeny=0 tickets=0 npc=0 command=0
airship=0 save_teleport=0 warp_item=0
```

## 纯内存与恢复

manual AI 下执行后状态进入 `MOVING`，`lockMap=pay_fild08`、旧 lockMap 坐标清空、Spore 临时放行；执行前、活动中、`exec stop` 后的 `config.txt` 与 `mon_control.txt` 哈希不变。

正式运行中的文件时间戳也没有因 execute/stop 改变。执行器没有调用 `configModify`；OpenKore 进程启动本身可能由其他既有插件重排或保存 config，因此跨进程哈希不能用于判断执行器写盘，测试采用同一进程内哈希和 mtime。

`exec stop` 已在 `MOVING` 和 `ACTIVE + attack` 两种状态实测：

- MOVING：只取消执行器拥有的 MapRoute，恢复原 lockMap 与怪物条目。
- ACTIVE + attack：立即恢复运行态目标，但保留当前原生战斗；战斗结束后由南门 lockMap 接管。

### 卸载即恢复（fail-open）

在 `ACTIVE + attack`（正在 pay_fild08 攻击 Spore，攻击计数 6、击杀计数 4）时直接从 OpenKore 控制台卸载 `world_ai`：

```text
[WORLD_AI] [PLUGIN] unloaded previous_exec_state=ACTIVE runtime_restored=yes
Plugin world_ai unloaded.
```

当前那场 Spore 战斗未被清空，打完并升到 Job Lv.13 后坐下回血；随后原生 lockMap 流程接管，输出 `Calculating lockMap route to: prt_fild08` 并沿 `pay_fild08 -> payon` 返程，最终回南门。恢复目标是 `prt_fild08` 而非临时 `pay_fild08`，证明卸载精确恢复了原 lockMap。

`config.txt`（mtime 20:05:20，即进程重启时刻）与 `mon_control.txt`（mtime 08-31 01:55）在 ACTIVE→卸载窗口内时间戳与 SHA-256 均未变化，卸载恢复只改内存、不写盘。

正反两面对照：执行活动期间 `route_maxWarpFee` 被锁为 0，原生卖货返程全程走免费 portal；卸载后该值恢复为空（原生不限费），原生返程最后一段从 payon 使用了 1200z Kafra 传送。运行态约束与恢复都精确生效。

## OpenKore 原生流程

执行前正好触发一次既有 48% 负重卖货流程。`worldai execute` 在 sellAuto 路线上正确拒绝，原生流程完成：

```text
prt_fild08 -> prontera -> prt_in
出售 9 种物品 / 获得 448 Zeny
Auto-sell completed
Auto-buy completed
prt_in -> prontera -> prt_fild08
```

这同时确认原有卖货、补药和 lockMap 返回链条没有被 Step 3B 破坏。

## 真实执行结果

首次完整免费路线沿途发现了本服 portal 实际落点，OpenKore 更新 `portals.txt` 并重建 portal LOS。300 秒工程上限在 `pay_gld` 触发，执行器正确 fail open、恢复南门并停止自己的路线。根据该证据把多图移动上限调整为 900 秒。

从 `pay_gld` 继续执行后：

```text
pay_gld -> payon -> pay_fild08
runtime_route_policy=ALLOWED
ACTIVE map=pay_fild08 monster=Spore
target_attack_started
target_kill_confirmed kills=1
```

到达约 60 秒，确认至少两次 Spore 攻击开始和一次击杀。战斗、喝药、拾取均由 OpenKore 原生逻辑完成。

随后从南门重新执行一条不间断完整路线。实际经过：

```text
prt_fild08 -> moc_fild01 -> pay_fild04
-> moc_fild02 -> pay_gld -> payon -> pay_fild08
```

总到达时间约 404.6 秒；每次换图后 MapRoute 都重新计算剩余路线，执行器逐次复核为 `0z / 0 tickets / npc=0 / command=0 / airship=0 / teleport=0 / warp_item=0`。到达后再次确认 Spore 攻击和击杀。

在执行器保持 `ACTIVE` 时手动触发 OpenKore 原生命令 `autosell`，机器人从 `pay_fild08` 沿免费路线回到 Prontera 室内商人，出售 7 种物品；`Auto-sell` 与 `Auto-buy` 均完成。完成后 OpenKore 输出：

```text
Calculating lockMap route to: pay_fild08
```

并开始从 `prt_in -> prontera -> prt_fild08` 返回新的练级地图，而不是恢复前的固定南门工作地点。

## 部署状态与边界

- 只有 bot01 加载正式 `world_ai`；`world_ai_test` 已从 bot01 启动列表移除。
- bot02～bot05 没有接入执行器。
- Step 3B 不后台重选地图；Base 等级变化不会自动触发 execute。
- 当前 Scorer 仍是通用普通攻击近似，五职业自动换图需后续职业基线和 Step 3C 灰度。
- 死亡分支没有人为杀死角色；执行器不清空 death/respawn，恢复后的或活动中的 lockMap 都由 OpenKore 在复活后重新执行。该分支应在自然死亡样本出现时补充运行证据。
