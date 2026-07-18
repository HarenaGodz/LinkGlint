# LinkGlint 架构

## 目录

```text
LinkGlint/
├── LICENSE                         # MIT 开源许可证
├── Resources/                      # Info.plist 与应用图标
├── scripts/verify.sh               # 本地测试、构建与签名验证
├── Sources/LinkGlint/              # 菜单栏应用、界面与网络管理逻辑
├── Sources/LinkGlintHelper/        # 受限的本机权限助手
├── Tests/LinkGlintTests/           # 解析、偏好、方案和用量测试
├── build_app.sh                    # Intel/Apple Silicon 应用打包脚本
└── Package.swift                   # Swift Package 清单
```

## 运行结构

```mermaid
flowchart LR
    UI[主窗口 / 菜单栏] --> Manager[NetworkManager]
    Manager --> Read[networksetup / ifconfig 读取]
    Manager --> Helper[LinkGlintHelper]
    Helper --> Write[受限 networksetup 修改]
    Manager --> Profiles[配置方案]
    Manager --> Usage[流量与用量统计]
    Usage --> Chart[最近 60 次实时曲线]
```

主应用负责展示状态、读取系统网络信息和组织用户操作。需要修改网络设置时，
主应用通过 `sudo -n` 调用首次配置阶段安装的受限助手。助手只接受代码中定义的
网络操作，不接收任意可执行文件路径或 Shell 命令。

## 刷新与响应性

- 网络路径变化使用 600 毫秒防抖，避免接口切换期间反复重建界面。
- 各网络服务的只读详情最多并行读取 4 项，完成后仍按 macOS 服务优先级排序。
- 实时流量通过 `getifaddrs` 直接读取接口计数器，不为每次采样启动子进程。
- 状态栏与流量定时器加入主运行循环的 common mode，菜单操作期间也能继续采样。
- 面板关闭后仅保留轻量采样历史，不再更新不可见的 AppKit 曲线视图。
- 权限助手状态短期缓存；安装和移除在后台执行，管理员授权期间主线程保持响应。

## 应用生命周期

- 显示主窗口或偏好设置时使用标准应用模式，因此窗口可正常出现在 Dock 与应用切换器中。
- 关闭最后一个窗口后切换为辅助应用模式，Dock 图标消失，但状态栏项目、网络监视和定时器继续运行。
- 从状态栏选择“显示主窗口”或重新打开应用时恢复标准应用模式。

## NetBar 升级兼容

LinkGlint 保留 `local.codex.NetBar` Bundle ID 和状态栏位置标识，以继承 3.x 用户的
偏好设置、登录项批准与菜单栏位置。权限管理器优先使用新的 LinkGlint 助手，同时兼容
读取旧的 `local.codex.NetBarHelper`；用户可在偏好设置中一次性移除新旧两套配置。
