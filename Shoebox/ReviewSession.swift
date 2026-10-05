import Photos

/// One month under review. Choices are saved as they're made; nothing is
/// deleted until `deleteMarked()` runs from the summary screen.
@MainActor @Observable
final class ReviewSession {
    let month: MonthKey
    let assets: [PHAsset]
    private(set) var index: Int = 0
    private(set) var decisions: [String: Decision] = [:]
    private(set) var markedBytes: Int64 = 0
    private var history: [Int] = []
    private var sizeCache: [String: Int64] = [:]
    private let store: ProgressStore

    init(month: MonthKey, store: ProgressStore) {
        self.month = month
        self.store = store
        assets = MediaFilter.fetchAssets(in: month)

        // Resume earlier choices that still match items in this month.
        let saved = store.progress(for: month).decisions
        for (i, asset) in assets.enumerated() {
            if let d = saved[asset.localIdentifier] {
                decisions[asset.localIdentifier] = d
                history.append(i)
            }
        }
        index = nextUndecided(after: -1)
        recomputeMarkedBytes()
    }

    var current: PHAsset? { index < assets.count ? assets[index] : nil }
    var isComplete: Bool { current == nil }
    var decidedCount: Int { decisions.count }
    var remaining: Int { assets.count - decidedCount }
    var canUndo: Bool { !history.isEmpty }

    var markedAssets: [PHAsset] { assets.filter { decisions[$0.localIdentifier] == .toss } }
    var markedCount: Int { decisions.values.filter { $0 == .toss }.count }
    var keptCount: Int { decisions.values.filter { $0 == .keep }.count }

    func decide(_ decision: Decision) {
        guard let asset = current else { return }
        let id = asset.localIdentifier
        decisions[id] = decision
        history.append(index)
        if decision == .toss { markedBytes += size(of: asset) }
        store.setDecision(decision, id: id, month: month)
        index = nextUndecided(after: index)
    }

    func undo() {
        guard let i = history.popLast() else { return }
        let asset = assets[i]
        let id = asset.localIdentifier
        if decisions[id] == .toss { markedBytes -= size(of: asset) }
        decisions[id] = nil
        store.setDecision(nil, id: id, month: month)
        index = i
    }

    /// Used from the summary grid to rescue an item before confirming.
    func keepInstead(_ asset: PHAsset) {
        let id = asset.localIdentifier
        guard decisions[id] == .toss else { return }
        decisions[id] = .keep
        markedBytes -= size(of: asset)
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

    func size(of asset: PHAsset) -> Int64 {
        if let cached = sizeCache[asset.localIdentifier] { return cached }
        let s = Self.fileSize(of: asset)
        sizeCache[asset.localIdentifier] = s
        return s
    }

    func filename(of asset: PHAsset) -> String? {
        PHAssetResource.assetResources(for: asset).first?.originalFilename
    }

    /// Sum of every stored resource (original, Live Photo video, edits).
    nonisolated static func fileSize(of asset: PHAsset) -> Int64 {
        PHAssetResource.assetResources(for: asset).reduce(Int64(0)) { total, resource in
            guard resource.responds(to: Selector(("fileSize"))),
                  let n = resource.value(forKey: "fileSize") as? NSNumber else { return total }
            return total + n.int64Value
        }
    }

    private func nextUndecided(after i: Int) -> Int {
        let undecided = { (j: Int) in self.decisions[self.assets[j].localIdentifier] == nil }
        if let j = assets.indices.first(where: { $0 > i && undecided($0) }) { return j }
        return assets.indices.first(where: undecided) ?? assets.count
    }

    private func recomputeMarkedBytes() {
        let marked = markedAssets
        guard !marked.isEmpty else { return }
        Task { [weak self] in
            let sizes = await Task.detached(priority: .utility) { () -> [String: Int64] in
                var sizes: [String: Int64] = [:]
                for a in marked { sizes[a.localIdentifier] = ReviewSession.fileSize(of: a) }
                return sizes
            }.value
            guard let self else { return }
            self.sizeCache.merge(sizes) { a, _ in a }
            self.markedBytes = self.markedAssets.reduce(0) { $0 + self.size(of: $1) }
        }
    }
}
