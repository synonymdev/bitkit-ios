import SwiftUI

struct DateRangeSelector: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: ActivityListViewModel
    @State private var startDate: Date
    @State private var endDate: Date

    init(viewModel: ActivityListViewModel) {
        self.viewModel = viewModel
        // Initialize with current dates or default to today
        _startDate = State(initialValue: viewModel.startDate ?? Calendar.current.startOfDay(for: Date()))
        _endDate = State(initialValue: viewModel.endDate ?? Date())
    }

    private func setDateRange(daysBack: Int) {
        let today = Date()
        let calendar = Calendar.current

        // Set end date to today
        endDate = today

        // Set start date to X days back at start of day
        if let daysBackDate = calendar.date(byAdding: .day, value: -daysBack, to: today) {
            startDate = calendar.startOfDay(for: daysBackDate)
        }
    }

    var body: some View {
        NavigationView {
            VStack {
                Form {
                    Section {
                        DatePicker("Start Date", selection: $startDate, displayedComponents: [.date])
                            .onChange(of: startDate) { newValue in
                                viewModel.startDate = newValue
                            }
                        DatePicker("End Date", selection: $endDate, displayedComponents: [.date])
                            .onChange(of: endDate) { newValue in
                                viewModel.endDate = newValue
                            }
                    }

                    Section {
                        Button("Today") {
                            setDateRange(daysBack: 0)
                            viewModel.startDate = startDate
                            viewModel.endDate = endDate
                            dismiss()
                        }
                        Button("Last 7 days") {
                            setDateRange(daysBack: 7)
                            viewModel.startDate = startDate
                            viewModel.endDate = endDate
                            dismiss()
                        }
                        Button("Last 30 days") {
                            setDateRange(daysBack: 30)
                            viewModel.startDate = startDate
                            viewModel.endDate = endDate
                            dismiss()
                        }
                        Button("Last 90 days") {
                            setDateRange(daysBack: 90)
                            viewModel.startDate = startDate
                            viewModel.endDate = endDate
                            dismiss()
                        }
                        Button("This year") {
                            let calendar = Calendar.current
                            startDate = calendar.date(from: calendar.dateComponents([.year], from: Date())) ?? Date()
                            endDate = Date()
                            viewModel.startDate = startDate
                            viewModel.endDate = endDate
                            dismiss()
                        }
                    } header: {
                        Text("Quick Select")
                    }
                }

                Spacer()

                HStack {
                    Spacer()
                    Button("Clear") {
                        viewModel.clearDateRange()
                        dismiss()
                    }
                    Spacer()
                    Button("Done") {
                        dismiss()
                    }
                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Date Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
}
