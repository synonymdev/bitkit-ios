import SwiftUI

// MARK: - DateRangeSelectorSheet

struct DateRangeSelectorSheet: View {
    @Environment(\.calendar) var calendar
    @ObservedObject var viewModel: ActivityListViewModel
    @Binding var isPresented: Bool

    @State private var selectedDates: Set<DateComponents> = []
    @State private var startDate: Date?
    @State private var endDate: Date?

    let datePickerComponents: Set<Calendar.Component> = [.calendar, .era, .year, .month, .day]

    init(viewModel: ActivityListViewModel, isPresented: Binding<Bool>) {
        self.viewModel = viewModel
        _isPresented = isPresented

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
        Sheet(id: .dateRangeSelector, data: nil) {
            VStack(spacing: 0) {
                BodyMBoldText(t("wallet__filter_title"), textColor: .white)
                    .padding(.top, 32)

                // Date Range Picker
                VStack(alignment: .leading, spacing: 16) {
                    // Calendar
                    MultiDatePicker("", selection: datesBinding)
                        .datePickerStyle(.graphical)
                        .tint(.brandAccent)
                        .padding(.horizontal, 16)
                        .padding(.top, 26)

                    // Display selected range
                    if let start = startDate {
                        HStack {
                            if let end = endDate {
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
                        .padding(.bottom, 36)
                        .padding(.horizontal, 16)
                        .transition(.asymmetric(
                            insertion: .scale.combined(with: .opacity),
                            removal: .scale.combined(with: .opacity)
                        ))
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: startDate)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: endDate)
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
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Helper Methods

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

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
    DateRangeSelectorSheet(viewModel: ActivityListViewModel(), isPresented: .constant(true))
}

#Preview("With Selection") {
    let viewModel = ActivityListViewModel()
    viewModel.startDate = Calendar.current.date(byAdding: .day, value: -7, to: Date())
    viewModel.endDate = Date()
    return DateRangeSelectorSheet(viewModel: viewModel, isPresented: .constant(true))
}
