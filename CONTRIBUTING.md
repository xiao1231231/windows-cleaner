# Contributing

感谢你改进 Windows Cleaner。由于本项目包含永久删除能力，安全性优先于便利性和清理覆盖率。

## 提交变更

1. 从独立分支提交范围明确的修改。
2. 不要弱化默认只读、逐项批准、`PLAN_TOKEN`、保护路径、reparse point 或快照复验机制。
3. 不要在文档、Skill 指令或脚本中增加绕过 `scripts/delete.ps1` 的裸删除命令。
4. 修改 `scripts/delete.ps1`、任一扫描脚本或安全规则时，同步增加或更新 `tests/safety.ps1`。
5. 在 Windows PowerShell 5.1 中运行完整测试。
6. 在拉取请求中说明风险、行为变化和验证结果。

## 本地验证

```powershell
powershell -NoProfile -File ".\skills\windows-cleaner\tests\validate-skill.ps1"
powershell -NoProfile -File ".\skills\windows-cleaner\tests\safety.ps1"
```

测试必须以 `PASSED: all safety tests` 结束。影响删除行为的变更还应提供默认预览、保护路径拒绝和执行令牌校验的对应证据。

提交贡献即表示你同意按仓库的 MIT License 发布该贡献。
