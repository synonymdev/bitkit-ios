import SwiftUI

private struct SettingsLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        CaptionMText(text)
            .frame(height: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum BackupStatus {
    case running
    case required(Int)
    case synced(Int)
}

private struct StatusItemView: View {
    let imageName: String
    let title: String
    let status: BackupStatus

    private var statusText: String {
        switch status {
        case .running:
            // return "Running"
            return "Dummy Status"
        case let .required(timestamp):
            // return "Required"
            return "Dummy Status"
        case let .synced(timestamp):
            // return "Synced"
            return "Dummy Status"
        }
    }

    private var iconBackgroundColor: Color {
        switch status {
        case .running:
            return .yellow16
        case .required:
            return .red16
        case .synced:
            return .green16
        }
    }

    private var iconColor: Color {
        switch status {
        case .running:
            return .yellowAccent
        case .required:
            return .redAccent
        case .synced:
            return .greenAccent
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            CircularIcon(
                icon: imageName,
                iconColor: iconColor,
                backgroundColor: iconBackgroundColor,
                size: 32
            )

            VStack(alignment: .leading, spacing: 0) {
                BodyMSBText(title)
                CaptionBText(statusText)
            }

            Spacer()

            if case .required = status {
                IconButton(icon: Image("arrows-clockwise"), size: 40) {
                    // TODO: Implement retry backup
                }
            }
        }
        // .listRowBackground(Color.black)
        .listRowSeparator(.visible, edges: .bottom)
        .listRowSeparatorTint(Color.white10)
        .frame(height: 56)
    }
}

struct BackupSettings: View {
    @EnvironmentObject var sheets: SheetViewModel

    var body: some View {
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Button(action: {
                        sheets.showSheet(.backup, data: BackupConfig(view: .mnemonic))
                    }) {
                        SettingsListLabel(title: t("settings__backup__wallet"))
                    }

                    NavigationLink(value: Route.resetAndRestore) {
                        SettingsListLabel(title: t("settings__backup__reset"))
                    }

                    SettingsLabel(t("settings__backup__latest"))
                        .padding(.top, 16)

                    StatusItemView(
                        imageName: "bolt-hollow",
                        title: t("settings__backup__category_connections"),
                        status: .required(1_718_281_828)
                    )
                    StatusItemView(
                        imageName: "note",
                        title: t("settings__backup__category_connection_receipts"),
                        status: .synced(1_718_281_828)
                    )
                    StatusItemView(
                        imageName: "arrow-up-down",
                        title: t("settings__backup__category_transaction_log"),
                        status: .synced(1_718_281_828)
                    )
                    StatusItemView(
                        imageName: "rewind",
                        title: t("settings__backup__category_wallet"),
                        status: .synced(1_718_281_828)
                    )
                    StatusItemView(
                        imageName: "gear-six",
                        title: t("settings__backup__category_settings"),
                        status: .running
                    )
                    StatusItemView(
                        imageName: "bolt-hollow",
                        title: t("settings__backup__category_widgets"),
                        status: .running
                    )
                    StatusItemView(
                        imageName: "tag",
                        title: t("settings__backup__category_tags"),
                        status: .running
                    )
                    StatusItemView(
                        imageName: "users",
                        title: t("settings__backup__category_contacts"),
                        status: .running
                    )

                    Spacer()
                }
                .frame(minHeight: geometry.size.height)
                .padding(.top, 16)
                .padding(.horizontal, 16)
                .bottomSafeAreaPadding()
            }
        }
        .navigationTitle(t("settings__backup_title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
