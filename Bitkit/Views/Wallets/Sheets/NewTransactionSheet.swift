//
//  NewTransactionSheet.swift
//  Bitkit
//
//  Created by Jason van den Berg on 2024/10/17.
//

import SwiftUI

struct NewTransactionSheet: View {
    @Binding var details: NewTransactionSheetDetails

    @EnvironmentObject private var app: AppViewModel

    @State private var offsetY: CGFloat = 0
    @State private var rotate: CGFloat = 0

    var body: some View {
        VStack {
            VStack {
                if details.type == .lightning {
                    if details.direction == .sent {
                        Text("Sent Instant Bitcoin")
                    } else {
                        Text("Received Instant Bitcoin")
                    }
                } else {
                    if details.direction == .sent {
                        Text("Sent Bitcoin")
                    } else {
                        Text("Received Bitcoin")
                    }
                }

                VStack(alignment: .leading) {
                    Text("\(details.sats) sats")
                        .font(.title)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top)
            }
            .padding()

            Spacer()

            Text("confetti")
                .rotationEffect(.degrees(rotate))
                .offset(y: offsetY)

            Spacer()

            Button("Close") {
                app.showNewTransaction = false
            }
        }
        .onAppear {
            withAnimation(Animation.easeInOut(duration: 10).repeatForever(autoreverses: true)) {
                offsetY = 100
            }

            withAnimation(Animation.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
                rotate = 360
            }
        }
    }
}

#Preview {
    NewTransactionSheet(details: .constant(NewTransactionSheetDetails(type: .lightning, direction: .sent, sats: 1000)))
        .environmentObject(AppViewModel())
        .preferredColorScheme(.dark)
}
