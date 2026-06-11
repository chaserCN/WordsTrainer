import QuartzCore
import UIKit

/// Logs dropped-frame "hitches": a frame whose interval ran meaningfully longer
/// than the display's per-frame budget. A hitch is what a micro-lag actually is —
/// the main thread missed a frame during an animation/transition.
///
/// Driven by CADisplayLink so it measures the real refresh cadence (60 or 120 Hz).
/// Diagnostic only; remove with the other Log call sites once perf is settled.
///
/// Note: in the Simulator frame timing is unreliable (rendered on the Mac, no
/// ProMotion), so absolute numbers there are indicative, not authoritative — but
/// comparing two flows (Колоди vs Сегодня) on the same machine is still useful.
@MainActor
final class FrameHitchMonitor {
    static let shared = FrameHitchMonitor()

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    /// A frame is a hitch if it overruns the budget by more than this factor.
    private let hitchThreshold: Double = 1.5
    /// Active label for the window being measured (e.g. "enter flashcard").
    private var marker: String = "idle"
    private var hitchCount = 0
    private var worstOverrunMs = 0

    private init() {}

    /// Begin counting hitches and tag them with `label` until the next mark/stop.
    func mark(_ label: String) {
        // Flush the previous window's summary before switching.
        flushSummary()
        marker = label
        hitchCount = 0
        worstOverrunMs = 0
    }

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTimestamp = 0
    }

    func stop() {
        flushSummary()
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = 0
    }

    private func flushSummary() {
        if hitchCount > 0 {
            Log.log("Frame", "window '\(marker)': \(hitchCount) hitch(es), worst frame overran budget by \(worstOverrunMs)ms")
        }
        hitchCount = 0
        worstOverrunMs = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard lastTimestamp != 0 else { return }

        let actual = link.timestamp - lastTimestamp
        // targetTimestamp - timestamp is the budget for this frame (handles 60 vs
        // 120 Hz automatically).
        let budget = link.targetTimestamp - link.timestamp
        guard budget > 0 else { return }

        if actual > budget * hitchThreshold {
            let overrunMs = Int((actual - budget) * 1000)
            hitchCount += 1
            worstOverrunMs = max(worstOverrunMs, overrunMs)
            Log.log("Frame", "hitch during '\(marker)': frame took \(Int(actual * 1000))ms (budget \(Int(budget * 1000))ms, +\(overrunMs)ms)")
        }
    }
}
