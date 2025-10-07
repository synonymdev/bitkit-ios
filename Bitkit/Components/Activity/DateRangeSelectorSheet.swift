
import SwiftUI

// MARK: - DateRangeSelectorSheet

struct DateRangeSelectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ActivityListViewModel

    @State private var selectedStartDate: Date?
    @State private var selectedEndDate: Date?
    @State private var isSelectingStart = true

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
                // Selection indicators
                HStack(spacing: 12) {
                    DateSelectionButton(
                        title: t("wallet__filter_start_date"),
                        date: selectedStartDate,
                        isSelected: isSelectingStart,
                        action: { isSelectingStart = true }
                    )

                    DateSelectionButton(
                        title: t("wallet__filter_end_date"),
                        date: selectedEndDate,
                        isSelected: !isSelectingStart,
                        action: { isSelectingStart = false }
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)

                // Calendar
                DatePicker(
                    "",
                    selection: Binding(
                        get: {
                            if isSelectingStart {
                                return selectedStartDate ?? Date()
                            } else {
                                return selectedEndDate ?? Date()
                            }
                        },
                        set: { newDate in
                            if isSelectingStart {
                                selectedStartDate = newDate
                                if selectedEndDate == nil || newDate > selectedEndDate! {
                                    selectedEndDate = newDate
                                }
                                isSelectingStart = false
                            } else {
                                if let start = selectedStartDate, newDate < start {
                                    selectedEndDate = start
                                    selectedStartDate = newDate
                                } else {
                                    selectedEndDate = newDate
                                }
                            }
                        }
                    ),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .tint(.brandAccent)
                .padding(.horizontal, 16)
            }

            Spacer()

            // Action buttons
            HStack(spacing: 16) {
                Button(action: {
                    selectedStartDate = nil
                    selectedEndDate = nil
                    viewModel.clearDateRange()
                    dismiss()
                }) {
                    Text(t("wallet__filter_clear"))
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .foregroundColor(hasSelection ? .primary : .secondary)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(hasSelection ? Color.primary.opacity(0.3) : Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                }
                .disabled(!hasSelection)
                .accessibilityIdentifier("CalendarClearButton")

                Button(action: {
                    viewModel.startDate = selectedStartDate
                    viewModel.endDate = selectedEndDate
                    dismiss()
                }) {
                    Text(t("wallet__filter_apply"))
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .foregroundColor(.white)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(hasSelection ? Color.brandAccent : Color.gray.opacity(0.3))
                        )
                }
                .disabled(!hasSelection)
                .accessibilityIdentifier("CalendarApplyButton")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.95, blue: 0.97),
                    Color.white,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .presentationDetents([.height(600)])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - DateSelectionButton

struct DateSelectionButton: View {
    let title: String
    let date: Date?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Text(date?.formatted(date: .abbreviated, time: .omitted) ?? t("wallet__filter_select_date"))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(date == nil ? .secondary : .primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.brandAccent.opacity(0.1) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.brandAccent : Color.clear, lineWidth: 2)
            )
        }
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
