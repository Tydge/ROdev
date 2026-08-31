# M1 MacBook 上部署并游玩经典 RO（rAthena Pre-Renewal）指南

> 目标：在 Apple M1 MacBook 上搭建一个适合单人怀旧游玩的《仙境传说 RO》环境。  
> 推荐玩法：**rAthena + Pre-Renewal 99/70 转生体系**。  
> 核心思路：保留经典 RO 的职业、属性、卡片、装备与战斗公式，同时适度提高单人体验倍率。

---

## 1. 推荐玩的版本

建议选择：**rAthena Pre-Renewal 99/70**。

特点：

- 初心者开始
- 一转
- 二转
- 99 级
- 转生
- 进阶一转
- 进阶二转
- 最终 Base Lv.99 / Job Lv.70
- 不开放三转
- 不开放四转
- 使用经典旧战斗公式
- 保留经典 STR / AGI / VIT / INT / DEX / LUK 配点体系
- 保留老版 ASPD、咏唱、命中、回避、卡片和装备体系

这套玩法最接近经典 RO 的核心体验，也很适合喜欢研究数值、职业 Build 和装备组合的人。

---

## 2. 为什么推荐 Pre-Renewal

RO 的服务器规则大体分成两套。

### Pre-Renewal

也就是经典旧规则。

特点：

- 经典 99/70 转生体系
- 无三转、四转
- 属性配点影响很大
- STR、AGI、DEX 等存在明显 Build 差异
- 卡片系统非常重要
- ASPD、FLEE、HIT、咏唱等都值得专门计算
- 低等级装备也可能因为卡槽和特殊效果长期有价值
- 不完全依赖“装备等级越高越强”

### Renewal

属于后来改版后的现代 RO 体系。

主要变化包括：

- 三转
- 四转
- 更高等级上限
- 新伤害公式
- 新 DEF / MATK / ATK 体系
- 等级差修正
- 更现代化的装备成长方式

如果目标是“怀旧”，优先推荐 Pre-Renewal。

---

## 3. 推荐的单人倍率

原版 RO 是多人 MMORPG，完全按 1 倍倍率单人玩会比较肝。

建议初始设置：

| 项目 | 推荐倍率 |
|---|---:|
| Base EXP | 1× |
| Job EXP | 1× |
| 普通物品掉率 | 2× |
| 装备掉率 | 3× |
| 卡片掉率 | 10× |
| MVP 装备掉率 | 3～5× |
| Zeny / 金钱获取 | 2× |

### 关于卡片掉率

经典普通怪卡片很多约为 `0.01%`，也就是大约 `1 / 10000`。

单人环境可以提高到 `0.1%`，约 `1 / 1000`。这样依旧稀有，但不会为了某一张卡刷到失去耐心。

不建议直接开到 1% 甚至更高，否则经典 RO 最重要的“掉卡惊喜感”会明显下降。

---

## 4. M1 MacBook 推荐架构

M1 是 Apple Silicon，也就是 ARM 架构。

rAthena 服务器本身可以很好地运行在 macOS 上，但经典 RO 官方客户端主要还是 Windows 程序。

因此推荐两条路线。

---

# 路线 A：稳定优先

推荐第一次部署使用这套。

```text
M1 MacBook
│
├── macOS
│   └── rAthena Pre-Renewal Server
│
└── Parallels Desktop
    └── Windows 11 ARM
        └── RO Windows Client
```

优点：

- 服务端直接运行在 Mac
- Windows 客户端兼容性相对稳定
- 比较容易排查问题
- 很多传统 RO 客户端工具仍然可以使用
- 不需要为了客户端折腾大量 Wine 配置

缺点：

- 需要 Windows 11 ARM
- 通常需要 Parallels
- 会额外占用一些内存

---

## 5. M1 内存建议

### 如果是 16 GB 内存

很舒服。

可以考虑：

- Windows 11 ARM：分配 4～6 GB
- rAthena：直接运行在 macOS
- MariaDB：Docker 或 macOS 本地
- 剩余内存留给 macOS

RO 本身资源需求很低。

### 如果是 8 GB 内存

也可以运行。

建议：

- Windows 11 ARM：分配约 3～4 GB
- 不要同时开大量浏览器标签页
- MariaDB 和 rAthena 保持轻量配置

rAthena 对硬件要求并不高，真正额外占内存的是 Windows 虚拟机。

---

# 6. 服务端：rAthena

rAthena 是一个长期维护的开源 RO 服务器模拟器。

主要组成：

```text
login-server
char-server
map-server
MariaDB / MySQL
NPC Scripts
Database
```

它的优点是：

- 服务端源码开放
- 技能公式可以直接研究源码
- 怪物、装备、技能、掉落可以修改
- NPC 和任务大量使用脚本
- 可以加入自己的 NPC
- 可以改经验倍率
- 可以改卡片掉率
- 可以改单人 MVP
- 可以做洗点 NPC
- 可以做传送 NPC

相对于依赖闭源历史服务端的项目，rAthena 更适合长期保存和自行修改。

---

## 7. rAthena 的 Pre-Renewal 模式

rAthena 可以编译成 Pre-Renewal 模式。

核心目标：

```text
Pre-Renewal = YES
```

经典配置主要使用：

```text
db/pre-re/
```

这里包含 Pre-Renewal 对应的数据。

注意：**Pre-Renewal 是战斗规则版本，不完全等于某一天的官方客户端版本。**

RO 实际上需要分开理解三个概念：

```text
战斗规则
+
Episode 内容
+
客户端协议版本
```

例如可以使用较新的客户端程序，但服务器仍然：

- 运行 Pre-Renewal 99/70
- 不开放三转
- 继续使用经典公式

所以“不使用 2008 年原始 EXE”并不代表“玩法不是怀旧版”。

---

# 8. 服务端安装方式

对于 M1 MacBook，有两种方式。

## 方式 1：自动化安装

可以优先关注社区的 Mac 自动安装方案，例如 rA Express 一类工具。

目标通常是自动处理：

```text
Homebrew
↓
编译依赖
↓
rAthena
↓
MariaDB
↓
数据库初始化
↓
服务器配置
↓
编译
```

如果自动安装器与你当前 macOS 版本兼容，这是最省事的方式。

## 方式 2：手动安装

大致流程：

```text
安装 Homebrew
↓
安装 Git
↓
安装 CMake / 编译环境
↓
安装 MariaDB / MySQL
↓
下载 rAthena
↓
设置 Pre-Renewal
↓
编译服务器
↓
导入数据库
↓
修改 login / char / map 配置
↓
启动服务器
```

这种方式步骤更多，但好处是：

- 更容易理解整个项目结构
- 出现问题时更容易定位
- 后续自己改代码更方便

---

# 9. 客户端：推荐 Windows 11 ARM + Parallels

经典 RO 客户端主要是 Windows `Ragexe.exe`。

在 M1 上推荐：

```text
Parallels Desktop
↓
Windows 11 ARM
↓
运行 RO x86 Windows Client
```

Windows 11 ARM 可以兼容运行大量 x86 / x64 Windows 软件。

对于 RO 这种古老而轻量的游戏，性能通常不是主要问题。

真正需要注意的是：

- 客户端版本
- Ragexe 日期
- Packet Version
- 数据文件
- GRF
- 登录配置
- 字体
- 中文资源

---

# 10. 为什么不优先推荐 CrossOver / Wine

理论上可以使用 Wine 或 CrossOver 直接在 macOS 上运行 Windows RO 客户端。

但是经典 RO 客户端很老，而且很多版本是 32 位程序。

不同 Wine / CrossOver 版本可能出现：

- 无法启动
- 黑屏
- 字体异常
- DirectX 问题
- 补丁器异常
- 老组件兼容问题

所以第一次搭建时，Parallels 通常更省心。

等服务器已经稳定运行以后，再尝试 Wine / CrossOver 会更合适。

---

# 11. 路线 B：完全 Mac 原生

另一条更有趣的路线：

```text
M1 MacBook
│
├── rAthena Server
└── Open-source RO Client
```

也就是：**Mac 原生服务端 + Mac 原生重写客户端**。

可以关注类似 Open Midgard 的现代开源 RO 客户端项目。

这类项目目标通常包括：

- C++ 重写
- macOS 原生
- ARM 支持
- 高分辨率
- Vulkan / Metal 等现代渲染
- 读取 RO 原始资源
- 连接 rAthena

理论上最终可以做到：

```text
不安装 Windows
不使用 Parallels
不使用 Wine
```

直接在 M1 MacBook 上运行整个 RO 环境。

但目前这类客户端通常仍处于开发阶段，因此更适合作为实验路线，而不是第一次部署的主方案。

---

# 12. 单人模式建议修改

如果只打算自己玩，可以适度改变 MMORPG 原本依赖多人在线的内容。

## MVP

建议：

- MVP HP 适度下降
- MVP 刷新时间缩短
- MVP 掉率略提高
- 增加 Boss 传送 NPC

不要改得过于简单，否则 Boss 装备会失去意义。

## 组队内容

可以考虑：

- 调低需要组队的副本怪物 HP
- 提高单人恢复能力
- 增加 NPC Buff
- 增加 Kafra 传送点
- 增加免费或低价洗点功能

## 洗点

经典 RO Build 很容易点错。

单人环境建议增加一个 NPC：

```text
Zeny 洗属性
Zeny 洗技能
```

例如每次 `100,000 Zeny`。

这样既不会完全没有代价，也避免因为一次加点错误重新练角色。

---

# 13. 为什么 RO 很适合单人长期保存

RO 有几个非常适合“私人离线服”的特点。

### 职业 Build 多

同一个职业可以玩完全不同路线。

例如骑士：

- AGI 双手剑
- VIT 枪骑
- Boss 坦克
- 技能爆发

牧师：

- 纯辅助
- 驱魔
- 暴力牧

刺客：

- 双刀
- 暴击
- 毒
- ASPD

### 卡片系统

很多怪物都有自己的卡片。

卡片可以：

- 增加属性
- 增加种族伤害
- 增加属性伤害
- 提高暴击
- 提供状态抗性
- 触发技能
- 改变装备特性

所以刷怪不仅仅是为了经验。

### 装备不会完全被等级淘汰

因为：

- 插槽
- 卡片
- 特殊效果
- 属性组合

一些低等级装备可能在特定 Build 中长期有价值。

### 属性机制很深

经典 RO 的六维属性：

```text
STR
AGI
VIT
INT
DEX
LUK
```

它们分别影响：

- 攻击
- ASPD
- FLEE
- HP
- DEF
- MATK
- SP
- 咏唱
- HIT
- 暴击
- 异常状态
- 特殊公式

角色培养本身就是一套很有意思的数值系统。

---

# 14. 推荐最终配置

如果目标是“第一次体验经典 RO，同时保留研究空间”，推荐：

```text
Server:
rAthena

Rules:
Pre-Renewal

Level Cap:
99 / 70

Transcendent Classes:
YES

Third Jobs:
NO

Fourth Jobs:
NO

Base EXP:
5x

Job EXP:
5x

Normal Drop:
2x

Equipment Drop:
3x

Card Drop:
10x

MVP Drop:
3x ~ 5x

Zeny:
2x
```

客户端：

```text
第一阶段：
Parallels + Windows 11 ARM + Ragexe

后续实验：
Mac 原生 Open-source RO Client
```

---

# 15. 推荐部署顺序

建议不要一次性把所有东西都改完。

### 第 1 阶段

确认 Mac：

- Apple M1
- 内存容量
- macOS 版本

### 第 2 阶段

搭建：

```text
rAthena
+
MariaDB
```

确保：

```text
login-server
char-server
map-server
```

全部能启动。

### 第 3 阶段

安装 RO 客户端。

确认：

```text
客户端
↓
连接 127.0.0.1
↓
创建账号
↓
进入角色选择
↓
进入地图
```

### 第 4 阶段

确认：

```text
Pre-Renewal
99/70
无三转
```

### 第 5 阶段

修改倍率。

### 第 6 阶段

增加单人优化：

- 洗点 NPC
- MVP 调整
- 传送 NPC
- 卡片倍率
- 单人副本调整

### 第 7 阶段

最后再考虑：

- 中文化
- UI 修改
- 自定义 NPC
- 自定义任务
- 自定义装备
- Mac 原生开源客户端

---

# 16. 最终推荐

## 稳定游玩方案

```text
macOS
├── rAthena Pre-Renewal Server
└── Parallels
    └── Windows 11 ARM
        └── RO Client
```

这是目前 M1 MacBook 最推荐的方式。

## 长期理想方案

```text
macOS
├── rAthena Server
└── Mac Native Open-source RO Client
```

未来如果开源客户端越来越成熟，这会成为最干净的方案。

---

## 下一步需要确认的信息

实际安装前建议确认：

1. Mac 芯片是否为 Apple M1
2. 内存是 8 GB 还是 16 GB
3. 当前 macOS 版本
4. 是否已经安装 Parallels
5. 是否希望完全离线
6. 是否需要简体中文客户端

确认后即可按照具体机器配置逐步完成：

```text
下载
→ 安装服务器
→ 建数据库
→ 设置 Pre-Renewal
→ 安装客户端
→ 连接本机服务器
→ 创建第一个角色
→ 调整单人倍率
```
