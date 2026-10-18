# 官网（`site/`）

纯静态页面，没有构建步骤、没有外部依赖，直接部署到 GitHub Pages。

## 文件

| 文件 | 内容 |
|---|---|
| `site/index.html` | 首页。中英文写在一起：`<span lang="zh">…</span><span lang="en">…</span>`，CSS 按 `html[data-lang]` 隐藏另一种。下载区是 macOS / Windows / Linux 三张卡片，都指向 Releases 最新版 |
| `site/manual.html` | 使用手册（上手指南）：三个平台的安装、第一次打开被拦、添加服务器、认识面板、详情与取消、提醒、登录方式与跳板机（含记住密码）、计算进度、Windows 与 Linux、常见问题、文件位置 |
| `site/features.html` | 功能详解（手册的子页面）：Slurm、直连与 GPU、计算软件识别和自定义规则、提醒、详情 / 日志 / 取消、每台服务器的设置、Tako、三个平台对比、设计原则 |
| `site/css/style.css` | 配色、圆角、卡片和 App / 宣传视频一致（`--mint #5BE6B5` 等）；900px、640px 两档窄屏 |
| `site/js/config.js` | **部署前只改这里**：版本号、GitHub 仓库地址 `repo`（GitHub / Issues / 下载按钮都由它生成）、可选的 DMG 直链 |
| `site/js/tako.js` | Tako 像素网格，和 `Pet.swift`、`promo/index.html` 同一张 |
| `site/js/main.js` | 三个页面共用：语言切换（子页面的标题写在 `<body data-title-zh / data-title-en>`）、手册目录滚动高亮（默认英文；`index.html` 开头的小脚本按系统首选语言选中文 / 英文，手动切换后记在 localStorage）、宣传视频按语言换中 / 英文版、GitHub Star 数、像素字组装动画、夜空星星、刘海演示状态机（收起 → 提示 → 收起 → 展开，鼠标悬停时一直展开）、滚动出现 |
| `site/assets/shots/{zh,en}/` | App 截图，由 `scripts/site_shots.sh` 生成；`cross-pet.png`（Windows / Linux 的桌宠模式）来自跨平台版的 `dotnet run -- --render-preview <目录> zh|en` 里的 `cross-pet.png` |
| `site/assets/promo[-en].mp4`、`promo-poster[-en].jpg` | 宣传视频的网页版（中 / 英文，1280 宽、CRF 27，约 4 MB） |
| `.github/workflows/pages.yml` | 推送到 main 且 `site/` 有变化时自动部署 |

## 常用操作

```bash
./scripts/site_shots.sh                 # 重新生成中英文截图（演示数据）
python3 -m http.server 8765 --directory site   # 本地预览（或用 .claude/launch.json 里的 "site"）
# 视频改动后：node promo/render.mjs，再压网页版
ffmpeg -i promo/out/ServerIsland-v0.1.mp4 -vf scale=1280:-2 -c:v libx264 -preset slow -crf 27 -pix_fmt yuv420p -c:a aac -b:a 128k -movflags +faststart site/assets/promo.mp4
```

## 部署到 GitHub Pages

项目开源，官网和源码在同一个公开仓库里：

1. 在 GitHub 建公开仓库并推送；
2. 仓库 Settings → Pages → Source 选 **GitHub Actions**；之后每次推送 `site/` 的改动都会自动发布到 `https://<用户名>.github.io/<仓库>/`；
3. `site/js/config.js` 里填 `repo`；
4. 发版：`./scripts/make_dmg.sh` 生成 DMG，`cross/scripts/publish.sh` 生成 Windows / Linux 包，在 GitHub 上建 Release 并上传。下载按钮默认打开 Releases 最新版页面。
   - 手册和 README 里写的文件名是 `ServerIsland-x.y.z.dmg`、`ServerIsland-x.y.z-win-x64.zip`、`ServerIsland-x.y.z-linux-x64.tar.gz`，上传时保持这个命名。
   - 手册和功能详解写的是用户能看到的行为；改了功能（尤其是设置项名称、默认值、文件位置）要同步改这两页和 README。

## 隐私守则（截图、视频、页面文字）

- 演示数据在 `Monitor/DemoData.swift`：用户名 `demo`，路径 `/home/demo/projects/...`，主机名"HPC 集群""4090 工作站"，作业号 88xxxxx，PID 41xxx。
- 宣传视频 `promo/index.html` 用同一套虚构信息。
- **不要写真实的用户名、主机别名、路径、分区名、作业号**。提交前可以用 `git grep` 检查一下自己的用户名和主机名。

## 访问量统计

三个页面的页脚都有不蒜子（busuanzi）的总访问量 / 访客数，写法参考 GPUMDkit 网站：`#busuanzi_container_site_pv/uv` 默认隐藏，脚本加载成功后才显示。本地预览时显示的是 localhost 的公共计数，不代表真实数据。

## 下载按钮（2026-10-18）

- 首页的下载按钮按访问者的系统推荐（`js/main.js` 的 `PLATFORMS` / `detectOS`）：Windows、Linux、macOS 各自显示"下载 X 版"；手机上默认 macOS，并在下载区提示"请在电脑上下载"，不标"推荐"。
- 按钮右侧 ▾ 打开全部平台的菜单（当前系统标"推荐"），按钮下面一行"其他平台：…"。下载区三张卡片里，访问者的系统那张加边框和"你的系统"。
- 文件地址：读 `api.github.com/repos/<repo>/releases/latest`，按后缀（`.dmg` / `-win-x64.zip` / `-linux-x64.tar.gz`）找附件的直接下载地址；某个平台没有附件或接口失败时打开 Release 页面。版本号也换成最新 Release 的。
- 调试：网址后面加 `?os=windows`、`?os=linux`、`?os=mac`、`?os=mobile`。
- 菜单要盖住下面的刘海演示：`.hero-inner` 的 `z-index` 必须高于 `.demo`。

## 缓存

三个页面引用 CSS / JS 时都带 `?v=日期`（例如 `style.css?v=20261018d`）。GitHub Pages 会缓存约 10 分钟，**改了 css / js 就把三个页面里的 `?v=` 一起改掉**，否则访问者可能拿到新 HTML 配旧脚本。
