# autoGear — 共享装备决策器

`autoGear` 是 OpenKore 上层的自动换装插件：在登录、转职、拾到装备或装备被卸下后，从背包里选择「确实更好」的装备并穿上。它依据 Pre-Renewal 装备库生成的评分目录判断职业、等级、鉴定状态、基础攻防、精炼与插槽；已插卡装备和无法可靠评分的自定义装备默认不替换。

## 目录

```text
autoGear/
├── autoGear.pl              # 插件主程序
├── gear_catalog.txt         # 由 item_db_equip.yml 生成的 2017 条评分目录
└── tools/
    └── generate_gear_catalog.rb   # 目录生成器
```

`autoGear.pl` 从自身插件目录加载 `gear_catalog.txt`，因此整套目录随插件一起部署、一起进 git，不再依赖运行目录下的 tables 覆盖文件。

## 生成/更新评分目录

当 rAthena 的装备库（`db/pre-re/item_db_equip.yml`）变化时重新生成：

```bash
ruby "OpenKore机器人/plugins/autoGear/tools/generate_gear_catalog.rb" \
  "/Users/wangtaizhi/Documents/Codex/2026-08-22/j/outputs/ro-local/rathena/db/pre-re/item_db_equip.yml" \
  "OpenKore机器人/plugins/autoGear/gear_catalog.txt"
```

生成后在机器人控制台执行 `plugin reload autoGear`（或重启机器人）即可生效。

## 职业名映射

生成器会把 rAthena 与 OpenKore 拼写不一致的职业名翻译成 OpenKore 的 `%jobs_lut` 拼写，当前包含：

| rAthena | OpenKore |
| --- | --- |
| `Swordman` | `Swordsman` |

这是 2026-09-01 发现并修复的问题：rAthena 把剑士拼成 `Swordman`（无 s），导致 `autoGear` 判定剑士用不了剑/匕首，剑士角色会一直空手。其余 rAthena 职业名（含 `SuperNovice`、`SoulLinker` 等）经归一化后与 OpenKore 一致，无需映射。

## 已知边界

- rAthena 的合并职业 `BardDancer` 对应 OpenKore 分开的 `Bard`/`Dancer`，暂未映射；项目五个职业（Assassin/Knight/Wizard/Hunter/Priest）不涉及。等出现 Bard/Dancer 角色时，需要同时在生成器与 `autoGear.pl` 的别名表里处理。
- 第一版保守管理武器、盾牌、衣服、披肩、鞋和头部装备；饰品与复杂脚本特效不参与自动比较。
- 目录是静态评分近似（基础攻防 + 精炼 + 插槽），不解析物品 `Script` 的特效加成；有 `Script` 的条目标 `scripted=1`，但当前评分仍只按基础数值。
