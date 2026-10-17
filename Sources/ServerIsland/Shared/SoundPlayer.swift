import AppKit

/// 播放提示音。声音由 scripts/gen_sounds.py 合成，打包在 App 的 Resources/Sounds 里。
@MainActor
final class SoundPlayer {
    enum Kind: String { case success, failure, warning }

    static let shared = SoundPlayer()
    private var cache: [Kind: NSSound] = [:]
    private var lastPlayed = Date.distantPast

    func play(_ kind: Kind, volume: Double) {
        // 短时间内多个事件只响一次。
        guard Date().timeIntervalSince(lastPlayed) > 1.2 else { return }
        lastPlayed = Date()
        guard let sound = sound(kind) else { NSSound.beep(); return }
        sound.stop()
        sound.volume = Float(max(0, min(volume, 1)))
        sound.play()
    }

    /// 设置页试听，不受节流限制。
    func preview(_ kind: Kind, volume: Double) {
        lastPlayed = .distantPast
        play(kind, volume: volume)
    }

    private func sound(_ kind: Kind) -> NSSound? {
        if let s = cache[kind] { return s }
        let url = Bundle.main.url(forResource: kind.rawValue, withExtension: "wav", subdirectory: "Sounds")
            ?? Bundle.main.url(forResource: kind.rawValue, withExtension: "wav")
        guard let url, let s = NSSound(contentsOf: url, byReference: true) else { return nil }
        cache[kind] = s
        return s
    }
}
