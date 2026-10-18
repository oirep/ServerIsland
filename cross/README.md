# ServerIsland for Windows / Linux

ServerIsland 的 Windows / Linux 版本（Avalonia + .NET 10）。Mac 版见仓库根目录（Swift）。

## 安装

- **Windows 10 / 11（Intel / AMD，64 位）**：解压 `ServerIsland-<版本>-win-x64.zip`，双击 `ServerIsland.exe`。不需要安装 .NET。
  第一次运行时如果出现"Windows 已保护你的电脑"，点 **更多信息 → 仍要运行**（程序没有付费签名）。
- **Linux（x64）**：解压 `ServerIsland-<版本>-linux-x64.tar.gz`，运行 `./ServerIsland`。需要 X11 或 XWayland，以及系统托盘支持。

## 和 Mac 版的区别

- 没有硬件刘海：默认是**屏幕顶部正中的灵动岛**，鼠标移上去展开；也可以在 设置 → 通用 → 显示方式 改成**桌面小章鱼**（Tako 待在桌面上，可以拖动）。
- 通知区域（托盘）里有 Tako 图标：点击打开并固定面板，右键菜单可以刷新、切换显示方式、打开设置、退出。
- SSH：Windows 上默认用**内置 SSH**——读取 `%USERPROFILE%\.ssh\config` 和 `known_hosts`，每台服务器保持一条连接；第一次连接要确认主机指纹，密码 / 动态口令 / 密钥口令在弹出的对话框里输入，不会保存。暂不支持 ssh-agent 和 ProxyCommand，遇到这种情况可以在 设置 → 通用 → SSH 实现 改成"系统 ssh"。Linux 上默认用系统 ssh（和 Mac 版一样复用连接）。
- Windows 上提醒以弹窗和提示音为主（没有系统通知）。

## 开发

```bash
brew install dotnet                     # 或从 dot.net 安装 .NET 10 SDK
cd cross/src/ServerIsland.Desktop
dotnet run -- --demo                    # 演示模式
dotnet run -- --selftest                # 自检
dotnet run -- --render-preview /tmp/si  # 预览图
cross/scripts/publish.sh                # 打包
```

更多说明见 [`references/cross-platform.md`](../references/cross-platform.md)。
