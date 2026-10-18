using System.Diagnostics;
using System.Text.Json;
using ServerIsland.Core.Ssh;

namespace ServerIsland.Core;

/// 自检：认证方式、手动填写的服务器、跳板机（和 Mac 版 SelfTestConnection.swift 对应）。
/// 有系统 ssh（非 Windows）时，用真的 `ssh -G` 解析生成的私有配置，不联网。
public static class SelfTestConnection
{
    public static void Run(Action<bool, string> check)
    {
        // 旧配置兼容
        var h0 = JsonSerializer.Deserialize<HostConfig>("""{"alias":"lab","auth":"interactive"}""", Json.Options)!;
        check(h0.Auth == AuthMode.Interactive && !h0.IsManual && !h0.RememberPassword && h0.JumpHostID == null,
              "连接：旧配置 auth=interactive 读成“动态口令”，新字段取默认值");

        var jump = new HostConfig("bob@jump.example.org", "Jump") { HostName = "jump.example.org", User = "bob", Auth = AuthMode.Password };
        var lab = new HostConfig("alice@10.0.0.2", "Lab", HostKind.Slurm)
        {
            HostName = "10.0.0.2", User = "alice", Port = 2222, IdentityFile = "~/.ssh/id_lab", Auth = AuthMode.KeyPassword, JumpHostID = jump.Id,
        };
        var aliasHost = new HostConfig("si-selftest-cluster", "Cluster") { JumpHostID = lab.Id };

        var json = JsonSerializer.Serialize(lab, Json.Options);
        var back = JsonSerializer.Deserialize<HostConfig>(json, Json.Options)!;
        check(json.Contains("\"auth\": \"keyPassword\"") && json.Contains("\"jumpHostID\": \"" + jump.Id.ToString("D").ToUpperInvariant() + "\"")
              && back.Fingerprint() == lab.Fingerprint(), "连接：新字段往返编码，和 Mac 版字段名一致（keyPassword / jumpHostID）");

        // 跳板机链与防环
        var all = new List<HostConfig> { jump, lab, aliasHost };
        var byId = all.ToDictionary(x => x.Id);
        check(SshHosts.Chain(aliasHost, byId).Select(x => x.DisplayName).SequenceEqual(["Lab", "Jump"]), "连接：多级跳板机链 Cluster → Lab → Jump");
        var loopA = new HostConfig("a");
        var loopB = new HostConfig("b") { JumpHostID = loopA.Id };
        loopA.JumpHostID = loopB.Id;
        check(SshHosts.Chain(loopA, new Dictionary<Guid, HostConfig> { [loopA.Id] = loopA, [loopB.Id] = loopB }).Count == 1, "连接：跳板机成环时停下");
        check(!SshHosts.JumpCandidates(jump, all).Any(x => x.Id == lab.Id || x.Id == jump.Id), "连接：跳板机候选里没有自己和以自己为跳板的机器");

        // 私有 ssh 配置
        var dir = Path.Combine(Path.GetTempPath(), "si-selftest-" + Environment.ProcessId);
        Directory.CreateDirectory(dir);
        try
        {
            var path = Path.Combine(dir, "ssh_config");
            string Cp(HostConfig h) => SshHosts.NeedsPrivateConfig(h) ? "/tmp/serverisland-test/" + h.Id.ToString("N")[..8] + "-%C" : "/tmp/serverisland-test/%C";
            var text = SshHosts.Render(all, path, Cp);
            var labId = lab.Id.ToString("D").ToUpperInvariant();
            check(text.Contains($"Host si-{labId}\n  HostName 10.0.0.2\n  User alice\n  Port 2222\n  IdentityFile ~/.ssh/id_lab\n  IdentitiesOnly yes"),
                  "连接：手动服务器生成 Host 块");
            check(text.Contains("Host si-selftest-cluster\n  ProxyCommand"), "连接：别名服务器经跳板机只加 ProxyCommand，其它设置仍来自 ~/.ssh/config");
            check(text.EndsWith("Match all\nInclude ~/.ssh/config\nInclude /etc/ssh/ssh_config\n"), "连接：末尾包含用户和系统的 ssh 配置");
            check(text.Contains($"ControlPath='/tmp/serverisland-test/{jump.Id.ToString("N")[..8]}-%%C'") && text.Contains("-W '[%h]:%p'"),
                  "连接：ProxyCommand 复用跳板机自己的主连接（%%C 留给内层 ssh）");
            if (!OperatingSystem.IsWindows() && File.Exists("/usr/bin/ssh"))
            {
                File.WriteAllText(path, text);
                File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
                var g = SshG("-F", path, "si-" + labId);
                check(g.Contains("hostname 10.0.0.2") && g.Contains("port 2222") && g.Contains("user alice")
                      && g.Contains($"proxycommand env {SshHosts.AskPassHostIdEnv}={jump.Id.ToString("D").ToUpperInvariant()} /usr/bin/ssh"),
                      "连接：ssh -G 能解析生成的配置（地址、端口、用户、跳板）");
                var g2 = SshG("-F", path, "si-selftest-cluster");
                check(g2.Contains("si-" + labId) && g2.Contains($"{SshHosts.AskPassHostIdEnv}={labId}"), "连接：ssh -G 解析别名服务器的跳板机");
            }
        }
        finally { try { Directory.Delete(dir, true); } catch { } }

        // 提示语分类
        check(SshHosts.Kind("(alice@10.0.0.2) Password: ") == SshHosts.PromptKind.Password, "弹窗：键盘交互的 Password 提示");
        check(SshHosts.Kind("alice@10.0.0.2's password: ") == SshHosts.PromptKind.Password, "弹窗：OpenSSH 密码提示");
        check(SshHosts.Kind("Verification code: ") == SshHosts.PromptKind.OneTimeCode, "弹窗：动态口令提示");
        check(SshHosts.Kind("Enter passphrase for key '/home/x/.ssh/id_ed25519': ") == SshHosts.PromptKind.Passphrase, "弹窗：私钥口令提示");
        check(SshHosts.Kind("Are you sure you want to continue connecting (yes/no/[fingerprint])? ") == SshHosts.PromptKind.HostKey, "弹窗：主机指纹确认");
        check(AuthMode.KeyPassword.CanRemember() && AuthMode.Password.CanRemember() && !AuthMode.Interactive.CanRemember() && !AuthMode.Key.CanRemember(),
              "弹窗：只有密码类可以记住，动态口令不能");

        // 错误提示
        check(SshCommon.KeyFailureHint("alice@x: permission denied (password).").Contains("密钥 + 密码"), "错误：密钥通过但还要密码 → 建议“密钥 + 密码”");
        check(SshCommon.KeyFailureHint("alice@x: permission denied (publickey,password).").Contains("密码"), "错误：密钥被拒但服务器接受密码");
        check(SshCommon.KeyFailureHint("alice@x: permission denied (publickey).") == "密钥登录失败", "错误：只接受密钥");
        const string badPerm = "Permissions 0755 for '/home/alice/.ssh/id_demo' are too open.\nLoad key \"/home/alice/.ssh/id_demo\": bad permissions\nalice@x: Permission denied (publickey,password).";
        check(SshCommon.KeyPermissionHint(badPerm)?.Contains("id_demo") == true
              && SshCommon.KeyPermissionHint("alice@x: Permission denied (publickey).") == null
              && SshCommon.Classify(SshResult.Failure(badPerm), new HostConfig("x", "x"))?.Message == SshCommon.KeyPermissionHint(badPerm),
              "错误：私钥权限太宽 → 提示改权限");

        SshHosts.Update(all, write: false);
        var hopLogin = SshCommon.JumpProblem("bob@jump.example.org: Permission denied (publickey,password).\nConnection closed by UNKNOWN port 65535", aliasHost);
        check(hopLogin?.Kind == HealthKind.NeedsLogin && hopLogin.Message.Contains("第 2 级跳板机") && hopLogin.Message.Contains("Jump"), "错误：指明是哪一级跳板机要登录");
        var hopRoute = SshCommon.JumpProblem("channel 0: open failed: connect failed: No route to host\nstdio forwarding failed", lab);
        check(hopRoute?.Kind == HealthKind.Error && hopRoute.Message.Contains("Jump") && hopRoute.Message.Contains("连不上"), "错误：跳板机连不上目标");
        check(SshCommon.JumpProblem("Permission denied", jump) == null, "错误：没有跳板机时不误判");
        SshHosts.Update([], write: false);
    }

    static string SshG(params string[] args)
    {
        var psi = new ProcessStartInfo("/usr/bin/ssh") { RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true, UseShellExecute = false };
        psi.ArgumentList.Add("-G");
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)!;
        p.StandardInput.Close();
        var o = p.StandardOutput.ReadToEnd();
        p.WaitForExit(5000);
        return o;
    }
}
