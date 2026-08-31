# world_ai — 第 2 步：只读动态练级推荐

`world_ai` 是 OpenKore 上层的练级决策器。当前版本只读取角色运行时状态和静态世界索引，输出“打什么、去哪张图”的建议；不自动移动、不修改 `lockMap`、不修改 `mon_control`、不操作 AI 队列，也不接管战斗。

## 命令

```text
worldai status
worldai top [N]
worldai recommend
worldai inspect monster <Name|AegisName|ID>
worldai inspect map <map>
worldai reload
```

`top` 默认输出 5 项，最多 20 项。排序固定为分数降序、怪物 ID 升序、地图名升序。

## 目录

```text
world_ai/
├── world_ai.pl
├── map_index.json
├── lib/WorldAI/
│   ├── Index.pm
│   ├── CharacterSnapshot.pm
│   └── Scorer.pm
├── t/
│   ├── index.t
│   └── scorer.t
└── tools/gen_index.py
```

- `Index.pm`：加载和校验索引，建立名称与 ID 查询表；reload 失败时保留旧数据。
- `CharacterSnapshot.pm`：从 OpenKore `$char`、`$field` 读取实时状态。
- `Scorer.pm`：无 OpenKore 副作用的纯评分模块。
- `world_ai.pl`：命令、输出和错误隔离。

## CPU 约束

插件没有 `AI_pre` 钩子、后台线程、轮询或定时任务。只有 `top`、`recommend` 和 inspect 命令会按需评分；`status` 不会遍历候选。一次评分中每张地图的共存怪风险只建立一次并复用，命令结束后缓存释放。因此机器人空闲或正常战斗时，world_ai 不产生持续 CPU 负载。

## 安全边界

- MVP 或候选地图属于 `boss_spawn_maps` 时硬排除。
- 明显超出等级、单击伤害或预估击杀次数阈值的怪物硬排除。
- `skill_range` 暂不评分，因为当前数据几乎都是默认值，不能证明怪物实际拥有远程技能。
- `attack_range` 参与远程风险。
- 当前 schema 2 只有刷新数量，没有地图面积和重生时间，因此评分项叫 `spawn_count_score`，不是严格的刷新密度。
- Top 榜只使用 `%maps_lut` 已知地图；路线仍标为 `UNVERIFIED`，Step 3 执行前必须重新验证。
- 普通显示名可能重名；歧义时命令会列出 ID/AegisName，而不是擅自选择。

## 离线测试

在项目根目录执行：

```bash
prove -I"OpenKore机器人/plugins/world_ai/lib" \
  "OpenKore机器人/plugins/world_ai/t/index.t" \
  "OpenKore机器人/plugins/world_ai/t/scorer.t" \
  "OpenKore机器人/plugins/world_ai/t/performance.t"
```

正式启用前还应使用 OpenKore 的 `src` 和 `src/deps` 路径执行 `perl -c`，再只在 bot01 的 manual AI 模式完成无副作用验证。

## 第 1 步索引生成

`map_index.json` 仍由纯标准库 Python 生成：

```bash
python3 "OpenKore机器人/plugins/world_ai/tools/gen_index.py" \
  --rathena-root "/Users/wangtaizhi/Documents/Codex/2026-08-22/j/outputs/ro-local/rathena"
```

数据来自 `db/pre-re/mob_db.yml` 与三个怪物脚本配置实际启用的静态刷怪文件。必需输入缺失时默认失败且不覆盖旧索引；只有显式传 `--allow-partial` 才允许生成部分数据。

当前 schema 2 包含 510 种有静态刷新点的怪物、318 张地图。内部关联始终使用怪物 ID，避免 Name/AegisName/刷怪脚本别名不一致。

已知边界：不索引 NPC 动态召唤；不计算真实 EXP/hour、掉落收益、路线成本、地图面积或实际重生率；不修改 rAthena 原生刷怪。
