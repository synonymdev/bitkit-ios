//
//  ToastView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/20.
//

import SwiftUI

struct ToastView: View {
    let toast: Toast
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(toast.title)
                        .font(.headline)
                    if let description = toast.description {
                        Text(description)
                            .font(.subheadline)
                    }
                }
                Spacer()
                if !toast.autoHide {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .foregroundColor(.white)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.8))
        .foregroundColor(.white)
        .cornerRadius(8)
        .shadow(radius: 4)
    }

    private var color: Color {
        switch toast.type {
        case .success: return .greenAccent
        case .info: return .blueAccent
        case .lightning: return .purpleAccent
        case .warning: return .orange
        case .error: return .redAccent
        }
    }
}

struct ToastModifier: ViewModifier {
    @Binding var toast: Toast?
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay(
                ZStack {
                    if let toast {
                        VStack {
                            ToastView(toast: toast, onDismiss: onDismiss)
                                .padding(.horizontal)
                                .padding(.top)
                            Spacer()
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.4), value: toast)
            )
    }
}

extension View {
    func toastOverlay(toast: Binding<Toast?>, onDismiss: @escaping () -> Void) -> some View {
        modifier(ToastModifier(toast: toast, onDismiss: onDismiss))
    }
}

#Preview {
    ToastView(
        toast: .init(
            type: .info,
            title: "Hey toast",
            description: "This is a toast message",
            autoHide: true,
            visibilityTime: 3.0
        ), onDismiss: {}
    )
}
