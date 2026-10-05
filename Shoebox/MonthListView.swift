import Photos
import SwiftUI

struct MonthListView: View {
    @Environment(PhotoLibrary.self) private var library
    @Environment(ProgressStore.self) private var store
    let onOpen: (MonthKey) -> Void

    private var years: [(year: Int, months: [MonthSummary])] {
        Dictionary(grouping: library.months, by: \.key.year)
            .map { ($0.key, $0.value.sorted { $0.key < $1.key }) }
            .sorted { $0.0 > $1.0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if !library.driveConnected { DriveBanner() }
                if library.isIndexing && library.months.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Counting your library…").foregroundStyle(Theme.muted)
                    }
                    .padding(.top, 40)
                    .frame(maxWidth: .infinity)
                }
                ForEach(years, id: \.year) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(String(group.year))
                            .font(Theme.display(26))
                            .foregroundStyle(Theme.ink)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 240), spacing: 14)], spacing: 14) {
                            ForEach(group.months) { m in
                                MonthTile(summary: m, progress: store.progress(for: m.key)) { onOpen(m.key) }
                                    .disabled(!library.driveConnected)
                            }
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

    private var header: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Shoebox").font(Theme.display(44, weight: .bold)).foregroundStyle(Theme.ink)
                Text("Pick a month. → keeps, ← tosses. Nothing is deleted until you confirm.")
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
            asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        }
    }
}

private struct MonthTile: View {
    let summary: MonthSummary
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
                    .opacity(finished ? 0.6 : 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.key.monthName)
                        .font(Theme.display(17))
                        .foregroundStyle(Theme.ink)
                    Text(detail)
                        .font(Theme.label(11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                    if inProgress {
                        ProgressView(value: Double(progress.decisions.count), total: Double(max(summary.total, 1)))
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
                .stroke(hovering ? Theme.amber.opacity(0.7) : Theme.line, lineWidth: 1))
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var cover: some View {
        CoverImage(id: summary.coverID)
    }

    @ViewBuilder private var badge: some View {
        if finished {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.bg)
                .padding(6)
                .background(Circle().fill(Theme.keep))
        } else if inProgress {
            Text("\(Int(Double(progress.decisions.count) / Double(max(summary.total, 1)) * 100))%")
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
        var parts = ["\(summary.photos) photo\(summary.photos == 1 ? "" : "s")"]
        if summary.videos > 0 { parts.append("\(summary.videos) video\(summary.videos == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}
