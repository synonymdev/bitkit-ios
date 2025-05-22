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

    var body: some View {
        NavigationStack {
            VStack {
                //Values are currently all wrong
                // VStack(alignment: .leading) {
                //     Text("\(details.sats) sats")
                //         .font(.title)
                // }
                // .frame(maxWidth: .infinity, alignment: .leading)
                // .padding(.top)

                Spacer()

                Image("check")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 300, height: 300)

                Spacer()

                CustomButton(title: "Close") {
                    app.showNewTransaction = false
                }
                .padding()
            }
            .sheetBackground()
            .navigationTitle(getTitle())
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func getTitle() -> String {
        if details.type == .lightning {
            return details.direction == .sent ? "Sent Instant Bitcoin" : "Received Instant Bitcoin"
        } else {
            return details.direction == .sent ? "Sent Bitcoin" : "Received Bitcoin"
        }
    }
}

#Preview {
    VStack {}.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.gray6)
        .sheet(
            isPresented: .constant(true),
            content: {
                NewTransactionSheet(details: .constant(NewTransactionSheetDetails(type: .lightning, direction: .sent, sats: 1000)))
                    .environmentObject(AppViewModel())
            }
        )
        .presentationDetents([.height(UIScreen.screenHeight - 120)])
        .preferredColorScheme(.dark)
}
