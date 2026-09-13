import Foundation

/// A shared token-clock limiter. All tasks using the global setting share one
/// actor, so aggregate throughput cannot exceed the configured rate.
public actor SpeedLimiter {
    private var nextPermit: UInt64 = 0
    public init() {}
    public func acquire(bytes: Int, limit: Int64) async {
        guard bytes > 0, limit > 0 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let start = max(now, nextPermit)
        nextPermit = start &+ UInt64((Double(bytes) / Double(limit)) * 1_000_000_000.0)
        if start > now { try? await Task.sleep(nanoseconds: start - now) }
    }
}
