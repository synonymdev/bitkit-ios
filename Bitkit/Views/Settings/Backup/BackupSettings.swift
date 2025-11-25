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

private struct StatusItemView: View {
    let imageName: String
    let title: String
    let statusText: String
    let iconColor: Color
    let backgroundColor: Color
    let showRetryButton: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            CircularIcon(
                icon: imageName,
                iconColor: iconColor,
                backgroundColor: backgroundColor,
                size: 32
            )

            VStack(alignment: .leading, spacing: 0) {
                BodyMSBText(title)
                CaptionBText(statusText)
            }

            Spacer()

            if showRetryButton {
                IconButton(icon: Image("arrows-clockwise"), size: 40) {
                    onRetry()
                }
            }
        }
        .listRowSeparator(.visible, edges: .bottom)
        .listRowSeparatorTint(Color.white10)
        .frame(height: 56)
    }
}

struct BackupSettings: View {
    @EnvironmentObject var sheets: SheetViewModel
    @StateObject private var viewModel = BackupViewModel()

    private var allSynced: Bool {
        BackupCategory.allCases.allSatisfy { category in
            let status = viewModel.getStatus(for: category)
            return !status.running && !status.isRequired
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: t("settings__backup_title"))

            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        Button(action: {
                            sheets.showSheet(.backup, data: BackupConfig(view: .mnemonic))
                        }) {
                            SettingsListLabel(title: t("settings__backup__wallet"))
                        }
                        .accessibilityIdentifier("BackupWallet")

                        NavigationLink(value: Route.resetAndRestore) {
                            SettingsListLabel(title: t("settings__backup__reset"))
                        }
                        .accessibilityIdentifier("ResetAndRestore")

                        HStack(alignment: .center, spacing: 8) {
                            SettingsLabel(t("settings__backup__latest"))

                            if Env.isE2E, allSynced {
                                Image("check")
                                    .resizable()
                                    .frame(width: 16, height: 16)
                                    .foregroundColor(.greenAccent)
                                    .accessibilityIdentifier("AllSynced")
                            }
                        }
                        .padding(.top, 16)

                        ForEach(BackupCategory.allCases, id: \.self) { category in
                            let status = viewModel.getStatus(for: category)
                            let statusText = viewModel.formatStatusText(for: category)
                            let iconColor = viewModel.iconColor(for: status)
                            let backgroundColor = viewModel.backgroundColor(for: status)
                            let showRetry = status.isRequired && !status.running

                            StatusItemView(
                                imageName: category.uiIcon,
                                title: category.uiTitle,
                                statusText: statusText,
                                iconColor: iconColor,
                                backgroundColor: backgroundColor,
                                showRetryButton: showRetry,
                                onRetry: {
                                    viewModel.triggerBackup(for: category)
                                }
                            )
                        }

                        Spacer()
                    }
                    .frame(minHeight: geometry.size.height)
                    .bottomSafeAreaPadding()
                }
                .accessibilityIdentifier("BackupScrollView")
            }
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
    }
}
