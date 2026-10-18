using System.Globalization;

namespace ServerIsland.Core;

/// 界面语言。
public enum AppLanguage { System, Zh, En }

public static class Lang
{
    /// 由 ConfigStore 在启动和修改设置时更新。
    public static AppLanguage Setting = AppLanguage.System;

    public static bool IsEnglish => Setting switch
    {
        AppLanguage.Zh => false,
        AppLanguage.En => true,
        _ => !CultureInfo.CurrentUICulture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase),
    };

    /// 中英文成对写在调用处，避免遗漏或错配。用法：`using static ServerIsland.Core.Lang;` 后直接写 L("中文", "English")。
    public static string L(string zh, string en) => IsEnglish ? en : zh;

    public static string Label(this AppLanguage l) => l switch
    {
        AppLanguage.System => L("跟随系统", "Follow System"),
        AppLanguage.Zh => "中文",
        _ => "English",
    };
}
