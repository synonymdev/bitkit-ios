import SwiftUI
import UIKit

struct ToastView: View {
    let toast: Toast
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    BodyMSBText(toast.title, textColor: accentColor)
                    if let description = toast.description {
                        CaptionText(description, textColor: .textPrimary)
                    }
                }
                Spacer()
                if !toast.autoHide {
                    Button(action: onDismiss) {
                        Image("x-mark")
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                // Colored background
                accentColor.opacity(0.7)

                // Black gradient overlay
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.black.opacity(0.6),
                        Color.black,
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        )
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(accentColor, lineWidth: 2)
        )
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
    }

    private var accentColor: Color {
        switch toast.type {
        case .success: return .greenAccent
        case .info: return .blueAccent
        case .lightning: return .purpleAccent
        case .warning: return .brandAccent
        case .error: return .redAccent
        }
    }
}

#Preview {
    ToastView(
        toast: .init(
            type: .info,
            title: "Hey toast",
            description: "This is a toast message",
            autoHide: true,
            visibilityTime: 4.0
        ), onDismiss: {}
    )
    .preferredColorScheme(.dark)
}
