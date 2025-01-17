//
//  Toast.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/10.
//

import Foundation

struct Toast: Equatable {
    enum ToastType {
        case success, info, lightning, warning, error
    }

    let type: ToastType
    let title: String
    let description: String?
    let autoHide: Bool
    let visibilityTime: Double
}
