# world_ai — 动态练级选图（第 1 步：离线索引）

这是把 `world_ai_test` 的“换图打怪”实验升级成正式动态练级系统的**第 1 步**：离线生成
“怪物 ↔ 地图”静态索引，供后续插件与收益/风险评分使用。本目录暂不含插件逻辑，只交付数据管线与数据。

## 文件

- `tools/gen_index.py`：生成器。纯 Python 标准库，无 PyYAML 依赖。
- `map_index.json`：生成结果（提交入库，插件运行时直接读取）。

## 重新生成

```bash
python3 "OpenKore机器人/plugins/world_ai/tools/gen_index.py" \
  --rathena-root "/Users/wangtaizhi/Documents/Codex/2026-08-22/j/outputs/ro-local/rathena"
```

`--rathena-root` 缺省即为上面这个本机路径；`--out` 可覆盖输出位置；`--extra-spawn` 可临时并入额外刷怪文件。

## 数据来源（已核实）

1. **怪物数值**：`db/pre-re/mob_db.yml`。`db/mob_db.yml` 只是 91 行的导入桩，其 `Footer.Imports`
   声明了 `db/pre-re/mob_db.yml`（Prerenewal）/ `db/re/mob_db.yml`（Renewal）/ `db/import/mob_db.yml`。
   本服编译为 Pre-Renewal（`DBPATH = "pre-re/"`，见 `src/config/const.hpp`），因此真正加载的是
   `db/pre-re/mob_db.yml`；`db/import/mob_db.yml` 本服为空，无覆盖。
2. **静态刷怪**：由三个 conf 里“未注释”的 `npc:` 行决定（`//` 注释的会被正确跳过）：
   - `npc/scripts_monsters.conf` → `npc/mobs/{jail,pvp,towns}.txt`
   - `npc/pre-re/scripts_monsters.conf` → `citycleaners.txt` + `dungeons/*.txt` + `fields/*.txt`
   - `npc/scripts_custom.conf` → 当前只有 resetnpc / 职业路线脚本（无静态刷怪）

   入口是 `npc/pre-re/scripts_main.conf`（map-server 通过 `map_reloadnpc_sub` 加载）。

## 输出结构

```jsonc
{
  "meta": { "schema_version": 1, "generated_at": "...", "sources": {...}, "counts": {...} },
  "monsters": {          // 只含“出现在静态刷怪里”的可狩猎怪物，按 ID 升序
    "1002": {
      "id": 1002, "aegis_name": "PORING", "name": "Poring",
      "level": 1, "hp": 50, "base_exp": 2, "job_exp": 1, "mvp_exp": 0,
      "is_mvp": false, "attack": 7, "attack2": 10, "defense": 0, "magic_defense": 5,
      "size": "Medium", "race": "Plant", "element": "Water", "element_level": 1,
      "walk_speed": 400, "attack_range": 1, "skill_range": 10,
      "maps": { "prt_fild08": 70, "prt_fild00": 40, "...": 30 },
      "boss_spawn_maps": []
    }
  },
  "maps": {              // 反向索引：地图 -> { 怪物ID: 数量 }
    "prt_fild08": { "1002": 70, "1063": 40, "1008": 20, "1113": 10 }
  }
}
```

- 同图同怪出现多条 `monster` 行时，`count` 累加。
- `monsters` 只保留有静态刷怪的怪物（1004 条 mob_db 中 510 条可狩猎）；纯任务/活动/召唤类怪物不在静态索引里。

## 校验结果（已知数据断言）

| 检查项 | 期望 | 实际 |
| --- | --- | --- |
| Poring 1002 数值 | lvl 1 / hp 50 / base_exp 2 / atk 7-10 | 一致 |
| Poring → prt_fild08 | 70 | 70 |
| Rocker 1052 数值 | lvl 9 / hp 198 / base_exp 20 | 一致 |
| Rocker → prt_fild07 / prt_fild04 | 80 / 70 | 80 / 70 |
| prt_fild08 原生刷怪 | Lunatic 40 · Pupa 20 · Poring 70 · Drops 10 | 一致 |

`world_ai_test.pl` 里硬编码的 Poring→prt_fild08=70、Rocker→prt_fild07=80、prt_fild04=70 与本索引完全吻合。

## 两个重要发现（会影响第 2、3 步）

1. **按 ID 连接，不按名字**。刷怪脚本写的是 `monster Garm 1252,1,...`，但 `mob_db.yml` 的
   `Name` 是 “Hatii”（`AegisName` 才是 `GARM`）。名字大小写/别名不一致很常见，本索引以刷怪行里的
   `ID` 作为唯一连接键，规避了这类问题。
2. **`is_mvp` 只表示 `MvpExp > 0` 的真 MVP**（如 Orc Hero、Mistress、Hatii/Garm）。像
   `Vocal (1088)` 这种“野外小 Boss”（`monster` 关键字 + 长刷新间隔、无 `MvpExp`）不会被该字段命中，
   也不是 `boss_monster` 刷出，因此 `boss_spawn_maps` 为空。**第 2 步的风险评分不能只靠 `is_mvp`**，
   还要用 `level / hp / attack` 差距来过滤这类高威胁怪。

## 已知边界

- 只索引**静态刷怪**。NPC 脚本里动态 `monster "map",x,y,...` 命令产生的活动/任务/MVP 召唤不在其中；
  对“选图打怪”而言静态刷怪才是可靠依据，动态召唤不属于可规划目标。
- 早期测试曾用 `npc/custom/bot_training_spawns.txt` 给 `prt_fild08` 补 Fabre/Chonchon/Willow/Roda Frog，
  属错误操作，已删除（文件与 `npc/scripts_custom.conf` 里的注释引用一并移除）。当前 `prt_fild08` 只有原生刷怪
  （Lunatic/Pupa/Poring/Drops）。**约定：禁止直接修改地图刷怪脚本。**
