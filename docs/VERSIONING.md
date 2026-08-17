# 版本管理

本项目的用户可见版本由 `project.yml` 维护：

- `MARKETING_VERSION` 是展示给用户的 `主版本.次版本.修订版本`，例如 `0.1.0`。
- `CURRENT_PROJECT_VERSION` 是同一营销版本下递增的构建号。
- `Resources/Info.plist` 由 XcodeGen 根据 `project.yml` 生成或覆盖，不要手工修改。

## 更新记录

应用内“版本更新记录”的唯一来源是 `Resources/VersionHistory.json`。每次修改用户可见版本时：

1. 更新 `project.yml` 的 `MARKETING_VERSION`；如构建号变化，同时递增 `CURRENT_PROJECT_VERSION`。
2. 在 `VersionHistory.json` 顶部新增对应版本，填写 `version`、`build`、`releaseDate`（`YYYY-MM-DD`）和面向用户的 `changes`。
3. 保持条目按语义化版本从新到旧排列，版本号不得重复，每条至少保留一项更新说明。

版本号规则：不兼容的用户可见变更递增主版本；兼容的新功能递增次版本；兼容的问题修复递增修订版本。构建号只增不减。

## 提交前检查

```bash
swift test
./scripts/generate_project.sh
./scripts/test.sh
git diff --check
```

Windows 环境可运行 `swift test` 和静态检查；XcodeGen、模拟器测试及 IPA 构建由 macOS 或 GitHub Actions 完成。
