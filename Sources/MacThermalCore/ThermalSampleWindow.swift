import Foundation

/// Selects the recent tail of a sample series.
public enum ThermalSampleWindow {
    /// The samples at or after `cutoff`.
    ///
    /// History is normally append-only and time-ordered, so the boundary is found
    /// by binary search and the window is returned as a slice. The previous
    /// linear scan took 4.5 ms to return 119 samples out of 40,319, most of it
    /// spent reserving room for the entire history on every dashboard refresh.
    ///
    /// A backwards clock jump (NTP, DST, a manual change) can leave a sample out
    /// of order, and a binary search over unsorted input silently drops rows, so
    /// the caller passes what it knows: `ThermalArchiveState` maintains the
    /// ordering flag in O(1) as it mutates. When it is false this falls back to
    /// an exhaustive filter instead of guessing.
    public static func recent(
        _ samples: [ThermalSample],
        since cutoff: Date,
        chronological: Bool = true,
        isCancelled: () -> Bool = { false }
    ) -> [ThermalSample] {
        guard chronological else { return filtered(samples, since: cutoff, isCancelled: isCancelled) }

        var low = 0
        var high = samples.count
        while low < high {
            let middle = low + (high - low) / 2
            if samples[middle].timestamp < cutoff { low = middle + 1 } else { high = middle }
        }
        return Array(samples[low...])
    }

    private static func filtered(
        _ samples: [ThermalSample],
        since cutoff: Date,
        isCancelled: () -> Bool
    ) -> [ThermalSample] {
        var recent: [ThermalSample] = []
        for (index, sample) in samples.enumerated() {
            if index.isMultiple(of: 256), isCancelled() { return recent }
            if sample.timestamp >= cutoff { recent.append(sample) }
        }
        return recent
    }
}
