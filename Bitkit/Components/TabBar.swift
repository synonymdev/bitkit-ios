//
//  TabBar.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import SwiftUI

struct TabBar: View {
    @EnvironmentObject var app: AppViewModel

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button(action: {
                    app.showSendSheet = true
                    Haptics.play(.openSheet)
                }, label: {
                    Text("Send")
                })
                Spacer()

                NavigationLink(destination: ScannerView()) {
                    Image(systemName: "viewfinder")
                        .resizable()
                        .frame(width: 30, height: 30)
                        .padding()
                }
                Spacer()

                Button(action: {
                    app.showReceiveSheet = true
                    Haptics.play(.openSheet)
                }, label: {
                    Text("Receive")
                })

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
            .environmentObject(AppViewModel())
    }
}
