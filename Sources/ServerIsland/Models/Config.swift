import Foundation

/// 服务器类型：决定"任务"从哪里来。
enum HostKind: String, Codable, CaseIterable, Identifiable {
    case slurm
    case direct

    var id: String { rawValue }
    var label: String { self == .slurm ? L("Slurm 集群", "Slurm cluster") : L("直连服务器", "Direct server") }
    var badge: String { self == .slurm ? "SLURM" : "DIRECT" }
}

/// 认证方式。App 从不保存密码：需要密码 / 二次验证的机器，先在终端里登录一次，
/// App 复用这条 SSH 主连接（ControlMaster）进行后续查询。
enum AuthMode: String, Codable, CaseIterable, Identifiable {
    case key
    case interactive

    var id: String { rawValue }
    var label: String { self == .key ? L("密钥 / ssh-agent", "SSH key / agent") : L("密码 / 动态口令", "Password / OTP") }
}

/// 需要密码登录的机器，主连接保持多久（期间不用再输密码）。
enum KeepAlive: String, Codable, CaseIterable, Identifiable {
    case h8, h24, d3, forever

    var id: String { rawValue }
    var label: String {
        switch self {
        case .h8: return L("8 小时", "8 hours")
        case .h24: return L("24 小时", "24 hours")
        case .d3: return L("3 天", "3 days")
        case .forever: return L("一直保持", "Until disconnected")
        }
    }
    var controlPersist: String {
        switch self {
        case .h8: return "8h"
        case .h24: return "24h"
        case .d3: return "72h"
        case .forever: return "yes"
        }
    }
}

/// 收起状态下刘海两侧"小翅膀"的显示策略。
enum CollapsedStyle: String, Codable, CaseIterable, Identifiable {
    case auto
    case always
    case never

    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return L("有任务或异常时显示", "When busy or failing")
        case .always: return L("始终显示", "Always")
        case .never: return L("从不显示", "Never")
        }
    }
}

/// 远程执行的命令。默认值适用于大多数 Linux / Slurm 环境，
/// 对不上时可以在设置里逐项修改。
struct CommandSet: Codable, Equatable {
    /// 远端读取脚本的 shell，脚本通过 stdin 传入。用 login shell 以便加载 module / PATH。
    var shell = "bash -l -s"
    /// 在所有命令之前执行，例如 `module load slurm` 或 `export PATH=/opt/slurm/bin:$PATH`。
    var preamble = ""
    var squeue = #"squeue -u "$(id -un)" -h -o '%i|%j|%T|%M|%l|%D|%R|%P|%F|%K'"#
    /// `{jobs}` 会被替换为逗号分隔的作业号。只在作业从队列消失时调用一次。
    var sacct = "sacct -n -X -P -o JobID,JobName,State,Elapsed,ExitCode -j {jobs}"
    var gpu = "nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits"
    var gpuApps = "nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits"
    var processes = #"ps -u "$(id -un)" -o pid=,etimes=,pcpu=,rss=,args= --sort=-pcpu | head -n 300"#
    var progressGlob = "~/.serverisland/progress/*.json"
    /// 磁盘占用：df -P 输出。路径以空格分隔，默认看 home 所在分区。
    var disk = "df -P -k ~"

    static let defaults = CommandSet()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CommandSet.defaults
        shell = try c.decodeIfPresent(String.self, forKey: .shell) ?? d.shell
        preamble = try c.decodeIfPresent(String.self, forKey: .preamble) ?? d.preamble
        squeue = try c.decodeIfPresent(String.self, forKey: .squeue) ?? d.squeue
        // 旧版默认命令没有数组列（%F|%K），自动升级。
        if squeue == #"squeue -u "$(id -un)" -h -o '%i|%j|%T|%M|%l|%D|%R|%P'"# { squeue = d.squeue }
        sacct = try c.decodeIfPresent(String.self, forKey: .sacct) ?? d.sacct
        gpu = try c.decodeIfPresent(String.self, forKey: .gpu) ?? d.gpu
        gpuApps = try c.decodeIfPresent(String.self, forKey: .gpuApps) ?? d.gpuApps
        processes = try c.decodeIfPresent(String.self, forKey: .processes) ?? d.processes
        progressGlob = try c.decodeIfPresent(String.self, forKey: .progressGlob) ?? d.progressGlob
        disk = try c.decodeIfPresent(String.self, forKey: .disk) ?? d.disk
    }
}

struct HostConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    /// `~/.ssh/config` 里的 Host 别名，或任意 `ssh` 能识别的目标（如 user@1.2.3.4）。
    var alias: String
    var displayName: String
    var kind: HostKind = .direct
    var auth: AuthMode = .key
    var enabled = true
    /// nil 表示跟随全局轮询间隔。
    var interval: Int?
    var showCPU = true
    var showMemory = true
    var showGPU = true
    var watchJobs = true
    var readProgressFiles = true
    /// 直连服务器：只显示命令行匹配该正则的进程。
    var processFilter = #"python|torchrun|accelerate|deepspeed|julia|matlab|Rscript|java|node|\./"#
    /// 直连服务器：命令行匹配该正则的进程一律忽略（系统服务、桌面、编辑器后台等）。
    var processExclude = HostConfig.defaultExclude

    static let defaultExclude = #"/usr/(lib|libexec|share)/|^/snap/|^/usr/sbin/|gnome-|Xorg|xdg-|ibus|gsd-|gvfs|update-manager|check-new-release|unattended-upgr|networkd-dispatcher|vscode-server|cursor-server|windsurf-server|\.codex/|codex app-server|jupyter-lab|ipykernel_launcher|pylsp|pyright|ruff|wireplumber|pipewire|dbus-daemon|update-notifier|systemd|at-spi|gcr-ssh|gnome-keyring|FlClash|clash"#
    /// 使用 App 管理的 SSH 连接复用（强烈建议开启，轮询几乎零开销）。
    var reuseConnection = true
    var commands = CommandSet()
    /// 静音：不弹提示、不发通知、不响铃（数据照常更新）。
    var muted = false
    /// 允许在刘海里取消这台机器上的任务（默认关闭，避免误操作）。
    var allowCancel = false
    /// 手动监听的进程（直连服务器）：不受过滤规则影响，结束时一定提醒。
    var watched: [WatchedProcess] = []
    var showDisk = true
    var keepAlive: KeepAlive = .h24
    /// 暂停自动刷新（仍然显示在刘海里，可以手动刷新）。
    var paused = false
    /// 识别计算软件（NEP / GPUMD）的进度。
    var detectApps = true
    /// 按这些进程名（pgrep -x，正则）查找计算软件；占用 GPU 或 CPU 很高的进程也会检查。
    var appProcessNames = HostConfig.defaultAppProcessNames
    static let defaultAppProcessNames = "gpumd|nep|gnep|vasp_std|vasp_gam|vasp_ncl|lmp|lmp_mpi|lmp_serial"
    /// Slurm 机器上同时显示不经过 Slurm、直接运行的进程（单机 Slurm 工作站很常见）。
    var slurmAlsoProcesses = false
    /// 读取 ~/.bashrc 等文件里的 PATH 设置，补全非交互 shell 缺少的路径（如装在家目录下的 Slurm）。
    var importShellPath = true

    init(alias: String, displayName: String? = nil, kind: HostKind = .direct) {
        self.alias = alias
        self.displayName = displayName ?? alias
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let alias = try c.decode(String.self, forKey: .alias)
        self.init(alias: alias)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? alias
        kind = try c.decodeIfPresent(HostKind.self, forKey: .kind) ?? .direct
        auth = try c.decodeIfPresent(AuthMode.self, forKey: .auth) ?? .key
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        interval = try c.decodeIfPresent(Int.self, forKey: .interval)
        showCPU = try c.decodeIfPresent(Bool.self, forKey: .showCPU) ?? true
        showMemory = try c.decodeIfPresent(Bool.self, forKey: .showMemory) ?? true
        showGPU = try c.decodeIfPresent(Bool.self, forKey: .showGPU) ?? true
        watchJobs = try c.decodeIfPresent(Bool.self, forKey: .watchJobs) ?? true
        readProgressFiles = try c.decodeIfPresent(Bool.self, forKey: .readProgressFiles) ?? true
        processFilter = try c.decodeIfPresent(String.self, forKey: .processFilter) ?? processFilter
        processExclude = try c.decodeIfPresent(String.self, forKey: .processExclude) ?? processExclude
        reuseConnection = try c.decodeIfPresent(Bool.self, forKey: .reuseConnection) ?? true
        commands = try c.decodeIfPresent(CommandSet.self, forKey: .commands) ?? CommandSet()
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        allowCancel = try c.decodeIfPresent(Bool.self, forKey: .allowCancel) ?? false
        watched = try c.decodeIfPresent([WatchedProcess].self, forKey: .watched) ?? []
        showDisk = try c.decodeIfPresent(Bool.self, forKey: .showDisk) ?? true
        keepAlive = try c.decodeIfPresent(KeepAlive.self, forKey: .keepAlive) ?? .h24
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        detectApps = try c.decodeIfPresent(Bool.self, forKey: .detectApps) ?? true
        appProcessNames = try c.decodeIfPresent(String.self, forKey: .appProcessNames) ?? Self.defaultAppProcessNames
        // 旧版默认值自动升级（用户改过的保持不动）
        if appProcessNames == "gpumd|nep|gnep" { appProcessNames = Self.defaultAppProcessNames }
        slurmAlsoProcesses = try c.decodeIfPresent(Bool.self, forKey: .slurmAlsoProcesses) ?? false
        importShellPath = try c.decodeIfPresent(Bool.self, forKey: .importShellPath) ?? true
    }
}

struct WatchedProcess: Codable, Equatable, Identifiable {
    var pid: String
    var name: String
    /// 进程启动时刻（由 etimes 推算），用来识别 PID 被复用的情况。
    var startedAt: Date?

    var id: String { pid }
}

struct AppSettings: Codable, Equatable {
    var hosts: [HostConfig] = []
    var defaultInterval = 60
    /// false：所有机器都只手动刷新。
    var autoRefresh = true
    var collapsedStyle: CollapsedStyle = .always
    /// 展开面板里把空闲的机器合并成一行（全部空闲时照常显示卡片）。
    var foldIdleHosts = true
    /// 任务结束 / 开始时刘海弹出提示。
    var islandAlerts = true
    /// 同时发送系统通知。
    var systemNotifications = true
    /// 提示音（成功 / 失败不同的声音）。
    var soundEnabled = true
    var soundVolume = 0.6
    /// 数组作业第一次出现失败元素时立即提醒一次。
    var arrayFirstFailureAlert = true
    /// 磁盘占用超过该比例时提醒。
    var diskWarnThreshold = 0.9
    var language: AppLanguage = .system
    /// 自定义进度识别规则（所有服务器通用）。
    var progressRules: [ProgressRule] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hosts = try c.decodeIfPresent([HostConfig].self, forKey: .hosts) ?? []
        defaultInterval = try c.decodeIfPresent(Int.self, forKey: .defaultInterval) ?? 60
        autoRefresh = try c.decodeIfPresent(Bool.self, forKey: .autoRefresh) ?? true
        collapsedStyle = try c.decodeIfPresent(CollapsedStyle.self, forKey: .collapsedStyle) ?? .always
        foldIdleHosts = try c.decodeIfPresent(Bool.self, forKey: .foldIdleHosts) ?? true
        islandAlerts = try c.decodeIfPresent(Bool.self, forKey: .islandAlerts) ?? true
        systemNotifications = try c.decodeIfPresent(Bool.self, forKey: .systemNotifications) ?? true
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
        soundVolume = try c.decodeIfPresent(Double.self, forKey: .soundVolume) ?? 0.6
        diskWarnThreshold = try c.decodeIfPresent(Double.self, forKey: .diskWarnThreshold) ?? 0.9
        arrayFirstFailureAlert = try c.decodeIfPresent(Bool.self, forKey: .arrayFirstFailureAlert) ?? true
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        progressRules = try c.decodeIfPresent([ProgressRule].self, forKey: .progressRules) ?? []
    }
}

/// 读写 `~/Library/Application Support/ServerIsland/config.json`。
@MainActor
final class ConfigStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            Lang.setting = settings.language
            ProgressRule.active = settings.progressRules
            if settings != oldValue { scheduleSave() }
        }
    }

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ServerIsland", isDirectory: true)
    }()
    static let fileURL = directory.appendingPathComponent("config.json")

    private var saveWork: DispatchWorkItem?
    private let persist: Bool

    init(persist: Bool = true) {
        self.persist = persist
        if persist,
           let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
        Lang.setting = settings.language
        ProgressRule.active = settings.progressRules
    }

    func host(_ id: UUID) -> HostConfig? {
        settings.hosts.first { $0.id == id }
    }

    func interval(for host: HostConfig) -> Int {
        max(10, host.interval ?? settings.defaultInterval)
    }

    private func scheduleSave() {
        guard persist else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        guard persist else { return }
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(settings).write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("ServerIsland: failed to save config: \(error)")
        }
    }
}
