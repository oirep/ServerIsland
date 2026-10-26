using Avalonia;
using Avalonia.Controls;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using Avalonia.VisualTree;
using ServerIsland.Core;
using ServerIsland.Desktop.Island;

namespace ServerIsland.Desktop.Preview;

/// `--ui-smoke <目录>`：在真实窗口系统上用演示数据把界面走一遍（展开、详情页、弹窗、收起、桌宠模式、设置窗口），
/// 每一步把窗口内容存成 PNG，并记录有没有异常。用于在 Windows / Linux 真机上快速自查，不需要人去点。
public static class UiSmoke
{
    public static string? Directory;
    static int _step;
    static int _dockedY;
    public static readonly List<string> Errors = [];

    public static void Run(App app, MonitorEngine engine, ConfigStore store, IslandWindow island)
    {
        if (Directory == null) return;
        System.IO.Directory.CreateDirectory(Directory);
        var steps = new List<(double Delay, string Name, Action Act, Func<Window?> Capture)>
        {
            (2.5, "1-collapsed", () => { }, () => { _dockedY = island.Position.Y; return island; }),
            (0.2, "2-expanded", () => { island.State.Pinned = true; island.SetHovering(true); }, () => island),
            (0.2, "3-job-detail", () =>
            {
                var host = store.Settings.Hosts[1];
                var job = engine.Snapshots[host.Id].Jobs[0];
                island.State.PinnedJob = job;
                island.State.Page = new IslandPage(PageKind.Job, host.Id, job.Id);
            }, () => island),
            (0.2, "4-all-jobs", () => island.State.OpenAllJobs(), () => island),
            (0.2, "4b-all-jobs-starred", () =>
            {
                // 关注一个任务，再只看关注的任务
                var host = store.Settings.Hosts[0];
                var job = engine.Snapshots[host.Id].Jobs.Last(j => j.ArrayJobID == null || j.Array != null);
                if (!engine.IsStarred(host.Id, job.Id)) engine.ToggleStar(host.Id, job);
                island.State.Jobs = island.State.Jobs with { StarredOnly = true };
                island.State.RequestRebuild();
            }, () =>
            {
                if (!store.Settings.StarredJobs.Any()) Errors.Add("4b-all-jobs-starred: star was not saved");
                return island;
            }),
            (0.2, "5-toast", () =>
            {
                island.State.Pinned = false;
                island.SetHovering(false);
                engine.Emit(new IslandEvent(EventKind.Failed, "eval_mmlu 失败", "OUT_OF_MEMORY · 用时 0:42:18", store.Settings.Hosts[0].DisplayName, store.Settings.Hosts[0].Id));
            }, () => island),
            (0.2, "6-pet", () => { engine.DismissEvent(); app.SetDisplayMode(DisplayMode.Pet); }, () => app.PetWindow),
            (0.2, "7-pet-panel", () => { island.State.Pinned = true; island.SetPetHover(true); }, () =>
            {
                Console.WriteLine($"   pet panel opens {(island.ShapeAtTop ? "downward" : "upward")}");
                return island;
            }),
            (0.2, "8-back-to-island", () =>
            {
                island.State.Pinned = false;
                island.SetPetHover(false);
                app.SetDisplayMode(DisplayMode.Island);
            }, () =>
            {
                if (!island.ShapeAtTop) Errors.Add("8-back-to-island: island is not at the top of its window");
                if (Math.Abs(island.Position.Y - _dockedY) > 2)
                    Errors.Add($"8-back-to-island: window y={island.Position.Y}, was {_dockedY} before pet mode");
                return island;
            }),
            (0.2, "9-settings", () => app.ShowSettings(), () => app.Settings),
        };
        _step = 0;
        void Next()
        {
            if (_step >= steps.Count)
            {
                var report = Path.Combine(Directory!, "result.txt");
                File.WriteAllText(report, Errors.Count == 0 ? "OK\n" : string.Join("\n", Errors));
                Console.WriteLine(Errors.Count == 0 ? "UI smoke: OK" : "UI smoke: " + Errors.Count + " error(s)");
                app.Quit();
                return;
            }
            var (delay, name, act, capture) = steps[_step++];
            DispatcherTimer.RunOnce(() =>
            {
                try { act(); }
                catch (Exception e) { Errors.Add($"{name}: {e}"); }
                // 等动画结束再截图
                DispatcherTimer.RunOnce(() =>
                {
                    try { Snapshot(capture(), name); }
                    catch (Exception e) { Errors.Add($"{name} snapshot: {e.Message}"); }
                    Next();
                }, TimeSpan.FromSeconds(1.2));
            }, TimeSpan.FromSeconds(delay));
        }
        Next();
    }

    static void Snapshot(Window? w, string name)
    {
        if (w?.Content is not Control c || c.Bounds.Width < 1) { Errors.Add($"{name}: window not visible"); return; }
        var scale = w.RenderScaling;
        var size = new PixelSize((int)Math.Ceiling(c.Bounds.Width * scale), (int)Math.Ceiling(c.Bounds.Height * scale));
        using var bmp = new RenderTargetBitmap(size, new Vector(96 * scale, 96 * scale));
        bmp.Render(c);
        bmp.Save(Path.Combine(Directory!, name + ".png"));
        if (Environment.GetEnvironmentVariable("SI_DUMP_TEXT") == "1")
        {
            var all = c.GetVisualDescendants().OfType<TextBlock>().ToList();
            Console.WriteLine($"   {all.Count} text blocks; island content = {(c as Panel)?.Children.Count}");
            foreach (var t in all.Where(t => (t.Text ?? "").Contains("ancel") || (t.Text ?? "").Contains("Settings")))
            {
                Console.WriteLine($"   text '{t.Text}' bounds={t.Bounds} desired={t.DesiredSize} visible={t.IsEffectivelyVisible}");
                if (t.Parent is Panel pp)
                {
                    Console.WriteLine($"     parent {pp.GetType().Name} bounds={pp.Bounds} desired={pp.DesiredSize}");
                    foreach (var ch in pp.Children) Console.WriteLine($"     child {ch.GetType().Name} bounds={ch.Bounds} desired={ch.DesiredSize}");
                    if (pp.Parent is Control g) Console.WriteLine($"     grand {g.GetType().Name} bounds={g.Bounds} desired={g.DesiredSize}");
                }
            }
        }
        Console.WriteLine("✓ " + name);
    }
}
