import Foundation

/// Tracks whether a sensor connection still works, and paces attempts to
/// replace one that does not.
///
/// The IOKit connection is opened once and can die while the app runs. When it
/// does, every individual key read fails but the capture still *succeeds* with
/// an empty result — so without this the app reports "SMC available" next to
/// zero sensors forever, instead of the unavailable state it already has a UI
/// for.
///
/// Kept out of the actor that owns the connection so the policy is testable
/// without IOKit: the actor is a thin shell around `SMC`, and neither test
/// build can compile it.
public struct SensorConnectionHealth: Sendable {
    /// Consecutive empty captures before the connection is presumed dead. One
    /// can be a transient hiccup; three in a row at the app's cadence is not.
    public static let failuresBeforeReconnect = 3
    /// Floor between reopen attempts, so a genuinely absent SMC cannot turn
    /// every refresh into an `IOServiceOpen` call.
    public static let minimumReconnectInterval: TimeInterval = 30

    private var consecutiveFailures = 0
    private var lastReconnectAttempt: Date?

    public init() {}

    /// Whether recent captures have been producing readings.
    public var isHealthy: Bool { consecutiveFailures < Self.failuresBeforeReconnect }

    public mutating func recordSuccess() {
        consecutiveFailures = 0
        lastReconnectAttempt = nil
    }

    /// Records a capture that produced nothing, and answers whether the caller
    /// should now discard its connection and open a fresh one.
    public mutating func recordFailure(now: Date) -> Bool {
        consecutiveFailures += 1
        guard consecutiveFailures >= Self.failuresBeforeReconnect else { return false }
        if let lastReconnectAttempt,
           now.timeIntervalSince(lastReconnectAttempt) < Self.minimumReconnectInterval {
            return false
        }
        lastReconnectAttempt = now
        return true
    }
}
