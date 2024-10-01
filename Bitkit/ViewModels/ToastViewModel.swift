//
//  ToastViewModel.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/20.
//

import SwiftUI

struct Toast: Equatable {
    enum ToastType {
        case success, info, lightning, warning, error
    }

    let type: ToastType
    let title: String
    let description: String
    let autoHide: Bool
    let visibilityTime: Double
}

@MainActor
class ToastViewModel: ObservableObject {
    @Published var currentToast: Toast?

    func show(type: Toast.ToastType, title: String, description: String, autoHide: Bool = true, visibilityTime: Double = 3.0) {
        Logger.debug("Showing toast: \(title) - \(description)")
        withAnimation {
            currentToast = Toast(type: type, title: title, description: description, autoHide: autoHide, visibilityTime: visibilityTime)
        }

        if autoHide {
            DispatchQueue.main.asyncAfter(deadline: .now() + visibilityTime) {
                withAnimation {
                    self.currentToast = nil
                }
            }
        }
    }

    func show(_ error: Error) {
        show(type: .error, title: "Error", description: error.localizedDescription)
    }

    func hide() {
        withAnimation {
            currentToast = nil
        }
    }
}
