# Economy V1 阶段 4：买家侧购买 + 自动收购（收购店）状态机

测试日期：2026-09-07

## 结论

阶段 4 完成并全部实测通过：

- 给中央商人 Cartwright 补了收购店许可证（`Buy Market Permit` 6377）。
- 补完了 OpenKore 在本服 PACKETVER 20211103 下缺失/错位的摆摊与收购店封包解析。
- 买家侧购买（`vl` / `vender <#>` / `vender <#> <item#> <amount>`）实机验证通过。
- 自动收购（收购店 / buying store）状态机已实现为仓库内插件 `economy`，开摊→成交→zeny 见底关店→回血重开 全链路验证通过。
- 新建顾客探针 bot07（Penny）作为买家/卖家对端。

关键结论：本服 rAthena 在 PACKETVER >= 20180704 起，收购店（buying store）的条目 itemId 是 **uint32**（4 字节），而 OpenKore 共享代码与 kRO 继承链里仍是 uint16 老布局；此外 2018-04-04b 起的 Send 基类把 `CZ_REQ_OPEN_BUYING_STORE`（0x0811）覆写成了缺 `len` + `storeName` 的坏布局。这两处是本阶段最核心的源码修复。

## 1. 收购店许可证

中央商人开收购店需要许可证物品。本服（Pre-Renewal）相关物品：

| itemId | AegisName | 名称 | 用途 |
| --- | --- | --- | --- |
| 6377 | Buy_Market_Permit | Buy Market Permit（구매노점 허가증） | 施放 `ALL_BUYING_STORE` 技能消耗 1 个（skill_db ItemCost） |
| 12548 | Buy_Market_Permit2 | Shabby Purchase Street Stall License | 无技能时直接用（`buyingstore 2;` 脚本，2 槽） |

Cartwright 已有 `ALL_BUYING_STORE`（Lv1），走技能路径，需 6377。已给 Cartwright 背包注入 6377 × 5（每次开收购店消耗 1 个，多次开/关会持续消耗，见第 6 节）。

`makeBuyerShop` 用**背包**里的同名物品取 nameID（不是手推车），所以待收购物品需在背包留样：给 Cartwright 背包补了 Jellopy(909) ×1、Empty Bottle(713) ×1 作样本。

## 2. OpenKore 源码修复（仓库外，运行目录）

文件：
```text
/Users/wangtaizhi/Documents/Codex/2026-08-22/j/outputs/ro-local/openkore/
  src/Network/Receive/kRO/RagexeRE_2021_11_03.pm
  src/Network/Send/kRO/RagexeRE_2021_11_03.pm
```

### 2.1 摆摊（vending）

- **0B40 卖家自摆清单**（阶段 3 遗留）：`vending_start` 依赖的 `vender_items_list_item_pack_self` 被 2016-12-07e 基类设成了 uint16 老布局 `'V v2 C v C3 a8 a25'`（47 字节），导致 0B40 58 字节现代条目错位。修复：`delete $self->{vender_items_list_item_pack_self};`，让 `vending_start` 回落到核心里本就正确的现代兜底 `'V v2 C V C C a16 a25 C C'`（58 字节）。实测 `openshop` 后 `al` 12 件全部正确。
- **0B3D 买家看商人摊位清单**：20200724 起条目末尾多 1 字节 `grade`，继承的 2020-04-01b pack `'V v2 C V C3 a16 a25 V v'` 只有 63 字节，少 grade。修复：`vender_items_list_item_pack = 'V v2 C V C2 a16 a25 V v C2'`（64 字节）+ 对应 `vender_items_list_item_keys`。

### 2.2 收购店（buying store）

- **0x0813（自己收购店清单）/ 0x0818（他人收购店清单）**：条目 itemId 是 uint32。共享 handler 默认 `'V v C v'`（uint16）。修复：`open_buying_store_items_list_pack` 与 `buying_store_items_list_pack` 都设为 `'V v C V'`（11 字节）。
- **0x09E6 收购店成交更新**：20211103 的更新封包是 0x09E6（24 字节：itemId V、amount v、zeny V、zenyLimit V、charId V、updateTime V），不再是老 0x081B。补绑定 `buying_store_update`。
- **0x0824 收购失败**：itemId 是 uint32，ServerType0 误读成 uint16（`v2`）。覆写为 `'v V'`。

### 2.3 发送侧（关键 bug）

- **0x0811 CZ_REQ_OPEN_BUYING_STORE**：2018-04-04b 基类把该封包覆写成缺 `len` + `storeName` 的坏布局 `'a4 c a*'`，导致发出去只有 27 字节，服务端报 `Malformed packet (expected length=89, length=27)`。修复：覆写回正确的 `'v V C Z80 a*'`（len、zenyLimit、result、storeName[80]、items[]）。
- **`buy_bulk_openShop_size`**：条目 `itemId(V) amount(v) price(V)` = 10 字节，共享默认 `(a8)*`/`v2 V` 是 uint16 老布局。设为 `(a10)*` / `V v V`。
- **`buy_bulk_buyer_size`**：`CZ_REQ_TRADE_BUYING_STORE` 条目 = `index(int16) itemId(uint32) amount(uint16)` = 8 字节。注意 `index` 是 OpenKore 背包条目的二进制 `{ID}`（2 字节串，不是数字），因此用 `a2 V v`（而不是 `v V v`）。设 `(a8)*` / `a2 V v`。

## 3. 顾客探针 bot07（Penny）

| 项目 | 值 |
| --- | --- |
| 实例 | bot07 |
| 角色 | Penny |
| 账号 | openkore_bot07（account_id 2000007） |
| 角色 ID | 150009 |
| 职业 | Novice（class 0） |
| Base / Job | 10 / 10 |
| 常驻点 | prontera (157, 170)，紧邻 Cartwright |
| 初始 | zeny 5000 + 新手包；背包 Jellopy ×3、Empty Bottle ×2 |

按 bot06 同款“DB 直建角色”先例创建。配置为最简顾客：不打怪、不摆摊、不开收购店，全部用控制台命令 `vl/vender`、`bl/buyer` 手工驱动。`BOT_IDS` 增加 bot07，`secrets` 追加 bot07 行（pincode 2586）。

## 4. economy 自动收购状态机插件

新增 `OpenKore机器人/plugins/economy/economy.pl`。

OpenKore 原生只有 `buyerShopAuto_open`（空闲即开一次、一直开着），没有 zeny 见底关店/回血重开闭环。插件把收购店当成受控状态机：

```text
[IDLE]  --(zeny>=reserve && idle && in lockMap && 有技能/许可证)--> 开收购店
[OPEN]  --(0x09E6 每笔成交)--> 记录购买、累计花费
[OPEN]  --(zeny<reserve)--> 关店（避免收购店破产）
[IDLE]  --(zeny 恢复)--> 重新开
```

- 配置：`economy_buy_store_enabled 1`、`economy_buy_store_reserve 2000`。
- Hook：`AI_pre/manual`（manual/auto 两种 AI 模式都触发；`AI_pre` 只在 auto 模式触发，故不用它）。
- Hook：`packet/buying_store_update`（0x09E6）追踪每笔成交；`buyer_shop_closed` 记录关店。
- 命令：`economy status|open|close|reset`。
- 开失败指数退避（10s→20s→…→120s），避免没许可证/没物品时刷屏并烧许可证。

## 5. 实测结果

### 5.1 买家侧购买（普通摆摊）

Cartwright 摆 12 件（shop.txt 韩文名），bot07：

```text
vl           → 0  Cartwright Test Shop (156,170)
vender 0     → 12 件清单全部正确（0B3D 解析修复生效）
vender 0 0 1 → You lost 10 zeny. / Item added: 사과 x1
```

服务端：`vendings` 去掉已售 Apple，`cart_inventory` 同步减少；Cartwright `You gained 10 zeny`、`Penny has bought your item(s)`。

### 5.2 自动收购（收购店）

Cartwright 收购清单 buyer_shop.txt：`젤로피 20z ×5`、`빈병 15z ×5`。economy 插件自动开店：

```text
[ECONOMY] open buying store requested zeny=10010 reserve=2000
You are casting Buying Store on yourself
Your buying store can buy 5 items
Buying Shop opened!
  젤로피 20z ×5 / 빈병 15z ×5
```

bot07 卖出：

```text
bl          → 0  Cartwright Buying Shop
buyer 0     → 清单正确（0x0818 解析修复生效）
buyer 0 0 2 → You gained 40 zeny. / You have sold 젤로피. Amount: 2. Total zeny: 40z
```

Cartwright 侧：

```text
Item added to inventory: 젤로피 x2
You lost 40 zeny.
You bought 2 젤로피
[ECONOMY] [BUY] purchase itemID=909 count=2 cost=40z (session purchases=1 spent=40z)
```

服务端：`buyingstore_items` Jellopy 5→3；zeny Cartwright 10010→9970、Penny 上升 40。

### 5.3 关店/重开（zeny 保底）

把 `economy_buy_store_reserve` 临时提到 9990（高于当前 zeny 9970）：

```text
[ECONOMY] close buying store: zeny_below_reserve zeny=9970 reserve=9990
```

`buyingstores` 删除；恢复 reserve=2000 后插件自动重开（`buyingstores` 新建一条）。状态机闭环验证通过。

## 6. 已知事项与后续

- **许可证是消耗品**：每开一次收购店消耗 1 个 6377。本阶段测试累计开了 ~4 次（含两次修复前失败开），5 个许可证剩 2 个。长期运行需周期性补许可证，或把 reserve 设得保守以减少开/关频率（开/关越频繁，许可证消耗越快）。
- **收购店条目编号回显小瑕疵**：`bs` 显示自己收购店时条目号都显示 0（`@selfBuyerItemList` 的展示编号 bug），不影响功能（名称/价格/数量正确）。
- **收购店 0x0812 失败封包**：ServerType0 的 0x0812 绑定只有 `v`（缺 weight 字段，recvpackets 8 字节），本阶段开/关均成功未触发，未修复（低优先级）。
- bot01～bot05 五个练级 Bot 全程在线未受影响。
- OpenKore 源码补丁按项目惯例**不入主仓库**，仅记录在本报告；仓库内只提交 config/插件/脚本/档案。

## 7. 涉及文件

### 7.1 仓库内（提交）

```text
OpenKore机器人/instances/bot06/config.txt.template        # 增 economy_buy_store_enabled/reserve
OpenKore机器人/instances/bot06/control/shop.txt            # 新：12 件摆摊清单
OpenKore机器人/instances/bot06/control/buyer_shop.txt      # 新：收购清单
OpenKore机器人/instances/bot07/config.txt.template         # 新：顾客探针
OpenKore机器人/instances/secrets.example.txt               # 增 bot07 占位行
OpenKore机器人/instances/shared-control/sys.txt            # loadPlugins_list 增 economy
OpenKore机器人/脚本/openkore-control.sh                     # BOT_IDS+economy 部署+按实例控制文件覆盖
OpenKore机器人/plugins/economy/economy.pl                  # 新：自动收购状态机
OpenKore机器人/角色档案/Penny.yml                           # 新：顾客角色档案
```

### 7.2 OpenKore 源码（仓库外，记录不提交）

```text
src/Network/Receive/kRO/RagexeRE_2021_11_03.pm   # 0B40/0B3D/收购店 receive 修复
src/Network/Send/kRO/RagexeRE_2021_11_03.pm      # 0x0811 + 收购店 send 布局修复
```

### 7.3 DB（已先备份到 日志与备份入口/db_pre_stage4_*.sql）

```text
login:     2000007 openkore_bot07（pincode 2586）
char:      150009 Penny（Novice, base10/job10, zeny 5000, prontera 157,170）
inventory: Cartwright +6377×5、+909×1、+713×1；Penny +909×3、+713×2
```

## 8. 阶段 4 验收

- [x] 补收购店许可证 6377（Cartwright 背包）
- [x] 修复 0B40 卖家自摆清单解析（阶段 3 遗留）
- [x] 修复 0B3D 买家看商人摊位清单解析
- [x] 修复收购店封包（0x0811/0x0813/0x0818/0x0819/0x09E6/0x0824）
- [x] 买家侧购买（vl/vender buy）实机验证
- [x] 新建 bot07 顾客探针
- [x] 实现 economy 自动收购状态机插件
- [x] 收购店开→成交→zeny 保底关店→重开 全链路验证
- [x] 未影响 bot01～bot05 运行
