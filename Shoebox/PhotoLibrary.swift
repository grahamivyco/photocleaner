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

    /// Oldest and newest dated items in the library.
    static func dateRange() -> (oldest: Date, newest: Date)? {
        func edge(ascending: Bool) -> Date? {
            let opts = PHFetchOptions()
            opts.predicate = mediaPredicate
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: ascending)]
            opts.fetchLimit = 1
            return PHAsset.fetchAssets(with: opts).firstObject?.creationDate
        }
        guard let oldest = edge(ascending: true), let newest = edge(ascending: false) else { return nil }
        return (oldest, newest)
    }
}

@MainActor @Observable
final class PhotoLibrary {
    enum Access { case unknown, granted, denied }

    var access: Access = .unknown
    var driveConnected = false
    var months: [MonthSummary] = []
    var isIndexing = false
    var indexingMonth: MonthKey?
    private var observers: [NSObjectProtocol] = []

    init() {
        access = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        refreshDrive()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDrive() }
            })
        }
    }

    func refreshDrive() {
        let connected = FileManager.default.fileExists(atPath: Config.libraryPath)
        let wasConnected = driveConnected
        driveConnected = connected
        if connected && !wasConnected && access == .granted && months.isEmpty {
            Task { await buildIndex() }
        }
    }

    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        access = Self.map(status)
        if access == .granted { await buildIndex() }
    }

    /// Counts items month by month, newest first. Reads metadata only, never touches files.
    func buildIndex() async {
        guard access == .granted, driveConnected, !isIndexing else { return }
        isIndexing = true
        defer {
            isIndexing = false
            indexingMonth = nil
        }
        guard let range = await Task.detached(priority: .userInitiated, operation: { MediaFilter.dateRange() }).value else {
            months = []
            return
        }
        let firstBuild = months.isEmpty
        let oldest = MonthKey(range.oldest)
        var key = MonthKey(range.newest)
        var found: [MonthSummary] = []
        while key >= oldest {
            indexingMonth = key
            let month = key
            if let s = await Task.detached(priority: .userInitiated, operation: { MediaFilter.summary(for: month) }).value {
                found.append(s)
                if firstBuild { months = found }
            }
            key = key.previous
        }
        months = found
    }

    private static func map(_ s: PHAuthorizationStatus) -> Access {
        switch s {
        case .authorized, .limited: return .granted
        case .notDetermined: return .unknown
        default: return .denied
        }
    }
}
