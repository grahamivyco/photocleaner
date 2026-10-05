import Foundation

enum Decision: String, Codable {
    case keep, toss
}

struct MonthProgress: Codable {
    /// In-progress choices, keyed by PHAsset.localIdentifier. Cleared when the month is finished.
    var decisions: [String: Decision] = [:]
    var finishedAt: Date?
    var deletedCount = 0
    var freedBytes: Int64 = 0
}

/// Saves progress to ~/Library/Application Support/Shoebox/progress.json.
@MainActor @Observable
final class ProgressStore {
    private(set) var months: [String: MonthProgress] = [:]
    private let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shoebox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("progress.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: MonthProgress].self, from: data) {
            months = decoded
        }
    }

    func progress(for key: MonthKey) -> MonthProgress {
        months[key.id] ?? MonthProgress()
    }

    func setDecision(_ decision: Decision?, id: String, month: MonthKey) {
        var p = progress(for: month)
        p.decisions[id] = decision
        months[month.id] = p
        save()
    }

    func finish(_ month: MonthKey, deleted: Int, freed: Int64) {
        var p = progress(for: month)
        p.decisions = [:]
        p.finishedAt = Date()
        p.deletedCount += deleted
        p.freedBytes += freed
        months[month.id] = p
        save()
    }

    var totalFreed: Int64 { months.values.reduce(0) { $0 + $1.freedBytes } }
    var totalDeleted: Int { months.values.reduce(0) { $0 + $1.deletedCount } }
    var finishedCount: Int { months.values.filter { $0.finishedAt != nil }.count }

    private func save() {
        do {
            let data = try JSONEncoder().encode(months)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Shoebox: could not save progress: \(error)")
        }
    }
}
