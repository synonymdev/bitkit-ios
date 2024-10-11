//
//  AppViewModel.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/10.
//

import SwiftUI

@MainActor
class AppViewModel: ObservableObject {
    @Published var scannedData: ScannedData?

    @Published var showReceiveSheet = false
    @Published var showSendSheet = false
    @Published var showTabBar = true

    @Published var currentToast: Toast?
}

// MARK: Toast notifications
extension AppViewModel {
    func toast(type: Toast.ToastType, title: String, description: String, autoHide: Bool = true, visibilityTime: Double = 3.0) {
        switch type {
        case .error:
            Haptics.notify(.error)
        case .success:
            Haptics.notify(.success)
        case .info:
            Haptics.play(.heavy)
        case .lightning:
            Haptics.play(.rigid)
        case .warning:
            Haptics.notify(.warning)
        }

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

    func toast(_ error: Error) {
        toast(type: .error, title: "Error", description: error.localizedDescription)
    }

    func hideToast() {
        withAnimation {
            currentToast = nil
        }
    }
}
