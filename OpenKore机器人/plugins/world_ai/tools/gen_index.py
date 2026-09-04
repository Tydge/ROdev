#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_index.py — 生成 OpenKore 动态练级所需的“怪物↔地图”静态索引。

把 rAthena Pre-Renewal 的怪物数值库与静态刷怪脚本合并成一份 map_index.json：

  来源 1（怪物数值）：db/pre-re/mob_db.yml
  来源 2（静态刷怪）：由 npc/scripts_monsters.conf、npc/pre-re/scripts_monsters.conf、
                        npc/scripts_custom.conf 中“未注释”的 npc: 行决定。

只依赖 Python 标准库，不需要 PyYAML：mob_db.yml 使用与本文档匹配的子集解析
（两空格缩进的 "- Id:" 列表项 + 四空格缩进的 "Key: value" 字段）。

必需数据源缺失时默认以非零码退出，且不写输出文件，避免用一次路径错误覆盖有效索引；
只有显式传入 --allow-partial 才允许降级（写部分/空索引并返回 0）。

用法：
    python3 gen_index.py [--rathena-root PATH] [--out PATH] [--extra-spawn FILE]... [--allow-partial]
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys

DEFAULT_RATHENA_ROOT = "/Users/wangtaizhi/Documents/Codex/2026-08-22/j/outputs/ro-local/rathena"

# 怪物数值库（Pre-Renewal）。db/mob_db.yml 只是导入桩，真正的数据在这里。
MOB_DB_REL = "db/pre-re/mob_db.yml"

# 元素克制表（Pre-Renewal），是 Fire/Holy 技能评分的权威来源。
ATTR_FIX_REL = "db/pre-re/attr_fix.yml"

# 定义静态刷怪脚本集合的 conf。按顺序解析，未注释的 `npc:` 行才是真正加载的刷怪文件。
SPAWN_CONF_RELS = [
    "npc/scripts_monsters.conf",
    "npc/pre-re/scripts_monsters.conf",
    "npc/scripts_custom.conf",
]

# mob_db 中抽取的字段。WalkSpeed 也是数值（rAthena DEFAULT_WALK_SPEED = 150），
# 放在整数字段里，避免生成出字符串类型的 walk_speed。
INT_FIELDS = {
    "Level": 1, "Hp": 1, "Sp": 1, "BaseExp": 0, "JobExp": 0, "MvpExp": 0,
    "Attack": 0, "Attack2": 0, "Defense": 0, "MagicDefense": 0,
    "Str": 1, "Agi": 1, "Vit": 1, "Int": 1, "Dex": 1, "Luk": 1,
    "AttackRange": 0, "SkillRange": 0, "ChaseRange": 0, "ElementLevel": 1,
    "WalkSpeed": 150,
}
STR_FIELDS = {
    "AegisName": "", "Name": "", "JapaneseName": "",
    "Size": "Small", "Race": "Formless", "Element": "Neutral",
}

# 输出 schema 断言：这些键在最终 JSON 里必须是整数。
SCHEMA_INT_KEYS = [
    "id", "level", "hp", "base_exp", "job_exp", "mvp_exp",
    "attack", "attack2", "defense", "magic_defense",
    "element_level", "walk_speed", "attack_range", "skill_range",
]
SCHEMA_STR_KEYS = ["aegis_name", "name", "size", "race", "element"]

# 怪物 AI 模式：mob_db.yml 的 `Ai:` 是 Aegis 怪物类型名（MONSTER_TYPE_XX），
# 不是直接可读的位掩码。真正的 mode 位掩码来自 rAthena src/map/mob.hpp 的
# `enum e_aegis_monstertype`。`Modes:` 是稀疏的位覆盖表（MD_* 位），叠加在 Ai 之上。
MONSTER_TYPE = {
    "01": 0x81, "02": 0x83, "03": 0x1089, "04": 0x3885, "05": 0x2085,
    "06": 0x0, "07": 0x108B, "08": 0x7085, "09": 0x3095, "10": 0x84,
    "11": 0x84, "12": 0x2085, "13": 0x308D, "17": 0x91, "19": 0x3095,
    "20": 0x3295, "21": 0x3695, "24": 0xA1, "25": 0x1, "26": 0xB695,
    "27": 0x8084,
}

# 与 src/common/mmo.hpp 的 e_mode 位一致。Modes: 块里的键直接以 "MD_<键>" 形式
# 解析，所以这里只保留当前 mob_db.yml 实际用到的覆盖键。
MD = {
    "CanMove": 0x1, "Looter": 0x2, "Aggressive": 0x4, "Assist": 0x8,
    "CastSensorIdle": 0x10, "NoRandomWalk": 0x20, "NoCast": 0x40,
    "CanAttack": 0x80, "CastSensorChase": 0x200, "ChangeChase": 0x400,
    "Angry": 0x800, "ChangeTargetMelee": 0x1000, "ChangeTargetChase": 0x2000,
    "TargetWeak": 0x4000, "RandomTarget": 0x8000, "IgnoreMelee": 0x10000,
    "IgnoreMagic": 0x20000, "IgnoreRanged": 0x40000, "Mvp": 0x80000,
    "IgnoreMisc": 0x100000, "KnockbackImmune": 0x200000,
    "TeleportBlock": 0x400000, "FixedItemDrop": 0x1000000,
    "Detector": 0x2000000, "StatusImmune": 0x4000000,
    "SkillImmune": 0x8000000,
}

# 输出为可解释布尔的位。cast_sensor 合并 idle 与 chase 两个位。
MODE_FLAG_BITS = [
    ("can_move", 0x1),
    ("looter", 0x2),
    ("aggressive", 0x4),
    ("assist", 0x8),
    ("cast_sensor", 0x10 | 0x200),
    ("can_attack", 0x80),
    ("mvp", 0x80000),
    ("ignore_melee", 0x10000),
    ("ignore_magic", 0x20000),
    ("ignore_ranged", 0x40000),
    ("ignore_misc", 0x100000),
    ("detector", 0x2000000),
]

ID_LINE_RE = re.compile(r"^  - Id:\s*(\d+)\s*$")
FIELD_LINE_RE = re.compile(r"^    ([A-Za-z][A-Za-z0-9_]*):\s*(.*?)\s*$")
MODE_LINE_RE = re.compile(r"^      ([A-Za-z][A-Za-z0-9_]*):\s*(true|false)\s*$")
MAP_NAME_RE = re.compile(r"^[A-Za-z0-9_@]+$")

ATTR_LEVEL_RE = re.compile(r"^  - Level:\s*(\d+)\s*$")
ATTR_OUTER_RE = re.compile(r"^    ([A-Za-z]+):\s*$")
ATTR_INNER_RE = re.compile(r"^      ([A-Za-z]+):\s*(-?\d+)\s*$")


def log(msg):
    print(msg, file=sys.stderr)


def parse_mob_db(path):
    """解析 pre-re mob_db.yml，返回 { mob_id(int): {字段: 值} }。

    额外捕获 `Ai`（字符串，默认 "06"）与 `Modes:` 覆盖块（存入 "_modes" 字典）。
    """
    monsters = {}
    cur = None
    in_modes = False
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.lstrip().startswith("#"):
                continue
            m = ID_LINE_RE.match(line)
            if m:
                mid = int(m.group(1))
                cur = dict(INT_FIELDS)
                cur.update(STR_FIELDS)
                cur["Id"] = mid
                cur["Ai"] = "06"
                cur["_modes"] = {}
                monsters[mid] = cur
                in_modes = False
                continue
            if cur is None:
                continue
            if in_modes:
                mm = MODE_LINE_RE.match(line)
                if mm:
                    cur["_modes"][mm.group(1)] = mm.group(2) == "true"
                    continue
                in_modes = False
            m = FIELD_LINE_RE.match(line)
            if not m:
                continue
            key, raw = m.group(1), m.group(2)
            if key == "Modes":
                in_modes = True
                continue
            if key == "Ai":
                cur["Ai"] = raw.strip() or "06"
                continue
            if key in INT_FIELDS:
                try:
                    cur[key] = int(raw)
                except ValueError:
                    pass
            elif key in STR_FIELDS:
                cur[key] = raw
    return monsters


def parse_attr_fix(path):
    """解析 pre-re attr_fix.yml，返回 { level(int): { 攻击元素: { 防御元素: % } } }。"""
    table = {}
    cur_level = None
    cur_outer = None
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            m = ATTR_LEVEL_RE.match(line)
            if m:
                cur_level = int(m.group(1))
                table[cur_level] = {}
                cur_outer = None
                continue
            m = ATTR_OUTER_RE.match(line)
            if m and cur_level is not None:
                cur_outer = m.group(1)
                table[cur_level][cur_outer] = {}
                continue
            m = ATTR_INNER_RE.match(line)
            if m and cur_level is not None and cur_outer is not None:
                table[cur_level][cur_outer][m.group(1)] = int(m.group(2))
                continue
    return table


def compute_mode(mob):
    """由 Ai 类型名 + Modes 覆盖块算出最终 mode 位掩码。"""
    base = MONSTER_TYPE.get(mob.get("Ai", "06"), 0)
    raw = base
    for key, active in (mob.get("_modes") or {}).items():
        bit = MD.get(key)
        if bit is None:
            continue
        if active:
            raw |= bit
        else:
            raw &= ~bit
    return raw


def conf_npc_paths(conf_path):
    """提取 conf 中未注释的 `npc: <path>` 行（相对 rAthena 根）。"""
    paths = []
    with open(conf_path, encoding="utf-8") as fh:
        for line in fh:
            stripped = line.strip()
            if not stripped or stripped.startswith("//"):
                continue
            m = re.match(r"^npc:\s*(\S+)", stripped)
            if m:
                paths.append(m.group(1))
    return paths


def collect_spawn_files(root, errors):
    """按 conf 里的未注释 npc: 行收集刷怪脚本。缺失的 conf/引用文件记入 errors。"""
    files, seen = [], set()
    for conf_rel in SPAWN_CONF_RELS:
        conf_path = os.path.join(root, conf_rel)
        if not os.path.isfile(conf_path):
            errors.append("必需的 conf 缺失: %s" % conf_rel)
            continue
        for rel in conf_npc_paths(conf_path):
            full = os.path.join(root, rel)
            if full in seen:
                continue
            if not os.path.isfile(full):
                errors.append("conf %s 引用的刷怪文件缺失: %s" % (conf_rel, rel))
                continue
            seen.add(full)
            files.append((full, rel))
    return files


def parse_spawn_file(path, rel, spawns):
    """解析一个刷怪脚本，产出 (map, mob_id, count, is_boss, rel, line_no) 列表项。"""
    found = 0
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.rstrip("\n").rstrip("\r")
            if "\t" not in line:
                continue
            parts = line.split("\t")
            if len(parts) < 4:
                continue
            mapfield, keyword, _, spawnspec = parts[0], parts[1], parts[2], parts[3]
            if keyword not in ("monster", "boss_monster"):
                continue
            mapname = mapfield.split(",")[0]
            if not MAP_NAME_RE.match(mapname):
                continue
            specparts = spawnspec.split(",")
            if len(specparts) < 2:
                continue
            try:
                mob_id = int(specparts[0])
                count = int(specparts[1])
            except ValueError:
                continue
            spawns.append((mapname, mob_id, count, keyword == "boss_monster", rel, lineno))
            found += 1
    return found


def build_monster_entry(mob):
    raw_mode = compute_mode(mob)
    mode = {"mode_raw": raw_mode}
    for name, bit in MODE_FLAG_BITS:
        mode[name] = bool(raw_mode & bit)
    return {
        "id": mob["Id"],
        "aegis_name": mob.get("AegisName", ""),
        "name": mob.get("Name") or mob.get("AegisName") or "",
        "level": mob["Level"],
        "hp": mob["Hp"],
        "base_exp": mob["BaseExp"],
        "job_exp": mob["JobExp"],
        "mvp_exp": mob["MvpExp"],
        "is_mvp": mob["MvpExp"] > 0,
        "attack": mob["Attack"],
        "attack2": mob["Attack2"],
        "defense": mob["Defense"],
        "magic_defense": mob["MagicDefense"],
        "size": mob["Size"],
        "race": mob["Race"],
        "element": mob["Element"],
        "element_level": mob["ElementLevel"],
        "walk_speed": mob["WalkSpeed"],
        "attack_range": mob["AttackRange"],
        "skill_range": mob["SkillRange"],
        "mode": mode,
        "maps": {},
        "boss_spawn_maps": [],
    }


def validate_index(monsters_out):
    """schema 断言：关键字段类型必须与文档契约一致，否则抛 AssertionError。"""
    for mid, entry in monsters_out.items():
        for key in SCHEMA_INT_KEYS:
            val = entry.get(key)
            if not isinstance(val, int):
                raise AssertionError(
                    "monster %s 字段 %s 应为 int，实际为 %r (%s)"
                    % (mid, key, val, type(val).__name__)
                )
        for key in SCHEMA_STR_KEYS:
            val = entry.get(key)
            if not isinstance(val, str):
                raise AssertionError(
                    "monster %s 字段 %s 应为 str，实际为 %r (%s)"
                    % (mid, key, val, type(val).__name__)
                )
        if not isinstance(entry.get("is_mvp"), bool):
            raise AssertionError("monster %s 字段 is_mvp 应为 bool" % mid)
        mode = entry.get("mode")
        if not isinstance(mode, dict):
            raise AssertionError("monster %s 字段 mode 应为 object" % mid)
        if not isinstance(mode.get("mode_raw"), int):
            raise AssertionError("monster %s 字段 mode.mode_raw 应为 int" % mid)
        for name, _bit in MODE_FLAG_BITS:
            if not isinstance(mode.get(name), bool):
                raise AssertionError(
                    "monster %s 字段 mode.%s 应为 bool" % (mid, name))


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def git_info(root):
    """返回 (commit_hash, dirty)。git 不可用或 root 非 git 仓库时返回 (None, None)。"""
    try:
        rev = subprocess.run(
            ["git", "-C", root, "rev-parse", "HEAD"],
            capture_output=True, text=True, timeout=15,
        )
        if rev.returncode != 0 or not rev.stdout.strip():
            return None, None
        commit = rev.stdout.strip()
        status = subprocess.run(
            ["git", "-C", root, "status", "--porcelain"],
            capture_output=True, text=True, timeout=15,
        )
        dirty = status.returncode == 0 and bool(status.stdout.strip())
        return commit, dirty
    except Exception:
        return None, None


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--rathena-root", default=DEFAULT_RATHENA_ROOT)
    ap.add_argument("--out", default=None)
    ap.add_argument("--extra-spawn", action="append", default=[],
                    help="额外纳入的刷怪脚本（相对 rAthena 根或绝对路径），可多次指定")
    ap.add_argument("--allow-partial", action="store_true",
                    help="必需数据源缺失时仍降级写出部分/空索引（默认失败退出且不写文件）")
    args = ap.parse_args(argv)

    root = os.path.abspath(args.rathena_root)
    errors = []

    mob_db_path = os.path.join(root, MOB_DB_REL)
    if not os.path.isfile(mob_db_path):
        errors.append("必需的 mob_db 缺失: %s" % MOB_DB_REL)
        monsters = {}
    else:
        monsters = parse_mob_db(mob_db_path)
        log("[info] mob_db 解析完成，共 %d 条怪物" % len(monsters))

    attr_fix_path = os.path.join(root, ATTR_FIX_REL)
    if not os.path.isfile(attr_fix_path):
        errors.append("必需的 attr_fix 缺失: %s" % ATTR_FIX_REL)
        element_table = {}
    else:
        element_table = parse_attr_fix(attr_fix_path)
        log("[info] attr_fix 解析完成，共 %d 个元素等级" % len(element_table))

    spawn_files = collect_spawn_files(root, errors)

    for extra in args.extra_spawn:
        full = extra if os.path.isabs(extra) else os.path.join(root, extra)
        if not os.path.isfile(full):
            errors.append("--extra-spawn 文件缺失: %s" % extra)
            continue
        if not any(f == full for f, _ in spawn_files):
            spawn_files.append((full, extra))

    spawns = []
    for full, rel in spawn_files:
        n = parse_spawn_file(full, rel, spawns)
        log("[info] %-45s 静态刷怪 %d 条" % (rel, n))

    if not spawn_files:
        errors.append("未收集到任何刷怪脚本（conf 缺失或全部被注释）")
    if not spawns:
        errors.append("未解析到任何静态刷怪记录")

    monsters_out = {}
    maps_out = {}
    boss_maps = {}
    unresolved = {}
    spawn_records = 0

    for mapname, mob_id, count, is_boss, rel, lineno in spawns:
        if mob_id not in monsters:
            unresolved.setdefault(mob_id, []).append((mapname, rel, lineno))
            continue
        spawn_records += 1
        entry = monsters_out.get(mob_id)
        if entry is None:
            entry = build_monster_entry(monsters[mob_id])
            monsters_out[mob_id] = entry
        entry["maps"][mapname] = entry["maps"].get(mapname, 0) + count
        if is_boss:
            boss_maps.setdefault(mob_id, set()).add(mapname)
        m = maps_out.setdefault(mapname, {})
        m[mob_id] = m.get(mob_id, 0) + count

    for mid, mapset in boss_maps.items():
        monsters_out[mid]["boss_spawn_maps"] = sorted(mapset)

    ordered_monsters = {
        str(mid): monsters_out[mid] for mid in sorted(monsters_out.keys())
    }
    for entry in ordered_monsters.values():
        entry["maps"] = {m: entry["maps"][m] for m in sorted(entry["maps"].keys())}
    ordered_maps = {
        m: {str(mid): maps_out[m][mid] for mid in sorted(maps_out[m].keys())}
        for m in sorted(maps_out.keys())
    }

    # schema 断言始终生效（即使 --allow-partial）；类型不符是生成器 bug，必须失败。
    try:
        validate_index(ordered_monsters)
    except AssertionError as exc:
        log("[fatal] schema 校验失败: %s" % exc)
        return 2

    # 来源指纹：记录每个输入文件的 SHA-256 与 rAthena git 状态，便于审计与复现。
    input_sha256 = {}
    if os.path.isfile(mob_db_path):
        input_sha256[MOB_DB_REL] = sha256_file(mob_db_path)
    if os.path.isfile(attr_fix_path):
        input_sha256[ATTR_FIX_REL] = sha256_file(attr_fix_path)
    for full, rel in spawn_files:
        try:
            input_sha256[rel] = sha256_file(full)
        except OSError:
            pass
    commit, dirty = git_info(root)

    # 报告被注释掉、当前未加载的“自定义补怪”脚本，便于人工核对。
    disabled_custom = []
    custom_conf = os.path.join(root, "npc/scripts_custom.conf")
    if os.path.isfile(custom_conf):
        with open(custom_conf, encoding="utf-8") as fh:
            for line in fh:
                if line.lstrip().startswith("//"):
                    m = re.search(r"npc:\s*(\S+)", line)
                    if m and ("spawn" in m.group(1) or "mob" in m.group(1)):
                        disabled_custom.append(m.group(1))

    if errors:
        if not args.allow_partial:
            for e in errors:
                log("[error] %s" % e)
            log("[fatal] 存在 %d 个必需数据源问题，未写入输出。"
                "若确要降级生成部分索引，请显式传 --allow-partial。" % len(errors))
            return 1
        for e in errors:
            log("[warn] (partial) %s" % e)

    doc = {
        "meta": {
            "schema_version": 3,
            "generated_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            "sources": {
                "mob_db": MOB_DB_REL,
                "attr_fix": ATTR_FIX_REL,
                "spawn_files": [rel for _, rel in spawn_files],
                "spawn_file_count": len(spawn_files),
                "input_sha256": input_sha256,
                "rathena_git": {"commit": commit, "dirty": dirty} if commit else None,
            },
            "counts": {
                "monsters_indexed": len(ordered_monsters),
                "maps_indexed": len(ordered_maps),
                "spawn_records": spawn_records,
                "unresolved_spawn_ids": {
                    str(mid): len(spots) for mid, spots in sorted(unresolved.items())
                },
                "disabled_custom_spawns": sorted(disabled_custom),
            },
        },
        "monsters": ordered_monsters,
        "maps": ordered_maps,
        "element_table": element_table,
    }

    out = args.out
    if out is None:
        out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "map_index.json")
    out = os.path.abspath(out)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=2)
        fh.write("\n")

    log("[info] 写入 %s" % out)
    log("[info] 汇总: 可狩猎怪物 %d / 地图 %d / 刷怪记录 %d"
        % (len(ordered_monsters), len(ordered_maps), spawn_records))
    if unresolved:
        log("[warn] %d 个刷怪 ID 在 mob_db 中不存在: %s"
            % (len(unresolved), ", ".join(sorted(str(k) for k in unresolved))))
    if disabled_custom:
        log("[note] 以下自定义刷怪脚本在 scripts_custom.conf 中被注释、当前未加载: %s"
            % ", ".join(sorted(disabled_custom)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
