# Economy V1 总计划进度对照

核对日期：2026-09-07。以 `RO_Bot_Economy_V1_Development_Plan.md` 为阶段编号权威。
该文件原样复制自用户指定的 Downloads 文件（2026-09-06 修订版），后续进度写在本文件，避免篡改原始计划。

## 本次核对

| 总计划任务 | 核对结果 |
| --- | --- |
| 阶段 0 / Sprint 1：冻结实际基线 | 已完成，见 STAGE0_BASELINE |
| 实验 2.2 / Sprint 2：通用 Trade 探针 | 已完成，见 STAGE2_TRADE_PROBE；已补主动取消 watchdog，详见 STAGE6_MULTI_TRADE |
| 阶段 1 / Sprint 3：Card、Equipment 防误卖及 ID 白名单 | 本次完成并通过原生解析及实机回城验收，见 ECONOMY_V1_STAGE1_NPC_ALLOWLIST |
| 实验 2.1 / Sprint 4：classify_item 与离线测试 | 已完成共享分类器、只读运行日志及离线测试，见 ECONOMY_V1_STAGE2_CLASSIFIER |
| 阶段 3 / Sprint 5–6：Merchant 引导和实例管理 | 核心能力已完成，见 STAGE3_MERCHANT_PROBE；严格总计划验收仍需核对真人坐标检查、资金来源等证据 |
| 阶段 4 / Sprint 7：Combat Bot 与 Merchant 普通 Trade | 本次完成，见 ECONOMY_V1_STAGE4_MERCHANT_TRADE；含拒绝后 incomingDeal 残留修复、真实 Trade 资产守恒、忙碌拒绝与重登持久化验收 |
| 阶段 5 / Sprint 8：自动 Trade 收一张 Card | 本次完成，见 ECONOMY_V1_STAGE5_AUTO_TRADE；nonce 私聊握手 + 白名单接单 + 报价校验 + 锁定竞态修复，实机全自动成交 4023 @10,000z |
| 阶段 6：多物品交易与拆批 | 已实现共享价格、多实例、逐项 ACK、10 项拆批及资产核对；离线回归通过；三种真实卡片成交、资金不足、超时回滚及重登已实机通过，跨 10 项拆批/装备边界仍待实机验收，见 STAGE6_MULTI_TRADE |
| 阶段 7–8：回城接入、排队、异常恢复 | 回城、world_ai 控制权、队列未实现；已补资金/容量预检、主动取消、回滚核对和显式掉线后资产重建 |
| 阶段 9–10：收货入 Cart、自动摆摊及收货切换 | 手工 Cart/Vending 和买家购买能力已验证；真实掉落的自动完整链路未验收 |

## 历史编号差异

`ECONOMY_V1_STAGE4_BUYING_STORE.md` 是额外的收购店与摆摊封包能力报告，
其“阶段 4 完成”不等于总计划阶段 4 或阶段 5 完成。既有成果保留，后续不再用该报告编号推断总计划进度。

## 下一步：阶段 6 实机验收，再接入阶段 7

阶段 5 单卡历史成功路径已通过；本次补齐安全处理并实现阶段 6，
包括真实库存实例识别、共享价格表、顺序拆批、主动取消与资产核对。
完整离线回归通过，详见 `ECONOMY_V1_STAGE6_MULTI_TRADE.md`。

2026-09-07 22:48–22:56 已同步部署 bot06/bot07，并通过三种卡片成交、
资金不足拒绝、报价丢失后的超时回滚和重登持久化。临时物品和周转金已通过真实 Trade 归还。
剩余跨 10 项拆批、同 ID 不同属性装备、真实满容量及交易中掉线的实机验收；
完成后进入阶段 7。bot07 默认 autoGear 关闭，装备探针必须先完成安全评估。

注：Sprint 8 历史实机收购目标是 4023（Baby Desert Wolf Card），非计划示例的 Rocker Card（4021）；
当前改为共享价格表，其中已包含这两种卡片。

Sprint 4 已于 2026-09-07 完成：只读分类由 autoGear 完成评估后触发，未开启自动交易。
