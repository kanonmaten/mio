import SwiftUI

/// The week-planner world: a violet-tinted ground, plain reading panels on top, one violet
/// tint for controls. Liquid Glass stays on system bars and controls; panels never use it.
enum MioTheme {
    static let ground = Color("MioGround")
    static let surface = Color("MioSurface")
    static let ribbon = Color("MioRibbon")
    /// Named asset, not `Color.accentColor`: the environment's accent resolved to system blue
    /// in the 2026-10-11 simulator build, while this asset is the violet the design needs.
    static let tint = Color("AccentColor")
    static let swedish = Locale(identifier: "sv_SE")
    static let panelRadius: CGFloat = 22
}

extension View {
    /// Tinted ground behind a scroll view.
    func mioGround() -> some View {
        background(MioTheme.ground.ignoresSafeArea())
    }

    /// Tinted ground behind a List or Form; rows keep their plain grouped surface.
    func mioListGround() -> some View {
        scrollContentBackground(.hidden)
            .background(MioTheme.ground.ignoresSafeArea())
    }
}

/// A plain reading panel. No glass, no halo; the ground's tint separates it.
struct MioPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MioTheme.surface, in: RoundedRectangle(cornerRadius: MioTheme.panelRadius, style: .continuous))
    }
}

/// Section heading inside the ground, above a panel.
struct MioSectionTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Week ribbon

/// Seven day cells, Monday first. Today is ringed, the selected day is filled, and three small
/// marks show how much happened that day.
struct MioWeekRibbon: View {
    let week: MioWeekOverview
    let selectedDate: Date
    let calendar: Calendar
    let select: (Date) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            // Two rows keep all seven days, and today's ring, on screen without a hidden scroll.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) { cells }
        } else {
            HStack(spacing: 6) { cells }
        }
    }

    private var cells: some View {
        ForEach(week.days) { day in
            Button { select(day.date) } label: {
                MioDayCell(day: day, isSelected: calendar.isDate(day.date, inSameDayAs: selectedDate))
            }
            .buttonStyle(.plain)
        }
    }
}

private struct MioDayCell: View {
    let day: MioWeekDay
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Text(day.date.formatted(.dateTime.weekday(.narrow).locale(MioTheme.swedish)).uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? MioTheme.tint : Color.secondary)
            Text(day.date.formatted(.dateTime.day().locale(MioTheme.swedish)))
                .font(.title3.weight(day.isToday ? .bold : .medium))
                .fontDesign(.rounded)
                .monospacedDigit()
                .foregroundStyle(day.isFuture ? Color.secondary : Color.primary)
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { mark in
                    Capsule()
                        .fill(mark < day.level ? MioTheme.tint : MioTheme.tint.opacity(0.18))
                        .frame(width: 5, height: 5)
                }
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: 76)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? MioTheme.tint.opacity(0.16) : Color.clear)
        }
        .overlay {
            if day.isToday {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(MioTheme.tint, lineWidth: 2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityText: String {
        var parts = [day.date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(MioTheme.swedish))]
        if day.isToday { parts.append("i dag") }
        if !day.isFuture { parts.append(day.activity == 1 ? "1 sak" : "\(day.activity) saker") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Streak grid

/// Twelve weeks, Monday at the top. Colour depth shows how much happened; nothing is shamed.
struct MioStreakGridView: View {
    let grid: MioStreakGrid

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(grid.activeDays) dagar med Mio")
                    .font(.headline)
                Spacer(minLength: 8)
                if grid.currentRun > 1 {
                    Text("\(grid.currentRun) i rad")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.tint)
                }
            }
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                ForEach(0..<7, id: \.self) { weekday in
                    GridRow {
                        ForEach(grid.weeks.indices, id: \.self) { column in
                            cell(grid.weeks[column][weekday])
                        }
                    }
                }
            }
            HStack {
                if let first = grid.weekNumbers.first { Text("v. \(first)") }
                Spacer()
                if let last = grid.weekNumbers.last { Text("v. \(last)") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func cell(_ day: MioWeekDay) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(fill(for: day))
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if day.isToday {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(MioTheme.tint, lineWidth: 1.5)
                }
            }
    }

    private func fill(for day: MioWeekDay) -> AnyShapeStyle {
        if day.isFuture { return AnyShapeStyle(MioTheme.ribbon.opacity(0.45)) }
        switch day.level {
        case 0: return AnyShapeStyle(MioTheme.ribbon)
        case 1: return AnyShapeStyle(MioTheme.tint.opacity(0.4))
        case 2: return AnyShapeStyle(MioTheme.tint.opacity(0.7))
        default: return AnyShapeStyle(MioTheme.tint)
        }
    }

    private var accessibilityText: String {
        var text = "Senaste 12 veckorna: \(grid.activeDays) dagar med Mio."
        if grid.currentRun > 1 { text += " \(grid.currentRun) dagar i rad." }
        return text
    }
}

// MARK: - Rows

/// One line for a plan or task: kind symbol, title, time, and an optional trailing control.
struct MioItemRow<Trailing: View>: View {
    let item: MioContentItem
    let timeText: String
    let trailing: Trailing

    init(item: MioContentItem, timeText: String, @ViewBuilder trailing: () -> Trailing) {
        self.item = item
        self.timeText = timeText
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: item.kind.symbolName)
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .strikethrough(item.isCompleted)
                    .foregroundStyle(item.isCompleted ? .secondary : .primary)
                Text(timeText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: 44)
    }
}

extension MioItemRow where Trailing == EmptyView {
    init(item: MioContentItem, timeText: String) {
        self.init(item: item, timeText: timeText) { EmptyView() }
    }
}

/// Swedish time phrases for Hem: "kl. 13.40", "i går kl. 9.00", "tis 6 okt".
enum MioTimeText {
    static func describe(_ date: Date, relativeTo now: Date, calendar: Calendar, allDay: Bool = false) -> String {
        if allDay {
            if calendar.isDate(date, inSameDayAs: now) { return "i dag" }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "i går" }
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "i morgon" }
            return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(MioTheme.swedish))
        }
        let time = date.formatted(.dateTime.hour().minute().locale(MioTheme.swedish))
        if calendar.isDate(date, inSameDayAs: now) { return "kl. \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "i går kl. \(time)"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "i morgon kl. \(time)"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(MioTheme.swedish))
    }
}
