import SwiftUI

struct TrezorAccountTypeSelector: View {
    @Binding var selection: TrezorAccountTypeSelection
    var title: String = "Account Type"

    private let columns = [
        GridItem(.adaptive(minimum: 92), spacing: 8),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.6))

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(TrezorAccountTypeSelection.allCases) { option in
                    Button {
                        selection = option
                    } label: {
                        VStack(spacing: 2) {
                            Text(option.title)
                                .font(.system(size: 12, weight: .semibold))
                            Text(option.subtitle)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(option == selection ? .white.opacity(0.7) : .white.opacity(0.4))
                        }
                        .foregroundColor(option == selection ? .white : .white.opacity(0.65))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(option == selection ? Color.white.opacity(0.18) : Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("TrezorAccountType-\(option.rawValue)")
                }
            }
        }
    }
}
