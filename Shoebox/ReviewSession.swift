import Photos

/// One month under review. Choices are saved as they're made; nothing is
/// deleted until `deleteMarked()` runs from the summary screen.
@MainActor @Observable
final class ReviewSession {
    let month: MonthKey
    let assets: [PHAsset]
    private(set) var index: Int = 0
    private(set) var decisions: [String: Decision] = [:]
    /// Size and file name per item, filled in off the main thread.
    private(set) var info: [String: ItemInfo] = [:]
    private var infoLoading: Set<String> = []
    private var history: [Int] = []
    private let store: ProgressStore

    struct ItemInfo: Sendable {
        let size: Int64
        let filename: String?
    }

    /// Fetches the month's items off the main thread, so the window never freezes.
    static func open(month: MonthKey, store: ProgressStore) async -> ReviewSession {
        let assets = await Task.detached(priority: .userInitiated) { MediaFilter.fetchAssets(in: month) }.value
        return ReviewSession(month: month, store: store, assets: assets)
    }

    private init(month: MonthKey, store: ProgressStore, assets: [PHAsset]) {
        self.month = month
        self.store = store
        self.assets = assets

        // Resume earlier choices that still match items in this month.
        let saved = store.progress(for: month).decisions
        for (i, asset) in assets.enumerated() {
            if let d = saved[asset.localIdentifier] {
                decisions[asset.localIdentifier] = d
                history.append(i)
            }
        }
        index = nextUndecided(after: -1)
        loadInfo(for: markedAssets)
        prefetchInfo()
    }

    var current: PHAsset? { index < assets.count ? assets[index] : nil }
    var isComplete: Bool { current == nil }
    var decidedCount: Int { decisions.count }
    var remaining: Int { assets.count - decidedCount }
    var canUndo: Bool { !history.isEmpty }

    var markedAssets: [PHAsset] { assets.filter { decisions[$0.localIdentifier] == .toss } }
    var markedCount: Int { decisions.values.filter { $0 == .toss }.count }
    var keptCount: Int { decisions.values.filter { $0 == .keep }.count }

    /// Space the tossed items would free. Items whose size is still loading count as 0 for a moment.
    var markedBytes: Int64 {
        decisions.reduce(Int64(0)) { total, entry in
            entry.value == .toss ? total + (info[entry.key]?.size ?? 0) : total
        }
    }

    func decide(_ decision: Decision) {
        guard let asset = current else { return }
        let id = asset.localIdentifier
        decisions[id] = decision
        history.append(index)
        if decision == .toss { loadInfo(for: [asset]) }
        store.setDecision(decision, id: id, month: month)
        index = nextUndecided(after: index)
        prefetchInfo()
    }

    func undo() {
        guard let i = history.popLast() else { return }
        let asset = assets[i]
        let id = asset.localIdentifier
        decisions[id] = nil
        store.setDecision(nil, id: id, month: month)
        index = i
    }

    /// Used from the summary grid to rescue an item before confirming.
    func keepInstead(_ asset: PHAsset) {
        let id = asset.localIdentifier
        guard decisions[id] == .toss else { return }
        decisions[id] = .keep
        store.setDecision(.keep, id: id, month: month)
    }

    /// Moves marked items to Recently Deleted. Photos shows its own confirmation first.
    func deleteMarked() async throws {
        let marked = markedAssets
        let freed = markedBytes
        if !marked.isEmpty {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(marked as NSArray)
            }
        }
        store.finish(month, deleted: marked.count, freed: freed)
    }

    /// Loads size and file name for the next few items so the info line never waits.
    private func prefetchInfo() {
        guard index < assets.count else { return }
        loadInfo(for: Array(assets[index..<min(index + 8, assets.count)]))
    }

    private func loadInfo(for items: [PHAsset]) {
        let todo = items.filter { info[$0.localIdentifier] == nil && !infoLoading.contains($0.localIdentifier) }
        guard !todo.isEmpty else { return }
        todo.forEach { infoLoading.insert($0.localIdentifier) }
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { () -> [String: ItemInfo] in
                var out: [String: ItemInfo] = [:]
                for a in todo {
                    let resources = PHAssetResource.assetResources(for: a)
                    out[a.localIdentifier] = ItemInfo(size: ReviewSession.fileSize(of: resources),
                                                      filename: resources.first?.originalFilename)
                }
                return out
            }.value
            guard let self else { return }
            self.info.merge(loaded) { a, _ in a }
            loaded.keys.forEach { self.infoLoading.remove($0) }
        }
    }

    /// Sum of every stored resource (original, Live Photo video, edits).
    nonisolated static func fileSize(of resources: [PHAssetResource]) -> Int64 {
        resources.reduce(Int64(0)) { total, resource in
            guard resource.responds(to: NSSelectorFromString("fileSize")),
                  let n = resource.value(forKey: "fileSize") as? NSNumber else { return total }
            return total + n.int64Value
        }
    }

    private func nextUndecided(after i: Int) -> Int {
        let undecided = { (j: Int) in self.decisions[self.assets[j].localIdentifier] == nil }
        if let j = assets.indices.first(where: { $0 > i && undecided($0) }) { return j }
        return assets.indices.first(where: undecided) ?? assets.count
    }

}
