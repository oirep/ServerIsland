# 构建与发布

## 环境

- 只有 Command Line Tools（`/Library/Developer/CommandLineTools`），Swift 5.10，SDK 14.4，没有 Xcode。
- `notarytool`、`stapler`、`hdiutil`、`codesign`、`SetFile`、`iconutil`、`sips` 都可以用。
- 目前**没有任何签名证书**（`security find-identity -v -p codesigning` 返回 0 个）。

## 构建

```bash
swift build                     # 调试构建：.build/debug/ServerIsland
./scripts/build_app.sh          # release 构建 → build/ServerIsland.app（ad-hoc 签名）
./scripts/build_app.sh --run    # 构建后重启 App
./scripts/install_local.sh      # 构建后替换 /Applications/ServerIsland.app 并启动（DEST=目录 可改安装位置）
```
`install_local.sh` 会先退出正在运行的 ServerIsland（包括在 Mac 上试用的跨平台版），只编译本机的架构，设置不受影响；装好后删掉 `build/ServerIsland.app`，免得启动台 / 聚焦搜索里出现两个 ServerIsland（`.metadata_never_index` 对普通文件夹不起作用）。

**一次打三个平台**：`./scripts/package_all.sh` 依次运行 `make_dmg.sh`（通用二进制 DMG）、`cross/scripts/publish.sh`（win-x64 zip、linux-x64 tar.gz），再用 `install_local.sh --no-build` 把刚打好的通用版装到 /Applications，最后打印三个包的大小和 SHA-256（写进发布说明）。Info.plist 和 `cross/Directory.Build.props` 的版本号不一致时直接报错。
`build_app.sh` 会把 Info.plist、AppIcon.icns、`Resources/Sounds/`、菜单栏 PNG 复制进 .app。
App 是非沙盒的，因为要读 `~/.ssh`、调用 ssh，所以**上不了 Mac App Store**。`Info.plist` 里设置了 `LSUIElement=true`，App 不在 Dock 里显示。

## DMG（方案 A，当前在用）

```bash
./scripts/make_dmg.sh           # → build/ServerIsland-<CFBundleShortVersionString>.dmg
```
脚本的步骤：
1. 分别编译 arm64 和 `--triple x86_64-apple-macosx14.0`，再用 `lipo` 合成通用二进制。x86_64 编译失败时只打包 arm64。
2. 组装 .app，执行 `codesign --force --deep --sign -` 并验证签名。
3. 准备 DMG 内容：.app、`Applications` 软链接、中英文的《安装说明 · Install.txt》、`.VolumeIcon.icns`。
4. `hdiutil create -format UDZO`。

别人第一次打开时会看到"无法验证开发者"。处理方法：右键 → 打开；或者在系统设置里点"仍要打开"；或者执行 `xattr -dr com.apple.quarantine /Applications/ServerIsland.app`。

注意：make_dmg 会重建 `build/ServerIsland.app`，正在运行的 App 需要重启。

## 方案 B（以后：正式签名 + 公证）

1. 加入 Apple Developer Program，申请 **Developer ID Application** 证书，装进钥匙串。
2. 执行一次：`xcrun notarytool store-credentials serverisland --apple-id … --team-id …`。
3. `SIGN_IDENTITY="Developer ID Application: … (TEAMID)" NOTARY_PROFILE=serverisland ./scripts/make_dmg.sh`。
   - 这样会使用 hardened runtime 和时间戳签名，然后提交公证，最后执行 stapler。
4. 自动更新已经自己实现了（见 `architecture.md` 的"自动更新"），不需要 Sparkle。有了 Developer ID 以后，更新时就不会再弹钥匙串的询问。

## 版本号

在 `Resources/Info.plist` 的 `CFBundleShortVersionString`（目前是 0.1.0）和 `CFBundleVersion`。DMG 的文件名会跟着变。

## Windows / Linux 版

```bash
cross/scripts/publish.sh                 # → build/ServerIsland-<版本>-win-x64.zip、-linux-x64.tar.gz
cross/scripts/publish.sh win-arm64       # 其它目标（win-arm64、linux-arm64……）
cross/scripts/build_mac_preview.sh --run # 在 Mac 上试用跨平台版（不是正式的 Mac 版）
```
版本号在 `cross/Directory.Build.props` 的 `<Version>`，**发布时和 Info.plist 一起改**。推送到 GitHub 后，`.github/workflows/cross.yml` 会在 Windows / Linux 机器上自检、走查界面并打包（Actions 页面的 Artifacts）。详见 `references/cross-platform.md`。

## git

- 远程：`git@github.com:zhyan0603/ServerIsland.git`（公开仓库）。`main` 是发布分支；**日常改动（两个版本）都在 `dev` 分支上做**，测好后合并进 `main`（2026-10-18 起，原来的 `avalonia` 分支改名为 `dev`）。
- **提交、推送都要等用户确认。** 提交信息结尾要带上 `Co-Authored-By` 行（见会话里的提示）。
- `.gitignore` 里忽略了：`.build/`、`build/`、`promo/node_modules/`、`promo/out/`、`cross/**/bin/`、`cross/**/obj/`、`references/private/`。
- 编译产物（DMG、zip、tar.gz）**不进 git**，发布时作为 GitHub Release 的附件上传。

## 发布新版本与"检查更新"

App 里的"检查更新"读 GitHub 的 `releases/latest`：发布时 **tag 写成 `v<版本号>`**（和 `Info.plist`、`cross/Directory.Build.props` 的版本一致），**不要勾"预发布"**（预发布不会被检查到），附件保持 `ServerIsland-<版本>.dmg`、`ServerIsland-<版本>-win-x64.zip`、`ServerIsland-<版本>-linux-x64.tar.gz` 这三个名字。正文里用 `- ` 开头的列表写主要变化，App 会取前 4 条显示。

**自动更新依赖这几点**（2026-10-19 起）：
- 附件必须直接上传到 Release（GitHub 会自动给每个附件算 SHA-256，App 用它核对下载的文件）；没有 digest 的附件不会自动安装，只提供下载。
- DMG 里的 App 的 `CFBundleShortVersionString` 必须和 tag 的版本号一致，否则 Mac 版会拒绝安装。
- Windows zip 里要有 `ServerIsland.exe`，Linux tar.gz 里要有 `ServerIsland`（`cross/scripts/publish.sh` 就是这样打包的）。
- 发布前可以用 `.build/debug/ServerIsland --test-update <临时目录> build/ServerIsland-<版本>.dmg <版本>` 检查一下 DMG 能不能通过 App 的核对。
