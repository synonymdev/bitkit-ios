import SwiftUI

struct PrimaryNodeSettingsScreen: View {
    @EnvironmentObject var app: AppViewModel
    @EnvironmentObject var navigation: NavigationViewModel
    @EnvironmentObject var wallet: WalletViewModel

    @State private var input = ""
    @State private var hasEdited = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var isTextFieldFocused: Bool

    private var currentPrimary: PrimaryNode? {
        PrimaryNodeService.shared.primaryNode
    }

    private var isConnected: Bool {
        guard let primary = currentPrimary else { return false }
        return wallet.peers?.contains { $0.nodeId == primary.nodeId && $0.isConnected } ?? false
    }

    private var isInputDefault: Bool {
        input == Env.defaultPrimaryNodeUri
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(
                title: t("primary_node__title"),
                action: AnyView(Button(action: {
                    navigation.navigate(.scanner)
                }) {
                    Image("scan")
                        .resizable()
                        .foregroundColor(.textPrimary)
                        .frame(width: 24, height: 24)
                        .frame(width: 32, height: 32)
                        .padding(.leading, 16)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("NavigationAction"))
            )
            .padding(.bottom, 16)

            GeometryReader { geometry in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        BodyMText(t("primary_node__description"))
                            .padding(.bottom, 24)

                        if let currentPrimary {
                            VStack(alignment: .leading, spacing: 8) {
                                CaptionMText(t("primary_node__current"))
                                BodySText(currentPrimary.uri, textColor: .textPrimary)
                                    .accessibilityIdentifier("PrimaryNodeCurrent")
                                BodyMText(
                                    isConnected ? t("primary_node__status_connected") : t("primary_node__status_offline"),
                                    textColor: isConnected ? .greenAccent : .redAccent
                                )
                                .accessibilityIdentifier(isConnected ? "PrimaryNodeOnline" : "PrimaryNodeOffline")
                            }
                            .padding(.bottom, 16)
                        }

                        if PrimaryNodeService.shared.isFundingPaused {
                            BodyMText(t("primary_node__funding_paused"))
                                .accessibilityIdentifier("PrimaryNodeFundingPaused")
                                .padding(.bottom, 16)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            CaptionMText(t("primary_node__address"))
                            TextField(t("primary_node__address_placeholder"), text: $input, axis: .vertical)
                                .lineLimit(3 ... 5)
                                .focused($isTextFieldFocused)
                                .autocapitalization(.none)
                                .autocorrectionDisabled(true)
                                .disabled(isLoading)
                                .onChange(of: input) { _ in
                                    hasEdited = true
                                    errorMessage = nil
                                }
                                .accessibilityIdentifier("PrimaryNodeInput")
                        }
                        .padding(.bottom, 16)

                        CustomButton(title: t("lightning__external_manual__paste"), variant: .secondary) {
                            if let text = UIPasteboard.general.string {
                                input = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                        .accessibilityIdentifier("PrimaryNodePaste")
                        .padding(.bottom, 16)

                        if let errorMessage {
                            BodyMText(errorMessage, textColor: .redAccent)
                                .accessibilityIdentifier("PrimaryNodeError")
                                .padding(.bottom, 16)
                        }

                        BodySText(t("primary_node__trust"))

                        Spacer()

                        HStack(spacing: 16) {
                            CustomButton(title: t("settings__es__button_reset"), variant: .secondary, isDisabled: isLoading || isInputDefault) {
                                input = Env.defaultPrimaryNodeUri
                            }
                            .accessibilityIdentifier("PrimaryNodeReset")

                            CustomButton(
                                title: t("primary_node__connect"),
                                isDisabled: input.isEmpty || isLoading,
                                isLoading: isLoading
                            ) {
                                await connect()
                            }
                            .accessibilityIdentifier("PrimaryNodeConnect")
                        }
                        .padding(.top, 16)
                        .bottomSafeAreaPadding()
                    }
                    .frame(minHeight: geometry.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isTextFieldFocused = false
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .navigationBarHidden(true)
        .padding(.horizontal, 16)
        .onAppear {
            if !hasEdited {
                input = currentPrimary?.uri ?? ""
                hasEdited = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primaryNodeScanned)) { notification in
            guard let uri = notification.object as? String else { return }
            if let primary = PrimaryNode.parseOrNil(uri) {
                input = primary.uri
            } else {
                errorMessage = t("primary_node__invalid")
            }
        }
    }

    private func connect() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            _ = try await PrimaryNodeService.shared.pair(input)
            wallet.syncState()
            hasEdited = false
            app.toast(type: .success, title: t("primary_node__connected"), accessibilityIdentifier: "PrimaryNodeConnectedToast")
        } catch {
            errorMessage = error.primaryErrorMessage
        }
    }
}
