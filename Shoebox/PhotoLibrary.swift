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

    static func fetchAssets(in month: MonthKey) -> [PHAsset] {
        let opts = PHFetchOptions()
        opts.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            mediaPredicate,
            NSPredicate(format: "creationDate >= %@ AND creationDate < %@",
                        month.startDate as NSDate, month.endDate as NSDate),
        ])
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: opts)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        for i in 0..<result.count { assets.append(result.object(at: i)) }
        return assets
    }
}

@MainActor @Observable
final class PhotoLibrary {
    enum Access { case unknown, granted, denied }

    var access: Access = .unknown
    var driveConnected = false
    var months: [MonthSummary] = []
    var isIndexing = false
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

    /// Counts items per calendar month. Reads metadata only, never touches files.
    func buildIndex() async {
        guard access == .granted, driveConnected, !isIndexing else { return }
        isIndexing = true
        let result = await Task.detached(priority: .userInitiated) { () -> [MonthSummary] in
            let opts = PHFetchOptions()
            opts.predicate = MediaFilter.mediaPredicate
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            let assets = PHAsset.fetchAssets(with: opts)
            let cal = Calendar.current
            var buckets: [MonthKey: MonthSummary] = [:]
            for i in 0..<assets.count {
                let asset = assets.object(at: i)
                guard let date = asset.creationDate else { continue }
                let c = cal.dateComponents([.year, .month], from: date)
                guard let y = c.year, let m = c.month else { continue }
                let key = MonthKey(year: y, month: m)
                var s = buckets[key] ?? MonthSummary(key: key, photos: 0, videos: 0)
                if asset.mediaType == .video { s.videos += 1 } else { s.photos += 1 }
                if s.coverID == nil { s.coverID = asset.localIdentifier }
                buckets[key] = s
            }
            return buckets.values.sorted { $0.key > $1.key }
        }.value
        months = result
        isIndexing = false
    }

    private static func map(_ s: PHAuthorizationStatus) -> Access {
        switch s {
        case .authorized, .limited: return .granted
        case .notDetermined: return .unknown
        default: return .denied
        }
    }
}
