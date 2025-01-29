import SwiftUI

struct TagSelector: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: ActivityListViewModel
    
    var body: some View {
        NavigationView {
            VStack {
                if viewModel.availableTags.isEmpty {
                    Text("No tags found")
                        .foregroundColor(.gray)
                        .padding()
                } else {
                    List {
                        ForEach(viewModel.availableTags, id: \.self) { tag in
                            Button(action: {
                                if viewModel.selectedTags.contains(tag) {
                                    viewModel.selectedTags.remove(tag)
                                } else {
                                    viewModel.selectedTags.insert(tag)
                                }
                            }) {
                                HStack {
                                    Text(tag)
                                    Spacer()
                                    if viewModel.selectedTags.contains(tag) {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.brandAccent)
                                    }
                                }
                            }
                        }
                    }
                }
                
                Spacer()
                // Bottom buttons
                HStack {
                    Spacer()
                    Button("Clear") {
                        viewModel.clearTags()
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
            .navigationTitle("Select Tags")
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