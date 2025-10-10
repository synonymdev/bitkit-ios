import SwiftUI

// MARK: - DateRangeSelectorSheetItem

struct DateRangeSelectorSheetItem: SheetItem {
    let id: SheetID = .dateRangeSelector
    let size: SheetSize = .medium
}

// MARK: - DateRangeSelectorSheet

struct DateRangeSelectorSheet: View {
    @EnvironmentObject private var sheets: SheetViewModel
    @Environment(\.calendar) var calendar
    @ObservedObject var viewModel: ActivityListViewModel
    @Binding var isPresented: Bool

    @State private var displayedMonth: Date
    @State private var startDate: Date?
    @State private var endDate: Date?

    init(viewModel: ActivityListViewModel, isPresented: Binding<Bool>) {
        self.viewModel = viewModel
        _isPresented = isPresented

        // Initialize displayed month to the selected start date or current date
        let initialMonth = viewModel.startDate ?? Date()
        _displayedMonth = State(initialValue: initialMonth)
        _startDate = State(initialValue: viewModel.startDate)
        _endDate = State(initialValue: viewModel.endDate)
    }

    private var hasSelection: Bool {
        startDate != nil
    }

    private var monthYearString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: displayedMonth)
    }

    private var daysInMonth: [Date?] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth),
              let monthFirstWeek = calendar.dateInterval(of: .weekOfMonth, for: monthInterval.start)
        else {
            return []
        }

        var days: [Date?] = []
        var currentDate = monthFirstWeek.start

        while days.count < 42 { // 6 weeks max
            if calendar.isDate(currentDate, equalTo: displayedMonth, toGranularity: .month) {
                days.append(currentDate)
            } else {
                days.append(nil)
            }

            guard let nextDate = calendar.date(byAdding: .day, value: 1, to: currentDate) else {
                break
            }
            currentDate = nextDate
        }

        return days
    }

    var body: some View {
        Sheet(id: .dateRangeSelector, data: DateRangeSelectorSheetItem()) {
            VStack(spacing: 0) {
                SheetHeader(title: t("wallet__filter_title"))

                VStack(alignment: .leading, spacing: 16) {
                    // Month navigation
                    HStack {
                        Text(monthYearString)
                            .font(.custom(Fonts.semiBold, size: 17))
                            .foregroundColor(.white)
                        Spacer()

                        Button(action: previousMonth) {
                            Image(systemName: "chevron.left")
                                .foregroundColor(.brandAccent)
                                .frame(width: 44, height: 44)
                        }
                        .padding(.leading, 8)
                        .accessibilityIdentifier("PrevMonth")

                        Button(action: nextMonth) {
                            Image(systemName: "chevron.right")
                                .foregroundColor(.brandAccent)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityIdentifier("NextMonth")
                    }
                    .padding(.horizontal, 16)

                    // Weekday headers
                    HStack(spacing: 0) {
                        ForEach(calendar.shortWeekdaySymbols, id: \.self) { symbol in
                            CaptionText(symbol.uppercased())
                                .foregroundColor(.white64)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 16)

                    // Calendar grid
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 8) {
                        ForEach(Array(daysInMonth.enumerated()), id: \.offset) { _, date in
                            if let date {
                                CalendarDayView(
                                    date: date,
                                    isSelected: isDateInRange(date),
                                    isStartDate: calendar.isDate(date, inSameDayAs: startDate ?? Date.distantPast),
                                    isEndDate: calendar.isDate(date, inSameDayAs: endDate ?? Date.distantPast),
                                    isToday: calendar.isDateInToday(date)
                                ) {
                                    selectDate(date)
                                }
                                .accessibilityIdentifier(calendar.isDateInToday(date) ? "Today" : "Day-\(calendar.component(.day, from: date))")
                            } else {
                                Color.clear
                                    .frame(height: 40)
                            }
                        }
                    }
                    .padding(.horizontal, 16)

                    // Display selected range (fixed height to prevent layout jump)
                    VStack {
                        if let start = startDate {
                            HStack {
                                if let end = endDate, start != end {
                                    BodyMSBText(
                                        "\(formatDate(start)) - \(formatDate(end))"
                                    )
                                    .id("\(formatDate(start))-\(formatDate(end))")
                                } else {
                                    BodyMSBText(formatDate(start))
                                        .id(formatDate(start))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .transition(.asymmetric(
                                insertion: .scale.combined(with: .opacity),
                                removal: .scale.combined(with: .opacity)
                            ))
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: startDate)
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: endDate)
                        } else {
                            // Placeholder to maintain height
                            BodyMSBText(" ")
                                .opacity(0)
                        }
                    }
                    .frame(height: 24)
                    .padding(.bottom, 36)
                    .padding(.horizontal, 16)
                }

                Spacer()

                // Action buttons
                HStack(spacing: 16) {
                    CustomButton(
                        title: t("wallet__filter_clear"),
                        variant: .secondary,
                        isDisabled: !hasSelection
                    ) {
                        startDate = nil
                        endDate = nil
                        viewModel.clearDateRange()
                        isPresented = false
                    }
                    .accessibilityIdentifier("CalendarClearButton")

                    CustomButton(
                        title: t("wallet__filter_apply"),
                        variant: .primary,
                        isDisabled: !hasSelection
                    ) {
                        viewModel.startDate = startDate
                        viewModel.endDate = endDate
                        isPresented = false
                    }
                    .accessibilityIdentifier("CalendarApplyButton")
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Helper Methods

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    private func isDateInRange(_ date: Date) -> Bool {
        guard let start = startDate else { return false }
        let end = endDate ?? start

        let normalizedDate = calendar.startOfDay(for: date)
        let normalizedStart = calendar.startOfDay(for: start)
        let normalizedEnd = calendar.startOfDay(for: end)

        return normalizedDate >= normalizedStart && normalizedDate <= normalizedEnd
    }

    private func selectDate(_ date: Date) {
        let normalizedDate = calendar.startOfDay(for: date)

        if startDate == nil {
            // First selection
            startDate = normalizedDate
            endDate = normalizedDate
        } else if let start = startDate, let end = endDate, start == end {
            // Second selection - create range
            let normalizedStart = calendar.startOfDay(for: start)
            if normalizedDate < normalizedStart {
                startDate = normalizedDate
                endDate = normalizedStart
            } else if normalizedDate == normalizedStart {
                // Same date clicked - do nothing or clear
                return
            } else {
                endDate = normalizedDate
            }
        } else {
            // Third selection - start new range
            startDate = normalizedDate
            endDate = normalizedDate
        }
    }

    private func previousMonth() {
        if let newMonth = calendar.date(byAdding: .month, value: -1, to: displayedMonth) {
            displayedMonth = newMonth
        }
    }

    private func nextMonth() {
        if let newMonth = calendar.date(byAdding: .month, value: 1, to: displayedMonth) {
            displayedMonth = newMonth
        }
    }
}

// MARK: - CalendarDayView

struct CalendarDayView: View {
    let date: Date
    let isSelected: Bool
    let isStartDate: Bool
    let isEndDate: Bool
    let isToday: Bool
    let action: () -> Void

    @Environment(\.calendar) var calendar

    private var dayNumber: String {
        String(calendar.component(.day, from: date))
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                // Selection background
                if isSelected {
                    if isStartDate && isEndDate {
                        // Single day or start=end
                        Circle()
                            .fill(Color.brand16)
                    } else if isStartDate {
                        Circle()
                            .fill(Color.brand16)
                    } else if isEndDate {
                        Circle()
                            .fill(Color.brand16)
                    } else {
                        // Middle of range
                        Rectangle()
                            .fill(Color.brandAccent.opacity(0.3))
                    }
                }

                // Day number
                Text(dayNumber)
                    .font(.custom(Fonts.regular, size: 16))
                    .foregroundColor(isStartDate || isEndDate ? Color.brandAccent : Color.white)

                // Today indicator
                if isToday && !isSelected {
                    Circle()
                        .stroke(Color.brandAccent, lineWidth: 1)
                }
            }
        }
        .frame(height: 40)
    }
}

#Preview("Empty State") {
    DateRangeSelectorSheet(viewModel: ActivityListViewModel(), isPresented: .constant(true))
}

#Preview("With Selection") {
    let viewModel = ActivityListViewModel()
    viewModel.startDate = Calendar.current.date(byAdding: .day, value: -7, to: Date())
    viewModel.endDate = Date()
    return DateRangeSelectorSheet(viewModel: viewModel, isPresented: .constant(true))
}
