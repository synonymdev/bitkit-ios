import SwiftUI

// TODO: add error message and retry button

struct SendFailure: View {
    @EnvironmentObject var sheets: SheetViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                VStack(alignment: .leading, spacing: 0) {
                    SheetHeader(title: t("wallet__send_error_tx_failed"), showBackButton: false)

                    Spacer()

                    Image("cross")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 256, height: 256)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Spacer()

                    HStack(spacing: 16) {
                        CustomButton(title: t("common__close")) {
                            sheets.hideSheet()
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .navigationBarHidden(true)
            .sheetBackground()
        }
    }
}
