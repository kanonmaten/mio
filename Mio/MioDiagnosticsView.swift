import SwiftUI
import UIKit

/// MetricKit reports kept on the phone. A plain native list on the graphite ground.
struct MioDiagnosticsView: View {
    @State private var reports: [MioMetricReport] = []
    @State private var hasLoaded = false
    @State private var tally = MioDirectNoteTally()
    @State private var latency = MioLessonNotesLatencyLog()

    var body: some View {
        List {
            Section {
                LabeledContent("Sparade direkt", value: "\(tally.saved)")
                LabeledContent("Väntade under Förslag", value: "\(tally.waiting)")
                LabeledContent("Ångrade", value: "\(tally.undone)")
                LabeledContent("Nej", value: "\(tally.rejected)")
            } header: {
                Text("Mio, kom ihåg och notera")
            } footer: {
                Text("Bara antal, ingen text. Många Ångra eller Nej kan betyda att Mio hör fraserna fel.")
            }
            Section {
                if let latest = latency.latest {
                    LabeledContent("Senaste lektionen", value: MioLessonNotesLatencyLog.duration(latest.seconds))
                    if let median = latency.medianSeconds, latency.entries.count > 1 {
                        LabeledContent("Mittvärde, \(latency.entries.count) lektioner", value: MioLessonNotesLatencyLog.duration(median))
                    }
                    LabeledContent("Under fem minuter", value: "\(latency.withinGoal) av \(latency.entries.count)")
                } else {
                    Text("Ingen lektion har fått färdiga anteckningar ännu.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Från lektionsslut till färdiga anteckningar")
            } footer: {
                Text("Bara tider, ingen text. Målet är under fem minuter. Tiden räknas från att lektionen avslutades tills sista delen var klar.")
            }
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
        .mioListGround()
        .navigationTitle("Diagnostik")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            tally = MioDirectNoteTally.load(from: .standard)
            latency = MioLessonNotesLatencyLog.load(from: .standard)
            reports = await MioMetricArchive.shared.reports()
            hasLoaded = true
        }
    }
}
