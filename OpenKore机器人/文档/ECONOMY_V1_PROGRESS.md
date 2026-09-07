# Economy V1 总计划进度对照

核对日期：2026-09-07。以 `RO_Bot_Economy_V1_Development_Plan.md` 为阶段编号权威。
该文件原样复制自用户指定的 Downloads 文件（2026-09-06 修订版），后续进度写在本文件，避免篡改原始计划。

## 本次核对

| 总计划任务 | 核对结果 |
| --- | --- |
| 阶段 0 / Sprint 1：冻结实际基线 | 已完成，见 STAGE0_BASELINE |
| 实验 2.2 / Sprint 2：通用 Trade 探针 | 已完成，见 STAGE2_TRADE_PROBE；显式超时 watchdog 仍待自动化实现 |
| 阶段 1 / Sprint 3：Card、Equipment 防误卖及 ID 白名单 | 本次完成并通过原生解析及实机回城验收，见 ECONOMY_V1_STAGE1_NPC_ALLOWLIST |
| 实验 2.1 / Sprint 4：classify_item 与离线测试 | 未实现；这是本次完成后的下一步 |
| 阶段 3 / Sprint 5–6：Merchant 引导和实例管理 | 核心能力已完成，见 STAGE3_MERCHANT_PROBE；严格总计划验收仍需核对真人坐标检查、资金来源等证据 |
| 阶段 4 / Sprint 7：Combat Bot 与 Merchant 普通 Trade | 未找到完整专项验收；通用 Trade 探针和收购店成交不能替代身份、忙碌拒绝、白名单及持久化验收 |
| 阶段 5 / Sprint 8：自动 Trade 收一张 Card | 未实现；当前 economy 插件是 buying store 自动开关，不是普通 Trade 买卖双方状态机 |
| 阶段 6–8：拆批、回城接入、排队和异常恢复 | 未实现；部分底层中断能力已经探针验证 |
| 阶段 9–10：收货入 Cart、自动摆摊及收货切换 | 手工 Cart/Vending 和买家购买能力已验证；真实掉落的自动完整链路未验收 |

## 历史编号差异

`ECONOMY_V1_STAGE4_BUYING_STORE.md` 是额外的收购店与摆摊封包能力报告，
其“阶段 4 完成”不等于总计划阶段 4 或阶段 5 完成。既有成果保留，后续不再用该报告编号推断总计划进度。

## 下一步：仅推进 Sprint 4

实现共享 `classify_item()`，先记录分类结果，不自动交易。
输出 NPC_SELL / MERCHANT_SELL / KEEP / CONSUME / UNKNOWN，未知默认保留。
复用本次唯一 NPC 白名单，不维护第二份相互冲突的出售表。
在 autoGear 评估后分类，保护已装备、保留升级品、不可交易及无法可靠识别的装备。
按总计划实验 2.1 增加带孔、精炼、插卡、未鉴定、任务/驯养/货币和未知 ID 测试。
完成后再补 Merchant 专项普通 Trade 验收，进入自动收一张 Card。
