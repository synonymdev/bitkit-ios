import SwiftUI

struct RadioGroup<T: Hashable>: View {
    let options: [RadioOption<T>]
    @Binding var selectedValue: T

    init(options: [RadioOption<T>], selectedValue: Binding<T>) {
        self.options = options
        _selectedValue = selectedValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element.value) { _, option in
                    RadioButton(
                        title: option.title,
                        isSelected: selectedValue == option.value
                    ) {
                        selectedValue = option.value
                    }

                    Divider()
                }
            }
        }
    }
}

struct RadioOption<T: Hashable> {
    let title: String
    let value: T

    init(title: String, value: T) {
        self.title = title
        self.value = value
    }
}

private struct RadioButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                BodyMText(title, textColor: .textPrimary)

                Spacer()

                if isSelected {
                    Image("checkmark")
                        .resizable()
                        .foregroundColor(.brandAccent)
                        .frame(width: 32, height: 32)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 51)
        }
    }
}
