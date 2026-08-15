# LinkGlint 开发与发布

## 环境

- macOS 13 或更高版本
- Xcode Command Line Tools
- Swift 5.10
- Intel 或 Apple Silicon

## 常用命令

```bash
swift test
swift build -Xswiftc -warnings-as-errors
ARCHS="x86_64 arm64" ./scripts/verify.sh
./scripts/package-dmg.sh
```

`build_app.sh` 是兼容入口，实际实现位于 `scripts/build-app.sh`。构建结果写入被忽略的 `dist/`。

## 目录

- `Sources/LinkGlint/`：应用、协调器、网络、权限和 UI
- `Sources/LinkGlintHelper/`：root helper executable
- `Sources/LinkGlintHelperSupport/`：可单测的 helper 参数和请求模型
- `Tests/LinkGlintTests/`：按子系统组织的单元测试
- `Resources/DMG/`：DMG 背景源图
- `scripts/`：构建、验证、背景渲染和 DMG 打包

## DMG

`scripts/package-dmg.sh` 会构建 `x86_64 arm64` Universal app，生成 Finder 拖拽安装窗口，输出：

```text
dist/LinkGlint-3.10.0-universal.dmg
dist/LinkGlint-3.10.0-universal.dmg.sha256
```

本地包使用 ad-hoc 签名，不包含 Developer ID 或 notarization。首次启动可能需要在访达中右击应用并选择“打开”。

## Release 检查清单

1. 测试、warnings-as-errors、`git diff --check` 全部通过。
2. app 和 helper 都包含 `x86_64 arm64`。
3. `codesign --verify --deep --strict` 通过。
4. DMG 通过 `hdiutil verify`，只读挂载后包含正确应用、Applications 链接和背景。
5. SHA-256 与最终上传文件一致。
6. GitHub PR CI 通过后再合并、打 `v3.10.0` 标签并发布 Release。
