import Foundation

struct TrafficRateSample: Equatable {
    let date: Date
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
}

/// A small in-memory ring buffer used by the status-panel traffic chart.
struct TrafficRateHistory {
    let capacity: Int
    private(set) var samples: [TrafficRateSample] = []

    init(capacity: Int = 60) {
        self.capacity = max(capacity, 1)
    }

    mutating func append(
        downloadBytesPerSecond: Double,
        uploadBytesPerSecond: Double,
        at date: Date = Date()
    ) {
        samples.append(
            TrafficRateSample(
                date: date,
                downloadBytesPerSecond: sanitized(downloadBytesPerSecond),
                uploadBytesPerSecond: sanitized(uploadBytesPerSecond)
            )
        )
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    var peakBytesPerSecond: Double {
        max(
            samples.reduce(0) {
                max($0, $1.downloadBytesPerSecond, $1.uploadBytesPerSecond)
            },
            1
        )
    }

    private func sanitized(_ value: Double) -> Double {
        value.isFinite ? max(value, 0) : 0
    }
}
