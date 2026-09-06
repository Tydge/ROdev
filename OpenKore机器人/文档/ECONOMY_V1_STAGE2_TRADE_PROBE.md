# Economy V1 阶段 2：Trade 能力探针

测试日期：2026-09-06

## 结论

当前 rAthena PACKETVER 20211103 与 OpenKore 的普通玩家 Trade 链路已可用。

- 请求、接受、加入物品、加入 Zeny、双方锁定、双方最终确认：通过
- 服务端完成事件与双方账目变化：通过
- 完成后重登持久化：通过
- 主动取消与已锁定后取消回滚：通过
- 一方掉线时自动取消及重登回滚：通过
- 原生交易自动超时：30 秒内未发生，后续 economy 状态机必须自行实现 watchdog
- 单方最多 10 个物品条目：已由 OpenKore 与 rAthena 当前源码共同确认

因此，通用 Trade 协议能力可以进入下一阶段；自动交易逻辑不得假定服务端会替它处理超时。

## 测试对象

| 角色 | 实例 | 职业 | 用途 |
| --- | --- | --- | --- |
| KoreHelper | bot01 | Thief | 提供 1 个 Jellopy |
| EthanRowe | bot02 | Swordsman | 支付 10 Zeny |

测试期间两名角色在 prt_fild08 相邻站立，关闭 world_ai 自动执行并切到手工 AI。完成全部探针后已恢复原有自动化配置。

## 首次探针发现的问题

修复前，Trade 请求和接受正常，但对端报价不可见：

- bot01 看不到 EthanRowe 加入的 Zeny；
- bot02 看不到 KoreHelper 加入的物品；
- OpenKore 报告 Packet Parser: Unknown switch: 0B42。

根因是 dated recvpackets.txt 已声明 0B42 长度为 62 字节，但
Network::Receive::kRO::RagexeRE_2021_11_03 未把该 switch 绑定到
deal_add_other。

rAthena 对当前协议的结构为：

    packetType + itemId(32-bit) + itemType + amount
    + identified + damaged
    + cards(16 bytes) + options(25 bytes)
    + location + look + refine + grade
    = 62 bytes

index = 0 时同一个包承载对端加入的 Zeny，因此漏掉该映射会同时破坏物品与 Zeny 回显。

## 兼容修复

部署源码：

    /Users/wangtaizhi/Documents/Codex/2026-08-22/j/outputs/ro-local/openkore/
      src/Network/Receive/kRO/RagexeRE_2021_11_03.pm

新增 0B42 到 deal_add_other 的接收映射，字段格式为：

    V C V C2 a16 a25 V v C2
    nameID type amount identified broken cards options
    type_equip viewID upgrade grade

格式长度为 60 字节，加 2 字节 switch 后正好是 dated recvpackets 声明的 62 字节。Perl 加载验证能通过语法与模块解析阶段；本机直接执行 perl -c 时会继续触发 OpenKore 的 XSTools 构建/加载流程，因此最终以两实例真实登录和完整 Trade 回显作为运行验证。

## 用例 1：成功交易

交易前：

| 角色 | Zeny | Jellopy |
| --- | ---: | ---: |
| KoreHelper | 12,514 | 21 |
| EthanRowe | 21,917 | 33 |

内容：

    KoreHelper -> Jellopy x 1
    EthanRowe  -> 10 Zeny

双方在锁定前都能看到完整对端报价：

    KoreHelper 视角：EthanRowe - Finalized，zeny: 10
    EthanRowe 视角：KoreHelper - Finalized，Jellopy x 1

双方最终确认后均收到 Deal Complete。

交易后：

| 角色 | Zeny | 变化 | Jellopy | 变化 |
| --- | ---: | ---: | ---: | ---: |
| KoreHelper | 12,524 | +10 | 20 | -1 |
| EthanRowe | 21,907 | -10 | 34 | +1 |

账目守恒：

    Zeny 总量：34,431 -> 34,431
    Jellopy 总量：54 -> 54

## 用例 2：完成后重登

成功交易后分别重启 bot01 与 bot02，并以手工 AI 重新登录。

重登结果：

| 角色 | Zeny | Jellopy |
| --- | ---: | ---: |
| KoreHelper | 12,524 | 20 |
| EthanRowe | 21,907 | 34 |

与服务端完成事件后的状态一致，持久化通过。

## 用例 3：锁定后主动取消

在交易后基线上再次建立 Trade：

1. KoreHelper 加入 Jellopy x 1；
2. EthanRowe 加入 10 Zeny 并先锁定；
3. KoreHelper 此时能看到对端 zeny: 10；
4. KoreHelper 取消。

双方均收到 Deal Cancelled。KoreHelper 的物品回到库存，EthanRowe 的 10 Zeny 解锁。

取消后仍为：

| 角色 | Zeny | Jellopy |
| --- | ---: | ---: |
| KoreHelper | 12,524 | 20 |
| EthanRowe | 21,907 | 34 |

## 用例 4：等待超时

再次建立相同 Trade，由 EthanRowe 加入 10 Zeny 并先锁定，KoreHelper 不继续操作。

等待 30 秒后：

- Trade 仍保持开启；
- 对端物品与 Zeny 回显仍正确；
- 没有自动取消事件。

随后主动取消，物品与 Zeny 全部回滚。

这不是资产原子性故障，但说明当前普通 Trade 没有可依赖的 30 秒服务端/OpenKore 自动取消。后续自动化必须：

- 为 REQUESTED / OPEN / QUOTED / FINALIZED 各状态设置明确截止时间；
- 超时后发送取消；
- 等待服务端 Deal Cancelled 或连接状态变化；
- 以取消后的库存与 Zeny 快照验收，不能只清理本地状态。

## 用例 5：一方掉线

在双方报价已回显、EthanRowe 已锁定后关闭 bot02：

- KoreHelper 立即收到 Deal Cancelled；
- 临时移出的 Jellopy 立即回到库存；
- KoreHelper Zeny 不变；
- bot02 重登后，EthanRowe 的 10 Zeny 已恢复；
- EthanRowe 的 Jellopy 数量没有变化。

掉线前后核账：

| 角色 | Zeny | Jellopy | 结果 |
| --- | ---: | ---: | --- |
| KoreHelper | 12,524 | 32 | 全部恢复 |
| EthanRowe | 21,907 | 34 | 全部恢复 |

KoreHelper 的 Jellopy 已因恢复自动战斗后的正常拾取从早先的 20 增加到 32；本用例比较的是掉线用例自身的前后快照。

## 10 条目边界

当前 OpenKore 的 Commands.pm 使用 dealMaxItems，未配置时默认 10。当前 rAthena 的 trade.cpp 以 ARR_FIND(0, 10, ...) 查找交易槽。

所以 V1 继续采用“单方每笔最多 10 个物品条目”的边界。堆叠数量不等于条目数；11 个及以上条目必须拆批，上一批收到服务端成功事件并核账后才允许开始下一批。

## 日志证据

| 时间 | 事件 |
| --- | --- |
| 21:44:34 | 修复后对端成功收到 Jellopy 报价 |
| 21:44:55 | 对端成功收到 10 Zeny 报价 |
| 21:45:14 | 双方收到 Deal Complete |
| 21:45:43 | 重登后资产快照一致 |
| 21:45:58 | 已锁定报价取消并收到 Deal Cancelled |
| 21:50:25 | 等待 30 秒后 Trade 仍保持开启 |
| 21:51:03 | bot02 掉线，bot01 收到 Deal Cancelled 并恢复物品 |
| 21:51:18 | bot02 重登，Zeny 与物品快照全部恢复 |

日志位置：

    /Users/wangtaizhi/Documents/Codex/2026-08-22/j/outputs/ro-local/openkore-local/instances/bot01/logs/console_openkore_bot01_0.txt
    /Users/wangtaizhi/Documents/Codex/2026-08-22/j/outputs/ro-local/openkore-local/instances/bot02/logs/console_openkore_bot02_0.txt

## 收尾状态

- bot01～bot05 均在运行；
- bot01、bot02 已恢复 attackAuto 2；
- 已恢复 route_randomWalk 1；
- 已恢复 sitAuto_hp_lower 45 与 sitAuto_idle 1；
- 已恢复 world_ai_auto_execute 1；
- bot01、bot02 已恢复自动 AI；
- 没有遗留中的 Trade。

## 下一步

按开发计划进入阶段 3：创建 bot06 中央 Merchant，并先完成 Merchant 技能、Cart、Vending 1 件/12 件能力探针。自动收购状态机仍需等 Merchant 能力探针通过后再实现。
