//
//  SendOptionsView.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/08/23.
//

import SwiftUI

struct SendOptionsView: View {
    @Environment(\.toast) private var toast

    var body: some View {
        VStack {
            Text("Send")

            Spacer()

            Button("Paste") {
                // TODO: handle proper sending flow and decode multiple strings
                Task {
                    do {
                        if let invoice = UIPasteboard.general.string {
                            let _ = try await LightningService.shared.send(bolt11: invoice)
                        }
                    } catch {
                        toast.show(error)
                    }
                }
            }

            Spacer()
        }
    }
}

#Preview {
    SendOptionsView()
}
