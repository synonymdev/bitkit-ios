//
//  View.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/11.
//

import SwiftUI

extension View {
    func transparentScrolling() -> some View {
        return scrollContentBackground(.hidden)
    }
}
