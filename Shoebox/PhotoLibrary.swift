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
        if sorted { opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)] }
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
        // Unsorted counts are the cheapest questions Photos can answer.
        let total = PHAsset.fetchAssets(with: options(for: month, sorted: false)).count
        guard total > 0 else { return nil }
        let videos = PHAsset.fetchAssets(with: options(for: month, videosOnly: true, sorted: false)).count
        return MonthSummary(key: month, photos: total - videos, videos: videos, coverID: nil)
    }

    /// The newest item in a month, for the tile picture. Asked for after the count.
    static func coverID(for month: MonthKey) -> String? {
        let opts = options(for: month)
        opts.fetchLimit = 1
        return PHAsset.fetchAssets(with: opts).firstObject?.localIdentifier
    }
}

@MainActor @Observable
final class PhotoLibrary {
    enum Access: Equatable {
        case notDetermined, requesting, authorized, limited, denied, restricted
    }

    enum Phase: Equatable {
        case idle
        case working(String)
        case ready
    }

    var access: Access = .notDetermined
    var driveConnected = false
    var phase: Phase = .idle
    /// When the current Photos lookup started, for the elapsed-time readout.
    var phaseStarted = Date()

    /// Straight from the calendar, so the grid never waits on Photos.
    var years: [Int] = Array(stride(from: Calendar.current.component(.year, from: Date()),
                                    through: Config.earliestGuessYear, by: -1))

    var summaries: [MonthKey: MonthSummary] = [:]
    var emptyMonths: Set<MonthKey> = []
    var itemsCounted: Int { summaries.values.reduce(0) { $0 + $1.total } }
    var monthsCounted: Int { summaries.count + emptyMonths.count }

    /// Months waiting to be counted. The front is counted next.
    private var queue: [MonthKey] = []
    private var worker: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    var isAuthorized: Bool { access == .authorized || access == .limited }
    private var canQuery: Bool { isAuthorized && driveConnected }

    init() {
        access = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        driveConnected = !requireDrive || FileManager.default.fileExists(atPath: Config.libraryPath)
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

    /// Off when the System Photo Library has moved off the external drive.
    var requireDrive: Bool = UserDefaults.standard.object(forKey: "requireDrive") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(requireDrive, forKey: "requireDrive")
            refreshDrive()
        }
    }

    func refreshDrive() {
        driveConnected = !requireDrive || FileManager.default.fileExists(atPath: Config.libraryPath)
        if !driveConnected && phase != .ready { phase = .idle }
        pump()
    }

    // MARK: Loading

    /// Starts (or resumes) loading. Safe to call any time.
    func start() { pump() }

    /// The months of one year up to today, newest first.
    func months(in year: Int) -> [MonthKey] {
        let now = MonthKey(Date())
        return (1...12).reversed().map { MonthKey(year: year, month: $0) }.filter { $0 <= now }
    }

    /// Asks for a month's count. Called when its tile appears; newest requests go first.
    func requestSummary(_ key: MonthKey) {
        guard summaries[key] == nil, !emptyMonths.contains(key), !queue.contains(key) else { return }
        queue.append(key)
        pump()
    }

    /// The month being counted right now.
    private(set) var countingKey: MonthKey?

    func isCounting(_ key: MonthKey) -> Bool { countingKey == key }

    func isCounted(_ key: MonthKey) -> Bool { summaries[key] != nil || emptyMonths.contains(key) }

    /// Forget a month's count so it's recounted (after deleting from it).
    func invalidate(_ key: MonthKey) {
        summaries[key] = nil
        emptyMonths.remove(key)
    }

    private func pump() {
        guard worker == nil, canQuery else { return }
        worker = Task {
            await runQueue()
            worker = nil
        }
    }

    /// One Photos lookup at a time, newest request first. No time limit:
    /// a busy Photos just takes longer, and the status line shows how long.
    private func runQueue() async {
        defer { countingKey = nil }
        repeat {
            // Always the newest waiting month next, so the current month comes first.
            while let key = queue.max() {
                guard canQuery else { return }
                countingKey = key
                begin(.working("Counting \(key.title)"))
                let result = await Task.detached(priority: .userInitiated) { MediaFilter.summary(for: key) }.value
                NSLog("Shoebox: counted %@ in %.1fs", key.id, Date().timeIntervalSince(phaseStarted))
                queue.removeAll { $0 == key }
                if let s = result { summaries[key] = s } else { emptyMonths.insert(key) }
            }
            countingKey = nil
            // Tile pictures last, and only while no month is waiting to be counted.
            for key in summaries.keys.sorted(by: >) where summaries[key]?.coverID == nil {
                guard canQuery, queue.isEmpty else { break }
                begin(.working("Loading pictures"))
                let id = await Task.detached(priority: .utility) { MediaFilter.coverID(for: key) }.value
                summaries[key]?.coverID = id
            }
        } while canQuery && !queue.isEmpty
        phase = .ready
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
