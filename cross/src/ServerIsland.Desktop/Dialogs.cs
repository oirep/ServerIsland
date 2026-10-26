using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using ServerIsland.Core;
using ServerIsland.Core.Ssh;
using ServerIsland.Desktop.Ui;
using static ServerIsland.Core.Lang;

namespace ServerIsland.Desktop;

/// 登录对话框：密码 / 动态口令 / 密钥口令 / 确认主机指纹。密码默认不保存；
/// 显示"记住密码"时，勾选后由调用方存进系统凭据库（动态口令从不提供这个选项）。
public static class PromptDialog
{
    public static async Task<string?> Ask(string hostName, string prompt, bool secret) =>
        (await AskWithRemember(hostName, prompt, secret, null)).Value;

    /// remember 为 null：不显示"记住密码"；否则是勾选框的初始状态。
    public static Task<(string? Value, bool Remember)> AskWithRemember(string hostName, string prompt, bool secret, bool? remember)
    {
        var placeholder = SshHosts.Kind(prompt) switch
        {
            SshHosts.PromptKind.OneTimeCode => L("动态口令 / 验证码", "One-time code"),
            SshHosts.PromptKind.Passphrase => L("密钥口令", "Passphrase"),
            _ when prompt.Contains("口令") && prompt.Contains("密钥") => L("密钥口令", "Passphrase"),
            _ => secret ? L("密码", "Password") : "",
        };
        var box = new TextBox { Watermark = placeholder, MinWidth = 300, PasswordChar = secret ? '●' : '\0', RevealPassword = false };
        var check = remember == null ? null : new CheckBox
        {
            IsChecked = remember,
            Content = OperatingSystem.IsWindows() ? L("记住密码（存入 Windows 凭据管理器）", "Remember (in Windows Credential Manager)")
                                                  : L("记住密码（存入系统钥匙圈）", "Remember (in the system keyring)"),
        };
        Control input = check == null ? box : new StackPanel { Spacing = 8, Children = { box, check } };
        var tcs = new TaskCompletionSource<(string?, bool)>();
        bool Remembered() => check?.IsChecked == true;
        var w = Window(L($"登录 {hostName}", $"Log in to {hostName}"),
            (prompt.Length == 0 ? L("请输入密码", "Enter your password") : prompt)
            + (check != null
                ? L("\n\n只交给 SSH 用于登录；勾选“记住密码”时存进系统凭据库。", "\n\nPassed to SSH to log in; stored in the system credential store only if you tick “Remember”.")
                : L("\n\n只会交给 SSH 用于这一次登录，ServerIsland 不会保存。", "\n\nPassed to SSH for this login only; ServerIsland never stores it.")),
            input, L("登录", "Log In"), L("取消", "Cancel"), ok => tcs.TrySetResult(ok ? (box.Text ?? "", Remembered()) : (null, false)));
        box.KeyDown += (_, e) => { if (e.Key == Key.Enter) { tcs.TrySetResult((box.Text ?? "", Remembered())); w.Close(); } };
        w.Opened += (_, _) => Dispatcher.UIThread.Post(() => box.Focus(), DispatcherPriority.Input);
        w.Show();
        w.Activate();
        return tcs.Task;
    }

    public static Task<bool> Confirm(string title, string message, string ok, string cancel)
    {
        var tcs = new TaskCompletionSource<bool>();
        var w = Window(title, message, null, ok, cancel, r => tcs.TrySetResult(r));
        w.Show();
        w.Activate();
        return tcs.Task;
    }

    /// 三个按钮：first（默认）→ 0，second → 1，取消或关掉窗口 → -1。
    public static Task<int> Choose(string title, string message, string first, string second, string cancel, bool secondEnabled = true)
    {
        var tcs = new TaskCompletionSource<int>();
        Window? w = null;
        var extra = new Button { Content = second, MinWidth = 88, IsEnabled = secondEnabled, HorizontalContentAlignment = HorizontalAlignment.Center };
        extra.Click += (_, _) => { tcs.TrySetResult(1); w?.Close(); };
        w = Window(title, message, null, first, cancel, r => tcs.TrySetResult(r ? 0 : -1), extra);
        w.Show();
        w.Activate();
        return tcs.Task;
    }

    static Window Window(string title, string message, Control? input, string okText, string cancelText, Action<bool> done, Button? extra = null)
    {
        var w = new Window
        {
            Title = title,
            Width = 440,
            SizeToContent = SizeToContent.Height,
            CanResize = false,
            Topmost = true,
            WindowStartupLocation = WindowStartupLocation.CenterScreen,
            Icon = App.WindowIcon,
        };
        bool answered = false;
        void Finish(bool r)
        {
            if (answered) return;
            answered = true;
            done(r);
            w.Close();
        }
        var ok = new Button { Content = okText, IsDefault = true, Classes = { "accent" }, MinWidth = 88, HorizontalContentAlignment = HorizontalAlignment.Center };
        var cancel = new Button { Content = cancelText, IsCancel = true, MinWidth = 88, HorizontalContentAlignment = HorizontalAlignment.Center };
        ok.Click += (_, _) => Finish(true);
        cancel.Click += (_, _) => Finish(false);
        w.Closed += (_, _) => { if (!answered) { answered = true; done(false); } };

        var pet = new Border
        {
            Width = 56, Height = 56, CornerRadius = new CornerRadius(14), Background = Brushes.Black,
            Child = new PetView(PetMood.Waiting, 32) { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
            VerticalAlignment = VerticalAlignment.Top,
        };
        var texts = new StackPanel { Spacing = 8 };
        texts.Children.Add(new TextBlock { Text = title, FontSize = 16, FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap });
        texts.Children.Add(new SelectableTextBlock { Text = message, TextWrapping = TextWrapping.Wrap, Opacity = 0.8, FontSize = 12.5 });
        if (input != null) texts.Children.Add(input);
        var top = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(pet, Dock.Left);
        pet.Margin = new Thickness(0, 0, 16, 0);
        top.Children.Add(pet);
        top.Children.Add(texts);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 18, 0, 0) };
        buttons.Children.Add(cancel);
        if (extra != null) buttons.Children.Add(extra);
        buttons.Children.Add(ok);
        w.Content = new StackPanel { Margin = new Thickness(22), Children = { top, buttons } };
        return w;
    }
}

/// 界面实现的登录提示（SSH 库在后台线程上调用，这里切到界面线程弹窗）。
public sealed class LoginPrompter : ILoginPrompter
{
    public Task<string?> AskAsync(string hostName, string prompt, bool secret) =>
        Dispatcher.UIThread.InvokeAsync(() => PromptDialog.Ask(hostName, prompt, secret));

    public Task<bool> ConfirmHostKeyAsync(string hostName, string message) =>
        Dispatcher.UIThread.InvokeAsync(() => PromptDialog.Confirm(L($"第一次连接 {hostName}", $"First connection to {hostName}"), message,
            L("信任并继续", "Trust & Continue"), L("取消", "Cancel")));

    public Task<(string? Value, bool Remember)> AskPasswordAsync(string hostName, string prompt, bool rememberDefault) =>
        Dispatcher.UIThread.InvokeAsync(() => PromptDialog.AskWithRemember(hostName, prompt, true,
            CredentialStore.Available ? rememberDefault : null));
}

/// Linux 上用系统 ssh 登录时，ssh 以 SSH_ASKPASS 的身份启动本程序：弹窗，把输入写到 stdout。
/// 经跳板机时每一跳的 ssh 都带着自己的 SERVERISLAND_ASKPASS_HOSTID，弹窗写明是哪台机器；
/// 记住了密码的机器先用凭据库里的密码（同一次登录里再被问到就说明它不对了，改为弹窗）。
public static class AskPassApp
{
    public static int Run(string[] args)
    {
        var prompt = string.Join(" ", args).Trim();
        var settings = LoadSettings();
        Lang.Setting = settings?.Language ?? Lang.Setting;
        var hostCfg = Guid.TryParse(Environment.GetEnvironmentVariable(SshHosts.AskPassHostIdEnv), out var hid)
            ? settings?.Hosts.FirstOrDefault(h => h.Id == hid) : null;
        var host = hostCfg?.DisplayName ?? Environment.GetEnvironmentVariable(OpenSshTransport.AskPassHost) ?? L("服务器", "server");
        var session = Environment.GetEnvironmentVariable(OpenSshTransport.AskPassSession);
        bool silent = Environment.GetEnvironmentVariable(OpenSshTransport.AskPassSilent) == "1";
        var kind = SshHosts.Kind(prompt);
        bool canRemember = kind == SshHosts.PromptKind.Password && hostCfg?.Auth.CanRemember() == true && CredentialStore.Available;

        bool rejectedSaved = false;
        if (canRemember && session != null)
        {
            var used = Path.Combine(session, "used-" + hostCfg!.Id.ToString("D").ToUpperInvariant());
            if (File.Exists(used)) rejectedSaved = true;
            else if (CredentialStore.Get(hostCfg.Id) is { } saved)
            {
                try { File.WriteAllText(used, ""); } catch { }
                Console.WriteLine(saved);
                return 0;
            }
        }
        if (silent) return 1;

        App.AskPassMode = true;
        Program.BuildAvaloniaApp().SetupWithoutStarting();
        string? result = null;
        bool ok = false, remember = false;
        var cts = new CancellationTokenSource();
        Dispatcher.UIThread.Post(async () =>
        {
            if (kind == SshHosts.PromptKind.HostKey)
            {
                ok = await PromptDialog.Confirm(L($"第一次连接 {host}", $"First connection to {host}"),
                    prompt + L("\n\n确认这是你的服务器后再继续。", "\n\nContinue only if this is your server."), L("信任并继续", "Trust & Continue"), L("取消", "Cancel"));
                result = ok ? "yes" : null;
            }
            else
            {
                var text = (rejectedSaved ? L("记住的密码没有通过，请重新输入。\n\n", "The saved password was rejected. Please enter it again.\n\n") : "") + prompt;
                (result, remember) = await PromptDialog.AskWithRemember(host, text, kind != SshHosts.PromptKind.Username,
                                                                        canRemember ? hostCfg!.RememberPassword : null);
                ok = result != null;
            }
            cts.Cancel();
        });
        Dispatcher.UIThread.MainLoop(cts.Token);
        if (!ok || result == null) return 1;
        if (canRemember)
        {
            var id = hostCfg!.Id;
            if (remember) CredentialStore.Save(id, result, hostCfg.DisplayName);
            else CredentialStore.Delete(id);
            if (session != null)
            {
                var name = id.ToString("D").ToUpperInvariant();
                // 刚输入的这次也算"用过"：若仍被拒，下次会重新弹窗而不是反复填错的密码。
                try
                {
                    if (remember) File.WriteAllText(Path.Combine(session, "used-" + name), "");
                    File.WriteAllText(Path.Combine(session, "remember-" + name), remember ? "1" : "0");
                }
                catch { }
            }
        }
        Console.WriteLine(result);
        return 0;
    }

    static AppSettings? LoadSettings()
    {
        try { return System.Text.Json.JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(AppPaths.ConfigFile), Json.Options); }
        catch { return null; }
    }
}
