# OpenKore 机器人实例配置（模板化）

这里是五个机器人（bot01–bot05）运行配置的**版本化来源**。运行态实例在
`服务端运行目录/openkore-local/instances/<bot>/control/`，由 `openkore-control.sh deploy-config`
从本目录渲染部署。

## 目录结构

```text
instances/
├── shared-control/          # 16 个五个机器人完全一致的控制文件
│   ├── sys.txt              # loadPlugins_list 已含 world_ai / autoGear
│   ├── mon_control.txt
│   ├── items_control.txt
│   ├── timeouts.txt
│   └── ...（其余）
├── bot01/config.txt.template
├── ...
├── bot05/config.txt.template
├── secrets.example.txt      # 机密文件格式示例（入库）
└── secrets.local.txt        # 真实机密（已被 .gitignore 忽略，不入库）
```

## 为什么只有 config.txt 需要模板

五个机器人的 17 个控制文件里，只有 `config.txt` 因凭据、职业、技能加点、
`attackEquip_arrow`、原生 `lockMap` 和 `world_ai_auto_execute` 而逐机不同；其余
16 个文件（`sys.txt`、`mon_control.txt`、`items_control.txt`、`timeouts.txt` 等）
五个完全一致，统一放在 `shared-control/`。

## 机密处理

`config.txt` 顶部含登录凭据：`username`、`password`（五机共享）、`loginPinCode`、
`adminPassword`。模板把这些值替换为占位符，真实值只存在本地 `secrets.local.txt`
（不入库）：

```text
password <shared_password>
bot01 <username> <pin> <adminPassword>
bot02 <username> <pin> <adminPassword>
...
```

首次部署：复制 `secrets.example.txt` 为 `secrets.local.txt` 并填入真实值。

## 部署

```bash
# 渲染所有机器人的 config.txt，并同步 shared-control 到运行态
./OpenKore机器人/脚本/openkore-control.sh deploy-config
```

`deploy-config` 幂等：重跑只会用模板+机密重新生成 `config.txt`。配置在重启后才生效；
对运行中的机器人执行无副作用（OpenKore 只在启动时读 `config.txt`）。

## 维护约定

- 改职业加点 / 技能 / 箭头等**非机密**配置：直接改 `botXX/config.txt.template`，然后
  `deploy-config` + 重启对应机器人。
- 改共享配置（`mon_control`、`items_control` 等）：改 `shared-control/`，然后
  `deploy-config`。
- 改凭据：只改本地 `secrets.local.txt`，不要提交。
- `config.txt` 本身仍被 `.gitignore` 忽略，运行态文件不作为版本来源。
