//
//  TabBar.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import SwiftUI

struct TabBar: View {
    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Label("Send", image: "arrow.up.arrow.down")
                Spacer()

                // Scan QR
                Image(systemName: "qrcode.viewfinder")
                    .resizable()
                    .frame(width: 30, height: 30)
                    .padding()
                    .onTapGesture {
                        Logger.info("Scan QR")
                    }
                Spacer()
                Label("Receive", image: "arrow.down.arrow.up")
                Spacer()
            }
            .background(.regularMaterial)
            .cornerRadius(30)
            .padding()
        }
    }
}

#Preview {
    VStack {
        Text("Hello, World!")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay {
        TabBar()
    }
}
