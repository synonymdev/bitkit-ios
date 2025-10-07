
import SwiftUI

// MARK: - DateRangeSelectorSheet

struct DateRangeSelectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ActivityListViewModel

    @State private var selectedStartDate: Date?
    @State private var selectedEndDate: Date?

    init(viewModel: ActivityListViewModel) {
        self.viewModel = viewModel
        _selectedStartDate = State(initialValue: viewModel.startDate)
        _selectedEndDate = State(initialValue: viewModel.endDate)
    }

    private var hasSelection: Bool {
        selectedStartDate != nil && selectedEndDate != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Date Range Picker
            VStack(alignment: .leading, spacing: 16) {
                // Calendar
                DatePicker(
                    "",
                    selection: Binding(
                        get: {
                            // Default to current start date, or today if none selected
                            return selectedStartDate ?? Date()
                        },
                        set: { newDate in
                            if selectedStartDate == nil {
                                // First selection - set as start date
                                selectedStartDate = newDate
                            } else if selectedEndDate == nil {
                                // Second selection - set as end date
                                if newDate < selectedStartDate! {
                                    // If new date is before start, swap them
                                    selectedEndDate = selectedStartDate
                                    selectedStartDate = newDate
                                } else {
                                    selectedEndDate = newDate
                                }
                            } else {
                                // Both dates selected - reset and start over
                                selectedStartDate = newDate
                                selectedEndDate = nil
                            }
                        }
                    ),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .tint(.brandAccent)
                .padding(.horizontal, 16)
                .padding(.top, 20)

                // Display selected range
                if let start = selectedStartDate {
                    HStack {
                        if let end = selectedEndDate {
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
                    selectedStartDate = nil
                    selectedEndDate = nil
                    viewModel.clearDateRange()
                    dismiss()
                }
                .accessibilityIdentifier("CalendarClearButton")

                CustomButton(
                    title: t("wallet__filter_apply"),
                    variant: .primary,
                    isDisabled: !hasSelection
                ) {
                    viewModel.startDate = selectedStartDate
                    viewModel.endDate = selectedEndDate
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
