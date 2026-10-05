import Photos
import SwiftUI

struct MonthListView: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(ProgressStore.self) private var store
    let onOpen: (MonthKey) -> Void

    @AppStorage("selectedYear") private var savedYear = 0

    private var year: Int? {
        library.years.contains(savedYear) ? savedYear : library.years.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if !library.driveConnected { DriveBanner() }
                LibraryStatus()
                if let year {
                    yearPicker(selected: year)
                    YearProgress(months: library.months(in: year), year: year)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 240), spacing: 14)], spacing: 14) {
                        ForEach(library.months(in: year)) { key in
                            MonthTile(key: key,
                                      summary: library.summaries[key],
                                      isEmpty: library.emptyMonths.contains(key),
                                      counting: library.isCounting(key),
                                      progress: store.progress(for: key)) { onOpen(key) }
                                .disabled(!library.driveConnected || library.emptyMonths.contains(key))
                                .onAppear { library.requestSummary(key) }
                        }
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 44)
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
    }

    private func yearPicker(selected: Int) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(library.years, id: \.self) { y in
                    Button { savedYear = y } label: { Text(String(y)) }
                        .buttonStyle(PillButtonStyle(fill: y == selected ? Theme.amber : Theme.surface,
                                                     text: y == selected ? Theme.bg : Theme.ink))
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Shoebox").font(Theme.display(44, weight: .bold)).foregroundStyle(Theme.ink)
                Text("Pick a year, then a month. → keeps, ← tosses. Nothing is deleted until you confirm.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            HStack(spacing: 22) {
                Stat(value: "\(store.finishedCount)", label: "months done")
                Stat(value: "\(store.totalDeleted)", label: "items tossed")
                Stat(value: Format.bytes(store.totalFreed), label: "freed", accent: true)
            }
        }
    }
}

/// "3 of 10 months counted · 1,234 items" for the year on screen.
private struct YearProgress: View {
    @Environment(PhotoLibrary.self) private var library
    let months: [MonthKey]
    let year: Int

    var body: some View {
        let done = months.filter { library.isCounted($0) }
        let items = done.reduce(0) { $0 + (library.summaries[$1]?.total ?? 0) }
        HStack(spacing: 12) {
            ProgressView(value: Double(done.count), total: Double(max(months.count, 1)))
                .progressViewStyle(.linear)
                .tint(Theme.amber)
                .frame(width: 180)
            Text("\(String(year)): \(done.count) of \(months.count) months counted · \(items.formatted()) items so far")
                .monospacedDigit()
        }
        .font(Theme.label(12))
        .foregroundStyle(Theme.muted)
    }
}

/// What Shoebox is waiting on, how long it's been, and what's been counted so far.
private struct LibraryStatus: View {
    @Environment(PhotoLibrary.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AccessBadge()
                switch library.phase {
                case .working(let what):
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let secs = max(0, Int(ctx.date.timeIntervalSince(library.phaseStarted)))
                        Text(secs >= Config.slowPhotosSeconds
                             ? "\(what)… \(secs)s. Photos is busy, probably syncing. You can open a month anyway."
                             : "\(what)… \(secs)s")
                            .monospacedDigit()
                    }
                case .ready:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.keep)
                    Text("Up to date")
                case .idle:
                    EmptyView()
                }
                Spacer()
                if !library.requireDrive {
                    Button("Using System Photo Library · Require drive again") { library.requireDrive = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.muted)
                }
                if library.monthsCounted > 0 {
                    Text("\(library.itemsCounted.formatted()) items counted in \(library.monthsCounted) month\(library.monthsCounted == 1 ? "" : "s")")
                        .monospacedDigit()
                }
            }
            .font(Theme.label(12))
            .foregroundStyle(Theme.muted)

        }
    }
}

private struct Stat: View {
    let value: String
    let label: String
    var accent = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value).font(Theme.display(22)).foregroundStyle(accent ? Theme.amber : Theme.ink)
            Text(label.uppercased()).font(Theme.label(10, weight: .semibold)).kerning(0.8).foregroundStyle(Theme.muted)
        }
    }
}

private struct CoverImage: View {
    let id: String?
    @State private var asset: PHAsset?

    var body: some View {
        ZStack {
            Theme.raised
            if let asset { AssetThumbnail(asset: asset) }
        }
        .task(id: id) {
            guard let id else { return }
            // Off the main thread so a slow library can't freeze the window.
            asset = await Task.detached(priority: .utility) {
                PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
            }.value
        }
    }
}

private struct MonthTile: View {
    let key: MonthKey
    let summary: MonthSummary?
    let isEmpty: Bool
    let counting: Bool
    let progress: MonthProgress
    let action: () -> Void
    @State private var hovering = false

    private var inProgress: Bool { !progress.decisions.isEmpty }
    private var finished: Bool { progress.finishedAt != nil && !inProgress }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                cover
                    .frame(height: 112)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .overlay(alignment: .topTrailing) { badge.padding(8) }
                    .saturation(finished ? 0.15 : 1)
                    .opacity(finished || isEmpty ? 0.6 : 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text(key.monthName)
                        .font(Theme.display(17))
                        .foregroundStyle(Theme.ink)
                    Text(detail)
                        .font(Theme.label(11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                    if inProgress {
                        ProgressView(value: Double(progress.decisions.count), total: Double(max(summary?.total ?? 1, 1)))
                            .progressViewStyle(.linear)
                            .tint(Theme.amber)
                            .padding(.top, 2)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(hovering && !isEmpty ? Theme.amber.opacity(0.7) : Theme.line, lineWidth: 1))
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var cover: some View {
        CoverImage(id: summary?.coverID)
    }

    @ViewBuilder private var badge: some View {
        if finished {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.bg)
                .padding(6)
                .background(Circle().fill(Theme.keep))
        } else if inProgress {
            Text("\(Int(Double(progress.decisions.count) / Double(max(summary?.total ?? 1, 1)) * 100))%")
                .font(Theme.label(10, weight: .bold))
                .foregroundStyle(Theme.bg)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Theme.amber))
        }
    }

    private var detail: String {
        if finished {
            return progress.freedBytes > 0 ? "Done · freed \(Format.bytes(progress.freedBytes))" : "Done"
        }
        if isEmpty { return "Nothing here" }
        guard let summary else { return counting ? "Counting…" : "Waiting to count…" }
        var parts = ["\(summary.photos) photo\(summary.photos == 1 ? "" : "s")"]
        if summary.videos > 0 { parts.append("\(summary.videos) video\(summary.videos == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}
