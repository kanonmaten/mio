import SwiftUI
import UIKit

/// MetricKit reports kept on the phone. Plain native list; the visual redesign restyles it later.
struct MioDiagnosticsView: View {
    @State private var reports: [MioMetricReport] = []
    @State private var hasLoaded = false

    var body: some View {
        List {
            if hasLoaded && reports.isEmpty {
                ContentUnavailableView("Inga rapporter ännu", systemImage: "waveform.path.ecg",
                    description: Text("iOS skickar mätvärden högst en gång per dygn och krasch- eller hängrapporter när de uppstår."))
            }
            ForEach(reports) { report in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(report.kind.title).font(.headline)
                        Spacer()
                        Text(report.receivedAt, format: .dateTime.day().month().hour().minute())
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(report.summary).font(.subheadline)
                    HStack(spacing: 20) {
                        ShareLink(item: report.shareText) { Label("Dela", systemImage: "square.and.arrow.up") }
                        Button { UIPasteboard.general.string = report.shareText } label: {
                            Label("Kopiera", systemImage: "doc.on.doc")
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.subheadline)
                }
                .padding(.vertical, 4)
            }
            Section {
                Text("Rapporterna kommer från iOS (MetricKit) och innehåller tider, minne, CPU, disk och anropsstackar, aldrig text från Mio. De sparas högst 30 dagar på telefonen och ingår i exporten. Diagnostik per session finns under Lektioner → Historik och råtext.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Diagnostik")
        .task {
            reports = await MioMetricArchive.shared.reports()
            hasLoaded = true
        }
    }
}
