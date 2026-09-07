# Economy V1 总计划进度对照

核对日期：2026-09-07。以 `RO_Bot_Economy_V1_Development_Plan.md` 为阶段编号权威。
该文件原样复制自用户指定的 Downloads 文件（2026-09-06 修订版），后续进度写在本文件，避免篡改原始计划。

## 本次核对

| 总计划任务 | 核对结果 |
| --- | --- |
| 阶段 0 / Sprint 1：冻结实际基线 | 已完成，见 STAGE0_BASELINE |
| 实验 2.2 / Sprint 2：通用 Trade 探针 | 已完成，见 STAGE2_TRADE_PROBE；显式超时 watchdog 仍待自动化实现 |
| 阶段 1 / Sprint 3：Card、Equipment 防误卖及 ID 白名单 | 本次完成并通过原生解析及实机回城验收，见 ECONOMY_V1_STAGE1_NPC_ALLOWLIST |
| 实验 2.1 / Sprint 4：classify_item 与离线测试 | 已完成共享分类器、只读运行日志及离线测试，见 ECONOMY_V1_STAGE2_CLASSIFIER |
| 阶段 3 / Sprint 5–6：Merchant 引导和实例管理 | 核心能力已完成，见 STAGE3_MERCHANT_PROBE；严格总计划验收仍需核对真人坐标检查、资金来源等证据 |
| 阶段 4 / Sprint 7：Combat Bot 与 Merchant 普通 Trade | 未找到完整专项验收；通用 Trade 探针和收购店成交不能替代身份、忙碌拒绝、白名单及持久化验收 |
| 阶段 5 / Sprint 8：自动 Trade 收一张 Card | 未实现；当前 economy 插件是 buying store 自动开关，不是普通 Trade 买卖双方状态机 |
| 阶段 6–8：拆批、回城接入、排队和异常恢复 | 未实现；部分底层中断能力已经探针验证 |
| 阶段 9–10：收货入 Cart、自动摆摊及收货切换 | 手工 Cart/Vending 和买家购买能力已验证；真实掉落的自动完整链路未验收 |

## 历史编号差异

`ECONOMY_V1_STAGE4_BUYING_STORE.md` 是额外的收购店与摆摊封包能力报告，
其“阶段 4 完成”不等于总计划阶段 4 或阶段 5 完成。既有成果保留，后续不再用该报告编号推断总计划进度。

## 下一步：Sprint 7 的 Merchant 专项普通 Trade 验收

先补核 Sprint 5–6 的坐标、初始化资金来源/持久化等引导证据；复用已创建的 bot06 和 Cart。
按总计划实验 4.1，以 Combat Bot 和 Cartwright 进行真实普通 Trade：
核对双方物品和 Zeny、重登持久化、Merchant 忙碌拒绝及精确白名单身份边界。
已有通用 Trade 和 Vending 探针可以复用，但不能用 buying store 成交代替普通 Trade。
验收通过后才进入 Sprint 8：带 nonce 的 SELL_REQUEST/READY 和单张 Card 自动收购状态机。

Sprint 4 已于 2026-09-07 完成：只读分类由 autoGear 完成评估后触发，未开启自动交易。
