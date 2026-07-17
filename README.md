<p align="center">
  <img src="docs/images/linkglint-logo.png" width="148" height="148" alt="LinkGlint 软件 Logo">
</p>

<h1 align="center">LinkGlint</h1>

<p align="center"><strong>让每一条网络连接，都在菜单栏清晰闪现。</strong></p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13%2B-111111?logo=apple" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-5.10-F05138?logo=swift&logoColor=white" alt="Swift 5.10">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="MIT License"></a>
</p>

**LinkGlint** 取自 *Link*（连接）与 *Glint*（微光）：它是一款原生 macOS
网络管理工具，让 Wi‑Fi、有线网络、VPN 与其他网络服务的状态和切换入口始终清晰可见。

![LinkGlint 3.2.0 简约主界面](docs/images/linkglint-3.2.0.png)

## 下载

预编译的 Intel 与 Apple Silicon 通用版本见 [GitHub Releases](https://github.com/HarenaGodz/LinkGlint/releases)。

## 功能

- 菜单栏以图标及“无线 / 有线 / VPN / 其他 · 网络名称”等文字实时显示当前网络状态
- 单击状态栏打开快捷管理面板；服务严格按 macOS 网络优先级显示并标注序号
- 面板支持切换、启停、重命名服务、连接其他 Wi‑Fi、快速方案及打开系统网络设置
- 状态栏可显示实时下载/上传速度，并支持单行或双行、Byte/bit 单位和 1/2/5 秒刷新间隔
- 彩色网络开关清晰区分启用与停用状态
- 简约原生主窗口：当前网络、方案和适配器开关一眼可见
- DNS、优先级、复制与切换等进阶操作统一收纳到每个适配器的“⋯”菜单
- 诊断、报告、用量、方案管理和系统设置统一收纳到“工具”菜单
- 关闭主窗口后自动移除 Dock 图标，程序和当前网络状态继续留在菜单栏
- 列出系统所有网络服务、设备名、连接状态与 IP 地址
- 显示默认出口、SSID、子网掩码、路由器、DNS 与 MAC 地址
- 单独启用/停用任意网络服务
- 一键切换到指定的 Wi‑Fi 或有线网络服务，并停用其他物理网络服务
- 单独打开/关闭 Wi‑Fi 硬件
- 系统网络路径发生变化时实时刷新，并保留每 12 秒定时刷新
- 每 2 秒显示各网络接口的实时下载/上传速率
- 一键复制 IP 地址或完整网络信息
- 一键检查默认网关延迟与 DNS 查询状态
- 复制或导出包含系统、路由、DNS、适配器和实时流量的诊断报告
- 内置“全部启用”“仅 Wi-Fi”“仅有线网络”三种快速配置方案
- 保存当前全部网络服务及 Wi-Fi 电源状态为自定义快照
- 从主窗口或菜单栏一键恢复、覆盖或删除自定义配置方案
- 统计当天与本次运行的下载/上传流量，并保留最近 30 天记录
- 直接读取系统网络计数器并按变化更新界面，避免周期性启动子进程和重复重建布局
- 查看最近 7 天用量、重置今日统计，诊断报告中自动附带用量历史
- 偏好设置可配置菜单栏网络名称、实时网速、单双行布局、速率单位、刷新间隔、启动窗口及自动诊断
- 查看每项网络服务的系统优先级并一键提升至最高优先级
- 为任意网络服务设置多个 IPv4/IPv6 DNS，留空即可恢复自动 DNS
- DNS 输入支持逗号、空格或换行分隔，并在应用前校验和去重
- 原生“登录时启动”开关（若系统要求，可直接打开登录项设置批准）
- 首次配置时只需一次 macOS 管理员授权，之后日常网络切换、DNS 与优先级修改不再输入密码
- 重新打开应用或从菜单栏选择“显示主窗口”时，Dock 图标随窗口恢复
- 快速打开 macOS 网络设置

## 构建

需要 macOS 13 或更新版本及 Xcode Command Line Tools：

```bash
chmod +x build_app.sh
./build_app.sh
open dist/LinkGlint.app
```

构建后的应用位于 `dist/LinkGlint.app`，默认同时支持 Apple Silicon 与 Intel Mac。
若只构建当前架构，可运行：

```bash
ARCHS="$(uname -m)" ./build_app.sh
```

运行完整的本地测试、构建和签名检查：

```bash
./scripts/verify.sh
```

启动后默认显示简约主窗口，同时也可从屏幕顶部菜单栏的当前网络状态进入。
状态栏会同时显示“无线 / 有线 / VPN / 其他”和当前网络或服务名称；单击图标会打开
日常网络管理面板，可直接切换、启停和重命名网络服务，也可输入 SSID 连接其他 Wi‑Fi。
右键图标仍可使用传统菜单。
关闭窗口时 Dock 图标会自动隐藏，但菜单栏状态、定时刷新和网络切换会继续运行；
重新打开应用或选择“显示主窗口”即可恢复窗口。
若正在使用菜单栏整理工具而暂时看不到状态，请先展开隐藏区域，再按住 `⌘`
将 LinkGlint 拖到分隔符右侧的常驻区域；主窗口和偏好设置中也保留了这条提示。

## 状态栏网速显示

在“LinkGlint 偏好设置”中可以分别控制网络名称和实时网速。网速支持：

- 单行：网络名称与 `↓ 下载速度 / ↑ 上传速度` 并排显示；
- 双行：第一行显示网络名称，第二行紧凑显示上下行速度；
- 仅网速：关闭网络状态文字后，可单行或分两行只显示上下行速度；
- 单位：在 `Byte/s` 与 `bit/s` 之间切换；
- 刷新间隔：1 秒、2 秒或 5 秒。

名称和网速都关闭时只保留网络类型图标，适合菜单栏空间较紧张的用户。

## 开机启动

从菜单栏或偏好设置打开“登录时启动”即可使用 macOS 原生登录项。若系统显示“需要批准”，
按应用提示在“系统设置 → 通用 → 登录项”中允许 LinkGlint。此设置不要求管理员密码。

## 首次权限配置

点击主窗口的“首次配置…”并完成一次 macOS 管理员授权。LinkGlint 会将一个受限助手
安装到 `/Library/PrivilegedHelperTools/io.github.harenagodz.LinkGlintHelper`，并为当前用户创建
仅限该助手的 `sudo -n` 规则。之后启用/停用适配器、Wi‑Fi 电源、DNS、优先级、
配置方案和一键切换均不会再次弹出密码窗口。

助手由 `root:wheel` 持有且不可由普通用户写入；它只接受固定的网络操作，直接启动
`/usr/sbin/networksetup`，不接收任意程序路径或 Shell 命令。可随时从偏好设置移除，
移除动作会再次请求一次管理员授权。

从早期版本升级后，如偏好设置提示“权限需修复”，请完成一次管理员授权来更新受限助手；
新版助手增加了连接其他 Wi‑Fi 与重命名网络服务所需的固定命令，仍不接受任意 Shell 命令。

## 实现说明

程序通过 macOS 自带的 `/usr/sbin/networksetup` 读取及更改网络配置，并通过
`/sbin/ifconfig` 判断链路状态。安装阶段的固定脚本仅通过位置参数接收路径和账号；
日常网络修改由受限助手直接执行，不使用 Shell 拼接用户可见的网络服务名称。

项目目录及运行结构见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)，版本变化见
[`CHANGELOG.md`](CHANGELOG.md)。构建产物、测试临时文件和本地发布包均通过
`.gitignore` 排除，不进入源码仓库。

## 许可证

LinkGlint 使用宽松的 [MIT License](LICENSE)。你可以使用、复制、修改、分发及用于
商业项目，但需要在副本或软件的主要部分中保留版权和许可证声明。

## 关于作者

LinkGlint 由 **HarenaGodz（Harena）** 开发并维护。应用内可从状态栏面板、右键菜单或
主窗口“工具”菜单打开“关于 LinkGlint”，查看版本、构建号、作者、项目地址与许可证。
