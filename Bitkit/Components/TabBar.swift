//
//  TabBar.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import SwiftUI

struct TabBar: View {
    @State private var showReceiveNavigation = false
    @State private var showSendNavigation = false

    @EnvironmentObject var toast: ToastViewModel

    private let sheetHeight = UIScreen.screenHeight - 200

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button(action: {
                    showSendNavigation = true
                }, label: {
                    Text("Send")
                })
                Spacer()

                NavigationLink(destination: scanner) {
                    Image(systemName: "viewfinder")
                        .resizable()
                        .frame(width: 30, height: 30)
                        .padding()
                }
                Spacer()

                Button(action: {
                    showReceiveNavigation = true
                }, label: {
                    Text("Receive")
                })

                Spacer()
            }
            .background(.regularMaterial)
            .cornerRadius(30)
            .padding()
        }
        .sheet(isPresented: $showSendNavigation, content: {
            if #available(iOS 16.0, *) {
                SendOptionsView()
                    .presentationDetents([.height(sheetHeight)])
            } else {
                SendOptionsView() // Will just consume full screen
            }
        })
        .sheet(isPresented: $showReceiveNavigation, content: {
            if #available(iOS 16.0, *) {
                ReceiveQR()
                    .presentationDetents([.height(sheetHeight)])
            } else {
                ReceiveQR() // Will just consume full screen
            }
        })
    }

    var scanner: some View {
        ScannerView { scannedData, error in
            if let error {
                toast.show(error)
                return
            }

            if let scannedData {
                Logger.test(scannedData)
            }
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
