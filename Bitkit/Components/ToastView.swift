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
                    Text(toast.description)
                        .font(.subheadline)
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
        case .success: return .green
        case .info: return .blue
        case .lightning: return .purple
        case .warning: return .orange
        case .error: return .red
        }
    }
}

struct ToastModifier: ViewModifier {
    @ObservedObject var viewModel: ToastViewModel

    func body(content: Content) -> some View {
        content
            .overlay(
                ZStack {
                    if let toast = viewModel.currentToast {
                        VStack {
                            ToastView(toast: toast) {
                                withAnimation {
                                    viewModel.hide()
                                }
                            }
                            .padding(.horizontal)
                            .padding(.top)
                            Spacer()
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.4), value: viewModel.currentToast)
            )
    }
}

extension View {
    func toast(viewModel: ToastViewModel) -> some View {
        modifier(ToastModifier(viewModel: viewModel))
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
