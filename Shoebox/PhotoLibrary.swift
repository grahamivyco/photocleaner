import AppKit
import Photos

struct MonthKey: Hashable, Codable, Comparable, Identifiable {
    let year: Int
    let month: Int

    var id: String { String(format: "%04d-%02d", year, month) }

    static func < (a: MonthKey, b: MonthKey) -> Bool { (a.year, a.month) < (b.year, b.month) }

    var startDate: Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: 1))!
    }

    var endDate: Date {
        Calendar.current.date(byAdding: .month, value: 1, to: startDate)!
    }

    var monthName: String {
        Calendar.current.monthSymbols[month - 1]
    }

    var title: String { "\(monthName) \(year)" }

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    init(_ date: Date) {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1)
    }

    var previous: MonthKey {
        month == 1 ? MonthKey(year: year - 1, month: 12) : MonthKey(year: year, month: month - 1)
    }
}

struct MonthSummary: Identifiable {
    let key: MonthKey
    var photos: Int
    var videos: Int
    var coverID: String?

    var id: String { key.id }
    var total: Int { photos + videos }
}

enum MediaFilter {
    /// Photos and videos only (skips audio and unknown types).
    static var mediaPredicate: NSPredicate {
        NSPredicate(format: "mediaType == %@ OR mediaType == %@",
                    NSNumber(value: PHAssetMediaType.image.rawValue),
                    NSNumber(value: PHAssetMediaType.video.rawValue))
    }

    static func options(for month: MonthKey, videosOnly: Bool = false, sorted: Bool = true) -> PHFetchOptions {
        let opts = PHFetchOptions()
        opts.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            videosOnly
                ? NSPredicate(format: "mediaType == %@", NSNumber(value: PHAssetMediaType.video.rawValue))
                : mediaPredicate,
            NSPredicate(format: "creationDate >= %@ AND creationDate < %@",
                        month.startDate as NSDate, month.endDate as NSDate),
        ])
        if sorted { opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)] }
        return opts
    }

    static func fetchAssets(in month: MonthKey) -> [PHAsset] {
        let result = PHAsset.fetchAssets(with: options(for: month))
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        for i in 0..<result.count { assets.append(result.object(at: i)) }
        return assets
    }

    /// Counts for one month using database counts, without loading every item.
    static func summary(for month: MonthKey) -> MonthSummary? {
        let all = PHAsset.fetchAssets(with: options(for: month))
        guard all.count > 0 else { return nil }
        let videos = PHAsset.fetchAssets(with: options(for: month, videosOnly: true, sorted: false)).count
        return MonthSummary(key: month, photos: all.count - videos, videos: videos,
                            coverID: all.firstObject?.localIdentifier)
    }

    /// Oldest and newest dated items. Two indexed lookups, no items loaded.
    static func dateRange() -> LibraryRange {
        func edge(ascending: Bool) -> Date? {
            let opts = PHFetchOptions()
            opts.predicate = mediaPredicate
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: ascending)]
            opts.fetchLimit = 1
            return PHAsset.fetchAssets(with: opts).firstObject?.creationDate
        }
        return LibraryRange(oldest: edge(ascending: true), newest: edge(ascending: false))
    }
}

struct LibraryRange: Sendable {
    let oldest: Date?
    let newest: Date?
}

@MainActor @Observable
final class PhotoLibrary {
    enum Access: Equatable {
        case notDetermined, requesting, authorized, limited, denied, restricted
    }

    enum Phase: Equatable {
        case idle
        case working(String)
        case notResponding(String)
        case ready
    }

    var access: Access = .notDetermined
    var driveConnected = false
    var phase: Phase = .idle
    /// When the current Photos lookup started, for the elapsed-time readout.
    var phaseStarted = Date()

    /// Shown straight away from the calendar, then trimmed to the library's
    /// real range once Photos answers.
    var years: [Int] = Array(stride(from: Calendar.current.component(.year, from: Date()),
                                    through: Config.earliestGuessYear, by: -1))
    private(set) var oldest: MonthKey?
    private(set) var newest: MonthKey?
    private(set) var rangeKnown = false

    var summaries: [MonthKey: MonthSummary] = [:]
    var emptyMonths: Set<MonthKey> = []
    var itemsCounted: Int { summaries.values.reduce(0) { $0 + $1.total } }
    var monthsCounted: Int { summaries.count + emptyMonths.count }

    /// Months waiting to be counted. The front is counted next.
    private var queue: [MonthKey] = []
    private var worker: Task<Void, Never>?
    // PhotoKit calls can't be cancelled, so a lookup that times out is kept
    // and waited on again by Retry instead of being started twice.
    private var rangeTask: Task<LibraryRange, Never>?
    private var summaryTasks: [MonthKey: Task<MonthSummary?, Never>] = [:]
    private var observers: [NSObjectProtocol] = []

    var isAuthorized: Bool { access == .authorized || access == .limited }
    private var canQuery: Bool { isAuthorized && driveConnected }

    init() {
        access = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        driveConnected = FileManager.default.fileExists(atPath: Config.libraryPath)
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDrive() }
            })
        }
        // Picks up a change made in System Settings while Shoebox was in the background.
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccess() }
        })
    }

    // MARK: Access and drive

    func refreshAccess() {
        guard access != .requesting else { return }
        access = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        pump()
    }

    func requestAccess() async {
        access = .requesting
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        access = Self.map(status)
        pump()
    }

    func refreshDrive() {
        driveConnected = FileManager.default.fileExists(atPath: Config.libraryPath)
        if !driveConnected && phase != .ready { phase = .idle }
        pump()
    }

    // MARK: Loading

    /// Starts (or resumes) loading. Safe to call any time.
    func start() { pump() }

    /// After a timeout: wait another 30 seconds on the same lookup.
    func retry() {
        if case .notResponding = phase { phase = .idle }
        pump()
    }

    /// The months of one year to show. Before Photos answers, every month up to today.
    func months(in year: Int) -> [MonthKey] {
        let all = (1...12).map { MonthKey(year: year, month: $0) }
        if let oldest, let newest { return all.filter { $0 >= oldest && $0 <= newest } }
        let now = MonthKey(Date())
        return all.filter { $0 <= now }
    }

    /// Asks for a month's count. Called when its tile appears; newest requests go first.
    func requestSummary(_ key: MonthKey) {
        guard summaries[key] == nil, !emptyMonths.contains(key) else { return }
        queue.removeAll { $0 == key }
        queue.insert(key, at: 0)
        pump()
    }

    func isCounting(_ key: MonthKey) -> Bool {
        if case .working = phase { return queue.first == key && rangeKnown }
        return false
    }

    /// Forget a month's count so it's recounted (after deleting from it).
    func invalidate(_ key: MonthKey) {
        summaries[key] = nil
        emptyMonths.remove(key)
    }

    private func pump() {
        guard worker == nil, canQuery else { return }
        if case .notResponding = phase { return }
        worker = Task {
            await runQueue()
            worker = nil
        }
    }

    /// One Photos lookup at a time: the date range first, then month counts.
    private func runQueue() async {
        if !rangeKnown {
            guard await loadRange() else { return }
        }
        while let key = queue.first {
            guard canQuery else { return }
            begin(.working("Counting \(key.title)"))
            let task = summaryTasks[key] ?? Task.detached(priority: .userInitiated) { MediaFilter.summary(for: key) }
            summaryTasks[key] = task
            guard let result = await Waiter.value(of: task, timeout: Config.photosTimeout) else {
                phase = .notResponding("Photos didn't answer within \(Config.photosTimeoutSeconds) seconds while counting \(key.title).")
                NSLog("Shoebox: timed out counting %@", key.id)
                return
            }
            summaryTasks[key] = nil
            queue.removeAll { $0 == key }
            if let s = result { summaries[key] = s } else { emptyMonths.insert(key) }
        }
        phase = .ready
    }

    private func loadRange() async -> Bool {
        begin(.working("Finding your oldest and newest photos"))
        let task = rangeTask ?? Task.detached(priority: .userInitiated) { MediaFilter.dateRange() }
        rangeTask = task
        guard let range = await Waiter.value(of: task, timeout: Config.photosTimeout) else {
            phase = .notResponding("Photos didn't answer within \(Config.photosTimeoutSeconds) seconds while opening your library.")
            NSLog("Shoebox: timed out finding date range")
            return false
        }
        rangeTask = nil
        NSLog("Shoebox: date range took %.1fs", Date().timeIntervalSince(phaseStarted))
        rangeKnown = true
        if let first = range.oldest, let last = range.newest {
            oldest = MonthKey(first)
            newest = MonthKey(last)
            years = Array(stride(from: newest!.year, through: oldest!.year, by: -1))
        } else {
            years = []
        }
        // Drop queued months outside the real range.
        queue.removeAll { !months(in: $0.year).contains($0) }
        return true
    }

    private func begin(_ p: Phase) {
        if p != phase { phaseStarted = Date() }
        phase = p
    }

    private static func map(_ s: PHAuthorizationStatus) -> Access {
        switch s {
        case .authorized: return .authorized
        case .limited: return .limited
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
}

/// Waits for a background task but stops waiting after `timeout`.
/// The task keeps running, so waiting on it again later still gets its result.
enum Waiter {
    static func value<T: Sendable>(of task: Task<T, Never>, timeout: Duration) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let once = ResumeOnce(cont)
            Task {
                let v = await task.value
                once.resume(v)
            }
            Task {
                try? await Task.sleep(for: timeout)
                once.resume(nil)
            }
        }
    }
}

private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T?, Never>?

    init(_ cont: CheckedContinuation<T?, Never>) { self.cont = cont }

    func resume(_ value: T?) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
