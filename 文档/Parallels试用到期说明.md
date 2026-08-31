# Parallels 试用到期说明

本机检测结果（2026-08-24）：

```text
Parallels Desktop 20.4.2
edition="pro"
is_trial="yes"
expiration="09/05/2026 23:59:59"
```

这里的日期格式为美国格式，即试用将在 **2026-09-05 23:59:59** 到期。

## 到期后会怎样

Parallels 官方说明 14 天试用不能延长。到期后需要正式许可证才能继续正常启动/恢复 Windows 虚拟机。现有 `.pvm` 虚拟机、Windows、RO 客户端和角色存档不会因为试用到期而被删除。

购买正式完整版并输入密钥后，不需要重新安装 Parallels、Windows 或 RO。路径是 Parallels Desktop 菜单 → `Account & License` → 输入许可证密钥。

注意：从试用版购买时需要“完整许可证”，不能购买仅面向已有旧版用户的 Upgrade 升级许可证。

## 选哪个版本

- 只运行这一套 RO：Standard 的 4 vCPU / 8 GB vRAM 上限已经够用，成本优先可选 Standard。Standard 官方同时提供订阅和一次性购买；一次性版可长期使用购买时的版本，但不保证未来大版本 macOS 的兼容更新。
- 希望当前基于 `prlctl` 的一键启动/暂停脚本原样长期使用：官方把命令行界面列为 Pro 功能，选择 Pro 最稳妥，但仅为玩 RO 会有些过度配置。
- 如果购买 Standard 后命令行被限制：服务端一键启停仍能工作，只需改成用 Parallels 图形界面手动启动/暂停 Windows，或者再把脚本改造成 Standard 兼容方式。

购买前可先在官方结账页确认中国区最终价格和税费，不要只依据旧文章中的价格。

## 官方资料

- 试用政策：https://kb.parallels.com/en/124227
- 试用后激活：https://kb.parallels.com/uk/124225?language=en
- 版本与购买方式：https://www.parallels.com/products/desktop/buy/
