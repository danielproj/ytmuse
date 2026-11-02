import Foundation

/// A tiny timing harness for the indicative headless measurements. Samples are wall-clock milliseconds; results are printed as `BENCH <name> ...` lines and,
/// when `YTMUSE_PERF_BENCH_OUT` names a directory, appended to `<dir>/benchmarks.jsonl` so `scripts/perf-report.py` can tabulate them.
enum Bench {
    struct Result: Codable { var name: String; var samples: [Double]; var unit = "ms"; var notes: String? }
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(sorted.count - 1, max(0, rank))]
    }
    @discardableResult static func time(_ name: String, samples: Int = 15, warmup: Int = 2, notes: String? = nil, _ work: () throws -> Void) rethrows -> Result {
        for _ in 0..<warmup { try work() }
        var values: [Double] = []
        for _ in 0..<samples {
            let start = DispatchTime.now().uptimeNanoseconds
            try work()
            values.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return report(Result(name: name, samples: values, notes: notes))
    }
    @MainActor @discardableResult static func timeMain(_ name: String, samples: Int = 15, warmup: Int = 2, notes: String? = nil, _ work: @MainActor () throws -> Void) rethrows -> Result {
        for _ in 0..<warmup { try work() }
        var values: [Double] = []
        for _ in 0..<samples {
            let start = DispatchTime.now().uptimeNanoseconds
            try work()
            values.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return report(Result(name: name, samples: values, notes: notes))
    }
    @discardableResult static func report(_ result: Result) -> Result {
        let line = String(format: "BENCH %@ n=%d p50=%.2fms p95=%.2fms worst=%.2fms", result.name, result.samples.count, percentile(result.samples, 0.5), percentile(result.samples, 0.95), result.samples.max() ?? .nan)
        print(line + (result.notes.map { " (\($0))" } ?? ""))
        if let directory = ProcessInfo.processInfo.environment["YTMUSE_PERF_BENCH_OUT"], !directory.isEmpty,
           let data = try? JSONEncoder().encode(result) {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("benchmarks.jsonl")
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            if let handle = try? FileHandle(forWritingTo: url) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data + Data([0x0A])); try? handle.close() }
        }
        return result
    }
}
