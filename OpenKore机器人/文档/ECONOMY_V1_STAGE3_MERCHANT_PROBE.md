# Economy V1 阶段 3：中央 Merchant（Cartwright）与 Cart / Vending 能力探针

测试日期：2026-09-06

## 结论

bot06 中央 Merchant 已建立并上线，Merchant 职业技能、Cart（手推车）、Vending（摆摊）1 件 / 12 件能力均已在本服 rAthena PACKETVER 20211103 + OpenKore 组合下验证通过。

- Merchant 职业与完整商人技能集：通过（服务端一次性授予，登录后技能列表正确）
- 手推车召唤、存取、100 槽 / 8000 负重、重登持久化：通过
- Vending 单件摆摊：通过（服务端 `vendings` / `vending_items` 表落库正确）
- Vending 12 件摆摊：通过（Vending Lv10 = 12 槽，`You can sell 12 items!`）
- 摆摊位置约束（与 NPC 距离）：已确认并选好无 NPC 摆摊点
- Vending 消耗 30 SP：已确认，中央商人需足够 Base 等级保证 SP 上限

仍有两处需要后续处理的已知项（详见第 5 节）：

1. OpenKore 尚未正确解析卖家自身摆摊清单封包 `0B40`（已加绑定、修正卡槽字节宽，但条目回显仍错位）。
2. 买家侧购买流程未做实机购买验收（`0B39` 买家清单解析继承自 ServerType0，预期可用）。

## 1. 测试对象与建号方式

| 项目 | 值 |
| --- | --- |
| 角色 | Cartwright |
| 实例 | bot06 |
| 账号 | openkore_bot06（account_id 2000006） |
| 角色 ID | 150008 |
| 职业 | Merchant（class 5） |
| Base / Job | 40 / 30 |
| 常驻点 | prontera (156, 170) |
| Zeny | 10,000 |

按仓库既有“首个角色由本机数据库按 rAthena 新手默认值创建”的先例，Cartwright 由本机数据库直接创建为 Merchant，并在 `skill` 表一次性授予商人技能集；技能学习入口 `skillsAddAuto 0`，不参与自然升级加点。这是探针建号，不代表“自然练成”路径。

授予的技能（`skill` 表，flag=0 永久）：

```text
NV_BASIC (1)            Lv 9
MC_INCCARRY (36)        Lv 10    // 负重增加
MC_DISCOUNT (37)        Lv 10    // 折扣
MC_OVERCHARGE (38)      Lv 10    // 高价卖出
MC_PUSHCART (39)        Lv 10    // 手推车
MC_IDENTIFY (40)        Lv 1     // 鉴定
MC_VENDING (41)         Lv 10    // 摆摊
MC_MAMMONITE (42)       Lv 1
MC_CARTREVOLUTION (153) Lv 1
MC_CHANGECART (154)     Lv 1
MC_LOUD (155)           Lv 1
ALL_BUYING_STORE (2535) Lv 1     // 收购店（仍需许可证物品）
MC_CARTDECORATE (2544)  Lv 1
```

## 2. Cart（手推车）探针

### 2.1 召唤方式（关键发现）

普通玩家 Trade 用 `ss <技能>` 触发技能没问题，但手推车**不能**用 `ss 39`（MC_PUSHCART）召唤：

```text
ss 39  →  Unable to cast skill 푸쉬카트 in 3 tries.
```

根因：本 rAthena 把 MC_PUSHCART 视作无施法确认的开关技能，OpenKore 的 `Task::UseSkill` 等不到 `is_casting` / `packet_skilluse` 确认，三次超时后报错。实际召唤手推车走的是 `ChangeCart`（0x01AF）封包，服务端 `clif_parse_ChangeCart` → `pc_setcart`。

可用命令：

```text
eval $messageSender->sendChangeCart(1)
```

`cart change <1-5>` 需要已有手推车；首召必须用上面的 `sendChangeCart`。OpenKore 的 `cart` 命令在无手推车时会提示 `You do not have a cart`。

### 2.2 存取与容量

```text
cart add 0 1     → Cart Item Added: 젤로피 x 1
cart get 0 1     → Cart Item Removed，物品回到背包
cart             → Capacity: 12/100  Weight: 27/8000
```

- 容量 100 槽、负重 8000，与 Pushcart Lv10 一致。
- 物品在背包与手推车之间往返正常。
- 重登后手推车状态（`On Push Cart`）与车内物品完整保留。

## 3. Vending（摆摊）探针

### 3.1 位置约束

首次在 prontera (156, 193) 喷泉边 `openshop` 失败：

```text
Skill 노점개설 failed: Location not allowed to create chatroom/market (error number 83)
```

原因是服务端 `skill.cpp` 对 MC_VENDING 有 `npc_isnear` 检查（`battle_config.min_npc_vendchat_distance = 3`），喷泉旁 NPC 密集。移动到 (156, 170) 后通过。摆摊点需与任意 NPC 保持 ≥ 3 格。

### 3.2 SP 约束

Vending 消耗 30 SP。初始 Base 1 / INT 1 的 Merchant 只有 13 SP；本服 SP 公式为 `base_sp[level] × (1 + INT×1%)`，INT 对 SP 几乎无贡献，SP 主要随 Base 等级增长。把 Base 调到 40 后 SP 上限 157，足够反复摆摊。

### 3.3 单件摆摊

shop.txt 写 1 件（Apple），`openshop`：

```text
You are casting 노점개설 on yourself (Delay: 0ms)
You can sell 12 items!
Store set up succesfully
```

服务端落库（`vendings` / `vending_items`）：

```text
vendings:      id=1, char_id=150008, map=prontera, title="Cartwright Test Shop"
vending_items: vending_id=1, index=0, cartinventory_id=1, amount=1, price=10
```

### 3.4 十二件摆摊

shop.txt 写 12 件（12 个不同物品，韩文名 + 价格），`openshop` 后 `vending_items` 落 12 条（index 0..11），价格、数量与 shop.txt 一致。OpenKore 显示 `You can sell 12 items!`，与 Vending Lv10 = 12 槽一致。

### 3.5 摆摊物品来源

OpenKore 的 `makeShop()` 只从**手推车**（`$char->cart`）匹配 shop.txt 条目，且按**显示名**精确匹配。本服物品显示名为韩文，因此 shop.txt 必须写韩文名（如 `사과`），不能用英文名或数字 ID（数字 ID 不参与匹配）。

## 4. 涉及文件与配置

### 4.1 仓库内新增 / 修改

```text
OpenKore机器人/instances/bot06/config.txt.template   # 新增，商人专用
OpenKore机器人/instances/secrets.local.txt            # 追加 bot06 行（不入库）
OpenKore机器人/instances/secrets.example.txt          # 追加 bot06 占位行
OpenKore机器人/脚本/openkore-control.sh               # BOT_IDS 增加 bot06
OpenKore机器人/角色档案/Cartwright.yml                 # 新增角色档案
```

bot06 config 关键值：`attackAuto 0`、`lockMap prontera (156,170)`、`route_randomWalk 0`、`shopAuto_open 0`、`buyerShopAuto_open 0`、`skillsAddAuto 0`、`statsAddAuto 0`、`autoGear 0`、`sellAuto 0`、`storageAuto 0`、`world_ai_auto_execute 0`、`cartMaxWeight 7900`。

### 4.2 OpenKore 源码（仓库外，运行目录）

```text
/Users/wangtaizhi/Documents/Codex/2026-08-22/j/outputs/ro-local/openkore/
  src/Network/Receive/kRO/RagexeRE_2021_11_03.pm
  src/Network/Receive.pm
```

与阶段 2 的 0B42（Trade 对端报价）同一类问题：`0B40`（ZC_PC_PURCHASE_MYITEMLIST，卖家自身摆摊清单）在 dated recvpackets 里声明为 `-1`（变长），但 `RagexeRE_2021_11_03` 未绑定。修复前 `openshop` 报 `Packet Parser: Unknown switch: 0B40`，商店能开但 OpenKore 看不到自己的货。

已做：

```text
1) RagexeRE_2021_11_03.pm 新增绑定：
   $self->{packet_list}{'0B40'} = ['vending_start', 'v a4 a*', [qw(len accountID itemList)]];

2) Receive.pm vending_start 的 modern 兜底 pack 卡槽宽度 a8 → a16（本协议 uint32 card[4] 为 16 字节）。
```

条目结构（每项 58 字节，由 704 字节总包长 / 12 件反推确认）：

```text
price(V) index(v) amount(v) itemType(C) itemId(V) identified(C) damaged(C)
cards(a16) options(a25) refine(C) grade(C)
```

修复后 `0B40` 不再报未知封包，但 `al` 的卖家清单条目回显仍错位（详见第 5.1 节）。

## 5. 已知问题与后续

### 5.1 0B40 卖家清单回显仍错位

绑定和包长已修正，但 `vending_start` 现代自摆清单的字段对齐仍有 bug：`al` 能显示 12 件里第 1 件的名称/价格/数量，后续条目错位成 `None` / 乱码。商店本身（服务端落库、买家可见性）不受影响。需要进一步排查 `vending_start` 的 `itemList` 切片或 `a16/a25` 与 rAthena 实际 wire 布局的差异（疑似 `a*` 变长捕获或字段顺序与现网不一致）。

建议：在 `RagexeRE_2021_11_03.pm` 里覆写一个针对 0B40 的专用解析，而不是继续依赖核心 `vending_start` 的现代分支；或按 58 字节条目手写 parse。该修复不影响阶段 3 的结论，但属于“自动收购状态机”上线前必须补齐的卖家侧可见性。

### 5.2 买家侧购买未做实机验收

本次只验证了“开摊”侧。买家侧封包 `0B39`（ZC_PC_PURCHASE_ITEMLIST）在 ServerType0 已绑定为 `item_list_nonstackable`，`vl` / `buy` 命令可用，预期可买。实机购买验收留到 economy 状态机阶段，与自动收购一起做。

### 5.3 其他

- `ALL_BUYING_STORE`（收购店）技能已授，但开收购店还需要 Bulk/Black Market Buyer Shop License 物品；阶段 4 做“自动收购”前需先给 Cartwright 补许可证。
- 阶段 3 未改动 bot01～bot05，五个练级 Bot 全程在线未受影响。
- 探针在真实 DB 上执行，已先行备份 `login/char/skill/inventory/cart_inventory` 到 `日志与备份入口/db_pre_bot06_*.sql`。

## 6. 阶段 3 验收

- [x] 建立 bot06 中央 Merchant（账号 / 角色 / 配置模板 / 机密 / 角色档案）
- [x] Merchant 职业技能集登录后可正确识别
- [x] 手推车召唤（0x01AF）、存取、容量、重登持久化
- [x] Vending 单件与 12 件开摊，服务端落库正确
- [x] 摆摊位置（NPC 距离）与 SP 约束已明确
- [x] 记录 0B40 未解析问题并做部分修复
- [x] 未影响 bot01～bot05 运行

下一步是阶段 4：给 Cartwright 补收购店许可证并实现 / 验证买家侧购买与自动收购状态机；同时补完 0B40 卖家清单解析。
