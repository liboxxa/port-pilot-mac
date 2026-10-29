# PortPilot

PortPilot 是一个 macOS 本地开发端口面板，用于查看当前监听的 TCP/UDP 端口，并通过自定义命令在 Terminal 中一键启动开发服务。

维护人：libo

## 当前功能

- 右上角悬浮窗口和菜单栏常驻
- 登录后自动启动
- 每 3 秒只查询已配置开发端口的 TCP/UDP 状态
- 显示端口、协议、地址、进程和 PID
- 为端口保存自定义启动命令和工作目录
- 在新的 Terminal 窗口中启动服务
- 启动指令保存在本机用户配置中

## 构建运行

```bash
./Scripts/build-app.sh
open .build/PortPilot.app
```

首次通过启动指令打开 Terminal 时，macOS 可能会请求自动化权限。

## 说明

端口扫描使用系统自带的 `/usr/sbin/lsof`，不需要额外安装 Node、Python 或其他运行时。只有在“启动指令”中配置过的端口会被查询和展示；系统服务端口不会出现在面板中。当前版本只负责发现监听端口和启动服务，不会自动结束已有进程。
