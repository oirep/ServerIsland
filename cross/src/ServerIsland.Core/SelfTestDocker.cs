using System.Text.Json;

namespace ServerIsland.Core;

/// 核心协议与速率计算的假数据自检，不连接 Docker 或真实 SSH。
public static class SelfTestDocker
{
    public static void Run(Action<bool, string> check)
    {
        var host = new HostConfig("demo-docker");
        check(!host.ShowDocker && !RemoteScript.Build(host).Contains("SEC docker"), "Docker：默认关闭，不访问 socket");
        host.ShowDocker = true;
        check(Json.Clone(host).ShowDocker && RemoteScript.Build(host).Contains(DockerMonitor.Source), "Docker：开关持久保存，同轮询嵌入共享采集器");
        host.DockerView = DockerViewMode.Grid; host.DockerAllView = DockerViewMode.List;
        var independent = Json.Clone(host);
        check(independent.DockerView == DockerViewMode.Grid && independent.DockerAllView == DockerViewMode.List,
            "Docker 展示：首页与全部布局可独立持久保存");
        var oldGrid = JsonSerializer.Deserialize<HostConfig>("""{"alias":"demo-docker","dockerView":"grid"}""", Json.Options);
        check(oldGrid?.DockerAllView == DockerViewMode.Grid, "Docker 展示：旧版共用 Grid 配置保留原显示");
        string[] Sample(double time, double rx) => [JsonSerializer.Serialize(new DockerSnapshot
        {
            Total = 1, Running = 1,
            Containers = [new DockerContainer { Id = new string('a', 64), Name = "demo-web", State = "running", CpuPercent = 250, OnlineCPUs = 4, CpuLimitCores = 4, LimitsRead = true, MemoryUsed = 512, MemoryLimit = 1024, NetworkRx = rx, SampledAt = time }],
        }, Json.Options)];
        var first = DockerSnapshot.Parse(Sample(100, 1000));
        var next = DockerSnapshot.Parse(Sample(110, 1500), first);
        check(first.Containers[0].RxRate == null && next.Containers[0].RxRate == 50, "Docker：首次速率未知，后续按真实时间差计算");
        check(first.Containers[0].CpuFraction == 0.625 && first.Containers[0].MemoryFraction == 0.5, "Docker：多核 CPU 与内存条按容量归一化");
        var quota = new DockerContainer { CpuPercent = 107.3, OnlineCPUs = 64 };
        check(quota.CpuUsagePercent == 107.3 && quota.CpuFraction == 1, "Docker：未限额 CPU 单核口径不受主机核心数稀释");
        quota.CpuLimitCores = 2;
        check(Math.Abs(quota.CpuUsagePercent!.Value - 53.65) < 1e-9 && Math.Abs(quota.CpuFraction!.Value - 0.5365) < 1e-9,
            "Docker：2 核限额下文字和资源条都显示 53.65%");
        quota.MemoryUsed = 512; quota.MemoryLimit = 4096; quota.MemoryConfiguredLimit = 1024;
        check(quota.MemoryFraction == 0.5, "Docker：内存按容器限额而不是主机总量计算");
        check(DockerSnapshot.Parse(Sample(120, 1), next).Containers[0].RxRate == null, "Docker：计数器回退不伪造速率");
        check(DockerSnapshot.Parse(["bash: python3: command not found"]).Error == "python_missing", "Docker：缺少 Python 时显示独立错误");
    }
}
