import SwiftUI

struct ConnectionClosedSheetItem: SheetItem {
    let id: SheetID = .connectionClosed
    let size: SheetSize = .medium
}

struct ConnectionClosedSheet: View {
    let config: ConnectionClosedSheetItem

    @EnvironmentObject private var sheets: SheetViewModel

    var body: some View {
        Sheet(id: .connectionClosed, data: config) {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: t("lightning__connection_closed__title"))

                BodyMText(
                    t("lightning__connection_closed__description"),
                    textColor: .textSecondary
                )

                Spacer()

                Image("switch")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 256, height: 256)
                    .frame(maxWidth: .infinity)

                Spacer()

                CustomButton(title: t("common__ok")) {
                    sheets.hideSheet()
                }
                .accessibilityIdentifier("ConnectionClosedButton")
            }
            .padding(.horizontal, 16)
        }
    }
}

#Preview {
    VStack {}
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gray6)
        .sheet(
            isPresented: .constant(true),
            content: {
                ConnectionClosedSheet(config: ConnectionClosedSheetItem())
                    .environmentObject(SheetViewModel())
            }
        )
        .presentationDetents([.height(UIScreen.screenHeight - 120)])
        .preferredColorScheme(.dark)
}
