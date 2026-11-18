#if os(iOS)
import AVFoundation
import UIKit

/// The shared detent cue for the frame-rate/media dials and the duration wheel: a soft,
/// short synthesized click with a light haptic, so turning any dial feels like one instrument.
///
/// It stays gentle on purpose:
/// - the click is a low, quickly decaying tone at low volume instead of the system tick;
/// - the ambient audio session follows the Ring/Silent switch and mixes with other audio;
/// - detents closer than `minimumInterval` are skipped, and quick spins play quieter, so a
///   fling sounds like a soft ratchet rather than a buzz;
/// - the audio engine pauses after a short idle period.
@MainActor
final class DialFeedback {
    static let shared = DialFeedback()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let haptic = UIImpactFeedbackGenerator(style: .soft)
    private var click: AVAudioPCMBuffer?
    private var notchClick: AVAudioPCMBuffer?
    private var configured = false
    private var lastCue: TimeInterval = 0
    private var idleTask: Task<Void, Never>?

    /// Faster detents are dropped rather than queued, which is what keeps a fling soft.
    private let minimumInterval: TimeInterval = 0.035
    /// Detents at least this far apart play at full (still low) level.
    private let restingInterval: TimeInterval = 0.12

    private init() {}

    /// Call when a touch lands on a dial so the first detent plays without start-up latency.
    func prepare() {
        haptic.prepare()
        startAudioIfNeeded()
    }

    /// One detent. Notches are production-standard stops and land a little firmer and lower.
    func detent(notch: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        let interval = now - lastCue
        guard interval >= minimumInterval else { return }
        lastCue = now
        let pace = min(1, max(0.35, interval / restingInterval))
        haptic.impactOccurred(intensity: (notch ? 0.7 : 0.4) * pace)
        playClick(notch: notch, level: Float(pace))
        haptic.prepare()
        pauseWhenIdle()
    }

    private func startAudioIfNeeded() {
        if !configured {
            configured = true
            // Ambient: silent with the Ring/Silent switch and never interrupts the operator's audio.
            try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else { return }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            click = Self.tone(format: format, frequency: 1_150, duration: 0.014, amplitude: 0.09)
            notchClick = Self.tone(format: format, frequency: 820, duration: 0.020, amplitude: 0.13)
        }
        // Route changes and interruptions stop the engine; restart on the next detent.
        guard !engine.isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        engine.prepare()
        try? engine.start()
    }

    private func playClick(notch: Bool, level: Float) {
        startAudioIfNeeded()
        guard engine.isRunning, let buffer = notch ? notchClick : click else { return }
        player.volume = level
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    private func pauseWhenIdle() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.player.stop()
            self.engine.pause()
        }
    }

    /// A short sine "tock" with a soft attack and fast decay: no hard edge, no ringing tail.
    private static func tone(format: AVAudioFormat, frequency: Double, duration: Double,
                             amplitude: Float) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for frame in 0 ..< Int(frames) {
            let time = Double(frame) / format.sampleRate
            let attack = min(1, time / 0.0015)
            let decay = exp(-time / (duration / 5))
            samples[frame] = amplitude * Float(attack * decay * sin(2 * .pi * frequency * time))
        }
        return buffer
    }
}
#endif
