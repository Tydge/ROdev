# world_ai_test

用于验证本服 OpenKore 原生跨地图寻路以及“指定怪物 → 选图 → 前往 → 正常攻击”的最小实验插件。

命令：

```text
worldtest nav <map>
worldtest hunt <monster>
worldtest status
worldtest stop
```

当前测试表只有 Poring 与 Rocker。插件不实现路径算法，`nav` 和 `hunt` 都通过 `Commands::run("move <map>")` 间接创建本机版本的 `Task::MapRoute`。

`hunt` 会通过 `configModify` 临时切换 `lockMap`，并在内存中临时放行目标怪物；执行 `worldtest stop`、测试失败或卸载插件时恢复原值。目标怪物攻击由 OpenKore 原有战斗 AI 完成。

