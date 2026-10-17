import Foundation

/// `--demo` 模式和预览图 / 官网截图用的假数据，不会连接任何服务器。
/// 场景是计算材料学的日常：Slurm 集群上跑 VASP / GPUMD / 数组扫描，工作站上跑 NEP、LAMMPS 和机器学习势训练。
/// 注意：这里的用户名、路径、主机名都是虚构的（用户名 demo），不要写进真实环境的信息。
enum DemoData {
    static func settings() -> AppSettings {
        var s = AppSettings()
        var a = HostConfig(alias: "hpc-login", displayName: L("HPC 集群", "HPC Cluster"), kind: .slurm)
        a.auth = .interactive
        let b = HostConfig(alias: "gpu-box", displayName: L("4090 工作站", "4090 Workstation"), kind: .direct)
        s.hosts = [a, b]
        return s
    }

    static let aliases: Set<String> = ["hpc-login", "gpu-box"]
    static func isDemoHost(_ h: HostConfig) -> Bool { aliases.contains(h.alias) }

    /// 演示用的工作目录前缀。
    static let home = "/home/demo/projects"

    static func snapshot(for host: HostConfig, tick: Int, previous: HostSnapshot) -> HostSnapshot {
        var s = HostSnapshot()
        s.health = .ok
        s.lastUpdate = Date()
        s.latency = 0.08 + Double(tick % 5) * 0.01
        let t = Double(tick)
        let wave = { (phase: Double) in (sin(t / 3 + phase) + 1) / 2 }

        func appJob(_ id: String, _ name: String, source: RemoteJob.Source, _ app: AppProgress) -> RemoteJob {
            var j = RemoteJob(id: id, name: name, state: .running, source: source)
            j.app = app; j.progress = app.fraction; j.eta = app.eta
            j.message = app.title + " · " + app.summary
            return j
        }

        switch host.kind {
        case .slurm:
            s.metrics = HostMetrics(cpuPercent: 18 + wave(0) * 12, load1: 6.2, cores: 64,
                                    memoryUsed: 92e9 + wave(1) * 8e9, memoryTotal: 256e9)

            // VASP 从头算分子动力学：NSW 已知，显示百分比
            var aimd = AppProgress(kind: .vasp, dir: home + "/Li3PS4/aimd-900K")
            aimd.vaspMode = .md; aimd.current = 1_240 + t; aimd.total = 5_000; aimd.hasTarget = true
            aimd.rate = 0.034; aimd.updatedAt = Date(); aimd.endMarker = false
            var md = appJob("8812044", "aimd_Li3PS4_900K", source: .slurm, aimd)
            md.elapsed = 36_420 + t * 2; md.limit = 48 * 3600; md.detail = "cn[012-013] · cpu"

            // VASP 结构优化：不知道总步数，只显示离子步
            var relaxApp = AppProgress(kind: .vasp, dir: home + "/LiCoO2/relax-hse")
            relaxApp.vaspMode = .relax; relaxApp.current = 17; relaxApp.hasTarget = false
            relaxApp.updatedAt = Date(); relaxApp.endMarker = false
            var relax = appJob("8812101", "relax_LiCoO2_hse", source: .slurm, relaxApp)
            relax.elapsed = 11_530 + t * 2; relax.limit = 24 * 3600; relax.detail = "cn027 · cpu"

            // GPUMD 热导率
            var kappa = AppProgress(kind: .gpumd, dir: home + "/graphene/kappa-300K")
            kappa.current = 1_240_000 + t * 3_000; kappa.total = 2_000_000; kappa.rate = 1_520; kappa.updatedAt = Date()
            kappa.neighbor = .init(radialActual: 48, radialMax: 120, angularActual: 21, angularMax: 60)
            var gpumd = appJob("8812230", "gpumd_kappa_300K", source: .slurm, kappa)
            gpumd.elapsed = 2_710 + t * 2; gpumd.limit = 12 * 3600; gpumd.detail = "gpu07 · gpu-v100"

            // 数组作业：40 个应变点的状态方程扫描
            var eos = RemoteJob(id: "8812300", name: "eos_scan", state: .running, source: .slurm)
            eos.arrayJobID = "8812300"
            var running: [RemoteJob] = []
            for k in 0..<6 {
                var e = RemoteJob(id: "8812300_\(16 + k)", name: "eos_scan", state: .running, source: .slurm)
                e.arrayJobID = "8812300"; e.arrayTask = "\(16 + k)"
                e.elapsed = Double(300 + k * 170) + t * 2; e.limit = 4 * 3600; e.detail = "cn0\(40 + k) · cpu"
                running.append(e)
            }
            eos.array = ArrayInfo(baseID: "8812300", running: running, pending: 18, done: 14, failed: 2, total: 40, accurate: true)
            eos.elapsed = running.compactMap(\.elapsed).max()
            eos.limit = 4 * 3600
            eos.detail = L("运行 6 · 排队 18 · 失败 2", "6 running · 18 pending · 2 failed")

            var phonon = RemoteJob(id: "8812355", name: "phonon_Si_444", state: .pending, source: .slurm)
            phonon.limit = 12 * 3600; phonon.detail = "(Priority) · cpu"; phonon.reason = "Priority"
            var band = RemoteJob(id: "8812356", name: "band_LiCoO2", state: .pending, source: .slurm)
            band.limit = 6 * 3600; band.detail = "(Dependency) · cpu"; band.reason = "Dependency"

            s.jobs = [md, relax, eos, gpumd, phonon, band]
        case .direct:
            s.metrics = HostMetrics(cpuPercent: 41 + wave(2) * 30, load1: 9.8, cores: 32,
                                    memoryUsed: 71e9 + wave(3) * 6e9, memoryTotal: 128e9)
            var gpus: [GPUStat] = []
            for i in 0..<4 {
                let idle = i == 3
                let util: Double = idle ? 0 : 70 + wave(Double(i)) * 29
                let mem: Double = idle ? 312 : 6_000 + wave(Double(i)) * 9_000
                gpus.append(GPUStat(index: i, name: "RTX 4090", utilization: util, memoryUsedMB: mem,
                                    memoryTotalMB: 24_564, temperature: 64))
            }
            s.gpus = gpus

            // NEP 训练（GPUMD 套件）
            var nepApp = AppProgress(kind: .nep, dir: home + "/Li3PS4/nep-train")
            nepApp.current = 7_800 + t * 20; nepApp.total = 20_000; nepApp.rate = 26.4; nepApp.updatedAt = Date()
            nepApp.losses = [.init(label: "Total", value: 0.1815), .init(label: "L1", value: 0.045), .init(label: "L2", value: 0.064),
                             .init(label: "Energy", value: 0.00074), .init(label: "Force", value: 0.07098), .init(label: "Virial", value: 0.01131)]
            var nep = appJob("41022", "nep", source: .process, nepApp)
            nep.elapsed = 5_420 + t * 2; nep.gpuMemoryMB = 2_600

            // LAMMPS 高熵合金 NPT
            var lmpApp = AppProgress(kind: .lammps, dir: home + "/HEA/npt-1200K")
            lmpApp.current = 380_000 + t * 2_000; lmpApp.total = 1_000_000; lmpApp.rate = 830; lmpApp.updatedAt = Date()
            lmpApp.endMarker = false
            var lmp = appJob("41377", "lmp", source: .process, lmpApp)
            lmp.elapsed = 2_300 + t * 2; lmp.cpuPercent = 1_580

            // 自定义规则识别的机器学习势训练
            var mace = AppProgress(kind: .custom, dir: home + "/MACE/run-02")
            mace.customName = L("MACE 训练", "MACE training"); mace.customUnit = "epoch"
            mace.current = 37; mace.total = 200; mace.updatedAt = Date()
            var train = appJob("41856", "python train_mace.py", source: .process, mace)
            train.elapsed = 9_250 + t * 2; train.cpuPercent = 104; train.gpuMemoryMB = 14_800

            s.jobs = [nep, lmp, train]
        }
        return s
    }
}
