import Foundation

/// 把 Slurm 的排队原因翻译成能看懂的话。
/// `needsAction` 为 true 表示一直等下去也不会开始，需要用户处理。
struct PendingReason: Equatable {
    var short: String
    var long: String
    var needsAction: Bool

    private struct Entry {
        var key: String
        var short: (String, String)
        var long: (String, String)
        var act: Bool
    }

    // 前缀匹配，顺序从具体到笼统。(中文, English)
    private static let table: [Entry] = [
        .init(key: "DependencyNeverSatisfied", short: ("依赖永远无法满足", "Dependency never satisfied"),
              long: ("依赖的作业失败或被取消了，这个作业不会再开始；需要 scancel 后重新提交，或用 scontrol update 修改依赖。",
                     "A job it depends on failed or was cancelled, so it will never start. Cancel and resubmit, or change the dependency with scontrol update."), act: true),
        .init(key: "Dependency", short: ("等待依赖作业", "Waiting for dependency"),
              long: ("在等待 --dependency 指定的作业结束。", "Waiting for the jobs given in --dependency to finish."), act: false),
        .init(key: "JobHeldUser", short: ("被你挂起", "Held by you"),
              long: ("作业被你自己 hold 住了，用 scontrol release <作业号> 释放后才会排队。", "You held this job; run scontrol release <jobid> to queue it."), act: true),
        .init(key: "JobHeldAdmin", short: ("被管理员挂起", "Held by admin"),
              long: ("作业被管理员 hold，需要联系管理员。", "An administrator held this job; contact them."), act: true),
        .init(key: "launch failed requeued held", short: ("启动失败已挂起", "Launch failed, held"),
              long: ("作业启动失败，被重新排队并挂起；检查脚本后用 scontrol release 释放。", "The job failed to launch and was requeued as held; check the script, then scontrol release."), act: true),
        .init(key: "BeginTime", short: ("未到开始时间", "Before begin time"),
              long: ("还没到 --begin 指定的开始时间。", "The --begin time has not been reached yet."), act: false),
        .init(key: "Priority", short: ("优先级排队中", "Queued by priority"),
              long: ("前面有优先级更高的作业，正常排队即可。", "Higher-priority jobs are ahead; just wait."), act: false),
        .init(key: "Resources", short: ("等待资源", "Waiting for resources"),
              long: ("优先级已经轮到你了，正在等待足够的空闲节点 / CPU / GPU。", "It is your turn; waiting for enough free nodes / CPUs / GPUs."), act: false),
        .init(key: "JobArrayTaskLimit", short: ("数组并发已满", "Array task limit"),
              long: ("数组作业同时运行的元素数已达到 %N 的上限，前面的元素结束后会继续。", "The array's %N concurrency limit is reached; more start as others finish."), act: false),
        .init(key: "AssocGrpBillingRunMinutes", short: ("组计费额度已满", "Group billing minutes full"),
              long: ("账户（组）正在运行的作业预计计费分钟数达到上限，需要等组内其他作业结束。", "Your account's running billing-minutes limit is reached; wait for other jobs in the group."), act: false),
        .init(key: "AssocGrpCPURunMinutes", short: ("组 CPU·分钟已满", "Group CPU-minutes full"),
              long: ("账户（组）正在运行作业的 CPU·分钟总量达到上限。", "Your account's running CPU-minutes limit is reached."), act: false),
        .init(key: "AssocGrpGRESRunMinutes", short: ("组 GPU·分钟已满", "Group GPU-minutes full"),
              long: ("账户（组）正在运行作业的 GPU·分钟总量达到上限。", "Your account's running GPU-minutes limit is reached."), act: false),
        .init(key: "AssocGrpGRES", short: ("组 GPU 总数已满", "Group GPU limit"),
              long: ("账户（组）同时使用的 GPU 数达到上限。", "Your account's GPU limit is reached."), act: false),
        .init(key: "AssocGrpCpuLimit", short: ("组 CPU 总数已满", "Group CPU limit"),
              long: ("账户（组）同时使用的 CPU 数达到上限。", "Your account's CPU limit is reached."), act: false),
        .init(key: "AssocGrpNodeLimit", short: ("组节点数已满", "Group node limit"),
              long: ("账户（组）同时使用的节点数达到上限。", "Your account's node limit is reached."), act: false),
        .init(key: "AssocGrpJobsLimit", short: ("组作业数已满", "Group job limit"),
              long: ("账户（组）同时运行的作业数达到上限。", "Your account's running-job limit is reached."), act: false),
        .init(key: "AssocGrpBilling", short: ("组计费额度已满", "Group billing limit"),
              long: ("账户（组）的计费额度达到上限。", "Your account's billing limit is reached."), act: false),
        .init(key: "AssocMaxJobsLimit", short: ("个人作业数已满", "Your job limit"),
              long: ("你同时运行的作业数达到上限。", "You have reached your running-job limit."), act: false),
        .init(key: "AssocMaxWallDurationPerJobLimit", short: ("时长超过上限", "Time over limit"),
              long: ("申请的运行时间超过了账户允许的单作业上限，会一直排队；需要减小 --time。", "The requested --time exceeds your account's per-job limit; it will never start. Reduce --time."), act: true),
        .init(key: "QOSMaxGRESPerUser", short: ("个人 GPU 上限", "Your GPU limit (QOS)"),
              long: ("你在这个 QOS 下同时使用的 GPU 数达到上限。", "You have reached the per-user GPU limit of this QOS."), act: false),
        .init(key: "QOSMaxCpuPerUserLimit", short: ("个人 CPU 上限", "Your CPU limit (QOS)"),
              long: ("你在这个 QOS 下同时使用的 CPU 数达到上限。", "You have reached the per-user CPU limit of this QOS."), act: false),
        .init(key: "QOSMaxJobsPerUserLimit", short: ("个人作业数上限", "Your job limit (QOS)"),
              long: ("你在这个 QOS 下同时运行的作业数达到上限。", "You have reached the per-user job limit of this QOS."), act: false),
        .init(key: "QOSMaxNodePerUserLimit", short: ("个人节点上限", "Your node limit (QOS)"),
              long: ("你在这个 QOS 下同时使用的节点数达到上限。", "You have reached the per-user node limit of this QOS."), act: false),
        .init(key: "QOSMaxWallDurationPerJobLimit", short: ("时长超过 QOS 上限", "Time over QOS limit"),
              long: ("申请的运行时间超过 QOS 允许的上限，会一直排队；需要减小 --time。", "The requested --time exceeds the QOS limit; it will never start. Reduce --time."), act: true),
        .init(key: "QOSGrp", short: ("QOS 总量已满", "QOS group limit"),
              long: ("这个 QOS 的总资源达到上限，需要等其他作业结束。", "This QOS's total limit is reached; wait for other jobs."), act: false),
        .init(key: "QOSNotAllowed", short: ("QOS 不允许", "QOS not allowed"),
              long: ("当前账户不能使用这个 QOS，需要更换 --qos。", "Your account cannot use this QOS; change --qos."), act: true),
        .init(key: "PartitionTimeLimit", short: ("时长超过分区上限", "Time over partition limit"),
              long: ("申请的运行时间超过分区上限，会一直排队；需要减小 --time 或换分区。", "The requested --time exceeds the partition limit; reduce --time or change partition."), act: true),
        .init(key: "PartitionNodeLimit", short: ("节点数超过分区限制", "Nodes over partition limit"),
              long: ("申请的节点数超出分区允许范围，会一直排队。", "The requested node count is outside the partition's limits; it will never start."), act: true),
        .init(key: "PartitionDown", short: ("分区已关闭", "Partition down"),
              long: ("分区处于 down 状态，等管理员恢复或换分区。", "The partition is down; wait or change partition."), act: false),
        .init(key: "PartitionInactive", short: ("分区未启用", "Partition inactive"),
              long: ("分区处于 inactive 状态。", "The partition is inactive."), act: false),
        .init(key: "ReqNodeNotAvail", short: ("指定节点不可用", "Required node unavailable"),
              long: ("需要的节点在维护、宕机或被预留，等节点恢复。", "Required nodes are down, in maintenance or reserved."), act: false),
        .init(key: "Nodes required for job are DOWN", short: ("所需节点不可用", "Required nodes down"),
              long: ("需要的节点宕机、drain 或被更高优先级分区预留。", "Required nodes are down, drained or reserved for higher-priority partitions."), act: false),
        .init(key: "Reservation", short: ("等待预约", "Waiting for reservation"),
              long: ("在等待预约（reservation）开始。", "Waiting for the reservation to start."), act: false),
        .init(key: "Licenses", short: ("等待许可证", "Waiting for licenses"),
              long: ("在等待软件许可证（license）空出来。", "Waiting for software licenses."), act: false),
        .init(key: "BadConstraints", short: ("约束无法满足", "Bad constraints"),
              long: ("--constraint 等条件没有节点能满足，会一直排队；需要修改约束。", "No node satisfies --constraint etc.; it will never start. Change the constraints."), act: true),
        .init(key: "InvalidAccount", short: ("账户无效", "Invalid account"),
              long: ("账户无效或没有权限，需要修改 --account。", "The account is invalid or not permitted; change --account."), act: true),
        .init(key: "InvalidQOS", short: ("QOS 无效", "Invalid QOS"),
              long: ("QOS 无效，需要修改 --qos。", "The QOS is invalid; change --qos."), act: true),
        .init(key: "Job's QOS not permitted", short: ("QOS 不能用于该分区", "QOS not allowed here"),
              long: ("当前 QOS 不允许使用这个分区，需要更换分区或 QOS。", "This QOS may not use the partition; change partition or QOS."), act: true),
        .init(key: "None", short: ("刚提交", "Just submitted"),
              long: ("刚提交，调度器还没处理到。", "Just submitted; the scheduler has not looked at it yet."), act: false),
    ]

    static func explain(_ raw: String?) -> PendingReason? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        for e in table where raw.hasPrefix(e.key) || (e.key.count > 12 && raw.localizedCaseInsensitiveContains(e.key)) {
            return PendingReason(short: L(e.short.0, e.short.1), long: L(e.long.0, e.long.1) + "\n（Slurm：\(raw)）",
                                 needsAction: e.act)
        }
        return PendingReason(short: String(raw.prefix(28)), long: raw, needsAction: false)
    }
}
