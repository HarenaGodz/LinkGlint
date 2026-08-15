# LinkGlint 权限与隐私

## 系统权限

- **定位服务**：只用于读取附近 Wi‑Fi 名称，LinkGlint 不读取或上传坐标。
- **管理员授权**：首次配置时安装 root-owned 受限 helper，用于切换网络服务、修改 DNS、调整网络优先级和执行受保护的 Wi‑Fi 操作。
- **Wi‑Fi 密码**：只交给 CoreWLAN 完成关联，不写入命令行参数、日志或远程请求。

未完成管理员授权前，菜单栏仍可显示只读速率，但快捷面板、主窗口、偏好设置和网络写操作会被阻断；用户可以完成授权或退出应用。

## 出口 IP 与地理位置

快捷面板的出口 IP/地理位置查询会向以下公开服务发起短超时 HTTPS 请求：

- Cloudflare `1.1.1.1/cdn-cgi/trace`
- ipify `api.ipify.org`
- icanhazip `ipv4.icanhazip.com`
- geojs `get.geojs.io`
- ipinfo `ipinfo.io`

这些服务天然可以看到本机的网络出口 IP。LinkGlint 不附加设备标识、账号、Wi‑Fi 密码或遥测数据；结果只用于面板显示，并在本机短期缓存。

进程流量来自本机 `/usr/bin/nettop`，接口流量来自 macOS 系统计数器，不上传进程名、用量或网络服务状态。

## 本地数据

偏好、网络方案、每日用量和流量历史只保存在本机。项目不包含账号系统、遥测 SDK 或后台服务。
