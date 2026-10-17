# Contributing / 参与贡献

Thanks for your interest! Issues and pull requests are welcome in English or Chinese.
欢迎用中文或英文提 Issue 和 Pull Request。

## Good first contributions / 适合上手的方向

- **A detector for another simulation package** (CP2K, Quantum ESPRESSO, ABACUS, Gaussian, ORCA, DeePMD …). Follow "新增一种软件" in [`references/remote-protocol.md`](references/remote-protocol.md): add a branch to the remote script, parse it in Swift, and add a self-test with sample output.
  **新增一种计算软件的识别**：按 `references/remote-protocol.md` 里"新增一种软件"一节来做，并加一条自检。
- Other schedulers (PBS / Torque, LSF), more pending-reason translations, UI polish.
  其他调度系统、更多排队原因翻译、界面改进。

## Development / 开发

Only the Xcode Command Line Tools are required (macOS 14+, Swift 5.10):

```bash
swift build && .build/debug/ServerIsland --selftest          # all self-tests must pass
.build/debug/ServerIsland --render-preview ./preview en      # look at every UI state after UI changes
open build/ServerIsland.app --args --demo                    # demo mode, no servers needed
```

Read [`AGENTS.md`](AGENTS.md) first (in Chinese) — it lists the project layout and the rules learned the hard way. A few that matter most:

1. **Detection must be read-only and conservative.** Only read file tails / small files; if anything doesn't match what you expect, report nothing rather than a wrong number.
   识别只读文件末尾或小文件；对不上就不显示，不要给出错误的进度。
2. **Never commit real usernames, hostnames, paths or partition names** — in code, docs, screenshots or the website. Demo data lives in `Sources/ServerIsland/Monitor/DemoData.swift`.
   代码、文档、截图里不要出现真实的用户名、主机名、路径、分区名。
3. **UI strings are bilingual**: `L("中文", "English")`. Strings matched against server output must not be translated.
   界面文案用 `L(中文, English)`；用来匹配服务器输出的字符串不能翻译。
4. After UI changes, render previews (`--render-preview`) and include a screenshot in the PR.
   改了界面请渲染预览图，并在 PR 里附上截图。

## License of contributions / 贡献的许可

ServerIsland is licensed under the [GPL-3.0](LICENSE). By submitting a pull request you agree that your contribution is licensed under the same terms.
ServerIsland 使用 GPL-3.0 许可证。提交 Pull Request 即表示你同意你的贡献也按 GPL-3.0 发布。

## Reporting bugs / 报告问题

Please include your macOS version, the server type (Slurm / direct) and, if possible, the output of
`/Applications/ServerIsland.app/Contents/MacOS/ServerIsland --diagnose <ssh-alias> slurm+` (**remove hostnames, usernames and paths before posting**) and the relevant part of `~/Library/Logs/ServerIsland/serverisland.log`.

请附上 macOS 版本、服务器类型，以及 `--diagnose` 的输出和日志相关部分（**贴出来之前删掉主机名、用户名和路径**）。

Questions that don't fit an issue: yanzihan@westlake.edu.cn
不适合发 Issue 的问题可以发邮件：yanzihan@westlake.edu.cn
