import SwiftUI

// MARK: - DateRangeSelectorSheet

struct DateRangeSelectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendar) var calendar
    @ObservedObject var viewModel: ActivityListViewModel

    @State private var selectedDates: Set<DateComponents> = []
    @State private var startDate: Date?
    @State private var endDate: Date?

    let datePickerComponents: Set<Calendar.Component> = [.calendar, .era, .year, .month, .day]

    init(viewModel: ActivityListViewModel) {
        self.viewModel = viewModel

        // Initialize with current date range if exists
        var initialDates: Set<DateComponents> = []
        if let start = viewModel.startDate, let end = viewModel.endDate {
            let calendar = Calendar.current
            var currentDate = calendar.startOfDay(for: start)
            let endOfDay = calendar.startOfDay(for: end)

            while currentDate <= endOfDay {
                if let components = calendar.dateComponents(datePickerComponents, from: currentDate) as DateComponents? {
                    initialDates.insert(components)
                }
                currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
            }
        }

        _selectedDates = State(initialValue: initialDates)
        _startDate = State(initialValue: viewModel.startDate)
        _endDate = State(initialValue: viewModel.endDate)
    }

    private var hasSelection: Bool {
        startDate != nil && endDate != nil
    }

    private var datesBinding: Binding<Set<DateComponents>> {
        Binding {
            selectedDates
        } set: { newValue in
            if newValue.isEmpty {
                selectedDates = newValue
                startDate = nil
                endDate = nil
            } else if newValue.count > selectedDates.count {
                // Date was added
                if newValue.count == 1 {
                    // First date selected - set as start
                    selectedDates = newValue
                    if let components = newValue.first,
                       let date = calendar.date(from: components)
                    {
                        startDate = date
                        endDate = nil
                    }
                } else if newValue.count == 2 {
                    // Second date selected - fill the range
                    selectedDates = filledRange(selectedDates: newValue)
                    updateStartEndDates()
                } else if let firstMissingDate = newValue.subtracting(selectedDates).first {
                    // Additional date tapped - start new range
                    selectedDates = [firstMissingDate]
                    if let date = calendar.date(from: firstMissingDate) {
                        startDate = date
                        endDate = nil
                    }
                }
            } else if let firstMissingDate = selectedDates.subtracting(newValue).first {
                // Date was removed - start new range from this date
                selectedDates = [firstMissingDate]
                if let date = calendar.date(from: firstMissingDate) {
                    startDate = date
                    endDate = nil
                }
            } else {
                selectedDates = []
                startDate = nil
                endDate = nil
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Date Range Picker
            VStack(alignment: .leading, spacing: 16) {
                // Calendar
                MultiDatePicker("", selection: datesBinding)
                    .datePickerStyle(.graphical)
                    .tint(.brandAccent)
                    .padding(.horizontal, 16)
                    .padding(.top, 20)

                // Display selected range
                if let start = startDate {
                    HStack {
                        if let end = endDate {
                            Text(
                                "\(start.formatted(.dateTime.month(.abbreviated).day().year())) - \(end.formatted(.dateTime.month(.abbreviated).day().year()))"
                            )
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.textPrimary)
                        } else {
                            Text(start.formatted(.dateTime.month(.abbreviated).day().year()))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.textPrimary)
                            Text(" - ")
                                .font(.system(size: 14))
                                .foregroundColor(.white32)
                            Text(t("wallet__filter_select_end_date"))
                                .font(.system(size: 14))
                                .foregroundColor(.white32)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)
                    .background(Color.white08)
                    .cornerRadius(8)
                    .padding(.horizontal, 16)
                }
            }

            Spacer()

            // Action buttons
            HStack(spacing: 16) {
                CustomButton(
                    title: t("wallet__filter_clear"),
                    variant: .secondary,
                    isDisabled: !hasSelection
                ) {
                    selectedDates = []
                    startDate = nil
                    endDate = nil
                    viewModel.clearDateRange()
                    dismiss()
                }
                .accessibilityIdentifier("CalendarClearButton")

                CustomButton(
                    title: t("wallet__filter_apply"),
                    variant: .primary,
                    isDisabled: !hasSelection
                ) {
                    viewModel.startDate = startDate
                    viewModel.endDate = endDate
                    dismiss()
                }
                .accessibilityIdentifier("CalendarApplyButton")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .sheetBackground()
        .presentationDetents([.height(600)])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Helper Methods

    private func filledRange(selectedDates: Set<DateComponents>) -> Set<DateComponents> {
        let allDates = selectedDates.compactMap { calendar.date(from: $0) }
        guard allDates.count == 2,
              let startDate = allDates.min(),
              let endDate = allDates.max()
        else {
            return selectedDates
        }

        var dateRange: Set<DateComponents> = []
        var currentDate = startDate

        while currentDate <= endDate {
            if let components = calendar.dateComponents(datePickerComponents, from: currentDate) as DateComponents? {
                dateRange.insert(components)
            }
            guard let nextDate = calendar.date(byAdding: .day, value: 1, to: currentDate) else {
                break
            }
            currentDate = nextDate
        }

        return dateRange
    }

    private func updateStartEndDates() {
        let allDates = selectedDates.compactMap { calendar.date(from: $0) }
        startDate = allDates.min()
        endDate = allDates.max()
    }
}

#Preview("Empty State") {
    DateRangeSelectorSheet(viewModel: ActivityListViewModel())
}

#Preview("With Selection") {
    let viewModel = ActivityListViewModel()
    viewModel.startDate = Calendar.current.date(byAdding: .day, value: -7, to: Date())
    viewModel.endDate = Date()
    return DateRangeSelectorSheet(viewModel: viewModel)
}
