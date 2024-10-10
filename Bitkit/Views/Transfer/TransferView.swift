//
//  TransferView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/09/12.
//

import SwiftUI

struct TransferView: View {
    @State private var sats = ""
    @State private var isCreatingOrder = false
    @State private var newOrder: BtOrder? = nil

    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var blocktank: BlocktankViewModel

    var body: some View {
        Form {
            Section {
                // Input amount
                TextField("Sats", text: $sats)
                    .keyboardType(.numberPad)
            }

            Section {
                Button(isCreatingOrder ? "Creating order..." : "Continue") {
                    Task { @MainActor in
                        guard let spendingBalanceSats = UInt64(sats) else {
                            return
                        }

                        isCreatingOrder = true

                        do {
                            newOrder = try await blocktank.createOrder(spendingBalanceSats: spendingBalanceSats)
                        } catch {
                            app.toast(error)
                        }

                        isCreatingOrder = false
                    }
                }
                .disabled(isCreatingOrder)
            }

            if let order = newOrder {
                NavigationLink(destination: ConfirmOrderView(order: order), isActive: .constant(true)) {
                    EmptyView()
                }
            }
        }
        .navigationTitle("Transfer Funds")
    }
}

#Preview {
    TransferView()
        .environmentObject(AppViewModel())
        .environmentObject(BlocktankViewModel())
}
