import SwiftUI

enum PaymentRequestExpiration: String, CaseIterable, Identifiable {
    case hour
    case day
    case week
    case month

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .hour: t("wallet__payment_request_expiry_hour")
        case .day: t("wallet__payment_request_expiry_day")
        case .week: t("wallet__payment_request_expiry_week")
        case .month: t("wallet__payment_request_expiry_month")
        }
    }

    func date(from date: Date) -> Date {
        switch self {
        case .hour: date.addingTimeInterval(60 * 60)
        case .day: date.addingTimeInterval(24 * 60 * 60)
        case .week: date.addingTimeInterval(7 * 24 * 60 * 60)
        case .month: Calendar.current.date(byAdding: .month, value: 1, to: date) ?? date.addingTimeInterval(30 * 24 * 60 * 60)
        }
    }

    static func closest(to expiration: Date, from date: Date) -> PaymentRequestExpiration {
        allCases.min {
            abs($0.date(from: date).timeIntervalSince(expiration)) < abs($1.date(from: date).timeIntervalSince(expiration))
        } ?? .week
    }
}

struct PaymentRequestDetailsView: View {
    @EnvironmentObject private var currency: CurrencyViewModel

    let initialDraft: PaykitPaymentRequestDraft
    let onContinue: (PaykitPaymentRequestDraft) -> Void

    @State private var amountViewModel = AmountInputViewModel()
    @State private var note = ""
    @State private var expiration = PaymentRequestExpiration.week
    @State private var isAmountInputFocused = false
    @FocusState private var isNoteFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__payment_request"), showBackButton: true)

            VStack(alignment: .leading, spacing: 0) {
                CaptionMText(t("wallet__payment_request_amount"), textColor: .white64)
                    .padding(.bottom, 8)

                NumberPadTextField(
                    viewModel: amountViewModel,
                    showEditButton: !isAmountInputFocused,
                    isFocused: isAmountInputFocused,
                    testIdentifier: "PaymentRequestAmountField"
                )
                .onTapGesture {
                    if isAmountInputFocused {
                        amountViewModel.togglePrimaryDisplay(currency: currency)
                    } else {
                        isAmountInputFocused = true
                    }
                }

                if !isAmountInputFocused {
                    CaptionMText(t("wallet__note"), textColor: .white64)
                        .padding(.top, 24)
                        .padding(.bottom, 8)

                    ZStack(alignment: .topLeading) {
                        if note.isEmpty {
                            BodySSBText(t("wallet__receive_note_placeholder"), textColor: .textSecondary)
                        }
                        TextEditor(text: $note)
                            .focused($isNoteFocused)
                            .font(.custom(Fonts.semiBold, size: 15))
                            .foregroundColor(.textPrimary)
                            .accentColor(.brandAccent)
                            .scrollContentBackground(.hidden)
                            .padding(EdgeInsets(top: -8, leading: -5, bottom: -5, trailing: -5))
                            .frame(minHeight: 30, maxHeight: 50)
                            .accessibilityIdentifier("PaymentRequestNote")
                    }
                    .padding()
                    .background(Color.white06)
                    .cornerRadius(8)

                    CaptionMText(t("wallet__payment_request_expires"), textColor: .white64)
                        .padding(.top, 24)
                        .padding(.bottom, 12)

                    expirationPicker

                    Spacer()

                    CustomButton(
                        title: t("wallet__payment_request_choose_recipient"),
                        isDisabled: amountViewModel.amountSats == 0
                    ) {
                        let draft = PaykitPaymentRequestDraft(
                            amountSats: amountViewModel.amountSats,
                            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                            expiresAt: expiration.date(from: Date())
                        )
                        onContinue(draft)
                    }
                    .buttonBottomPadding(isFocused: isNoteFocused)
                    .accessibilityIdentifier("PaymentRequestAmountContinue")
                }
            }

            if isAmountInputFocused {
                Spacer()

                NumberPad(
                    type: amountViewModel.getNumberPadType(currency: currency),
                    errorKey: amountViewModel.errorKey
                ) { key in
                    amountViewModel.handleNumberPadInput(key, currency: currency)
                }

                CustomButton(title: t("common__continue"), isDisabled: amountViewModel.amountSats == 0) {
                    isAmountInputFocused = false
                }
            }
        }
        .padding(.horizontal, 16)
        .sheetBackground()
        .navigationBarHidden(true)
        .task {
            amountViewModel.updateFromSats(initialDraft.amountSats, currency: currency)
            note = initialDraft.note
            if initialDraft.expiresAt > Date() {
                expiration = .closest(to: initialDraft.expiresAt, from: Date())
            }
        }
        .onChange(of: note) { _, value in
            if value.count > 256 {
                note = String(value.prefix(256))
            }
        }
    }

    private var expirationPicker: some View {
        HStack(spacing: 0) {
            ForEach(PaymentRequestExpiration.allCases) { option in
                Button {
                    expiration = option
                } label: {
                    VStack(spacing: 8) {
                        BodySSBText(option.title, textColor: expiration == option ? .textPrimary : .white64)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Rectangle()
                            .fill(expiration == option ? Color.brandAccent : Color.white16)
                            .frame(height: 2)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(expiration == option ? .isSelected : [])
            }
        }
    }
}

struct PaymentRequestRecipientView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var contactsManager: ContactsManager
    @Environment(PaykitPaymentRequestManager.self) private var paymentRequests

    let draft: PaykitPaymentRequestDraft
    let onSent: (PaykitPaymentRequest) -> Void

    @State private var selectedTarget: PaykitPaymentRequestTarget?

    private var recipientTargets: [PaykitPaymentRequestTarget] {
        paymentRequests.eligibleTargets.sorted {
            displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__payment_request_choose_recipient"), showBackButton: !paymentRequests.isCreatingRequest)

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    CaptionMText(t("contacts__nav_title").localizedUppercase, textColor: .white64)
                        .padding(.bottom, 16)

                    CustomDivider()

                    ForEach(recipientTargets) { target in
                        if let contact = contact(for: target) {
                            PubkyContactRow(
                                contact: contact,
                                verticalPadding: 20,
                                isLoading: paymentRequests.isCreatingRequest && selectedTarget == target,
                                isSelected: selectedTarget == target
                            ) {
                                selectedTarget = target
                            }
                            .accessibilityIdentifier("PaymentRequestContact-\(contact.publicKey)")
                            .disabled(paymentRequests.isCreatingRequest)
                        }
                    }
                }
            }

            CustomButton(
                title: t("wallet__payment_request_send_request"),
                isDisabled: !canSend,
                isLoading: paymentRequests.isCreatingRequest
            ) {
                await sendRequest()
            }
            .accessibilityIdentifier("PaymentRequestSend")
        }
        .padding(.horizontal, 16)
        .sheetBackground()
        .navigationBarHidden(true)
        .interactiveDismissDisabled(paymentRequests.isCreatingRequest)
        .onChange(of: recipientTargets) { _, targets in
            if let selectedTarget, !targets.contains(selectedTarget) {
                self.selectedTarget = nil
            }
        }
    }

    private func sendRequest() async {
        guard let selectedTarget, recipientTargets.contains(selectedTarget) else { return }
        do {
            let request = try await paymentRequests.propose(draft, to: selectedTarget)
            guard paymentRequests.sentRequests.contains(where: { $0.id == request.id }) else { return }
            onSent(request)
        } catch {
            app.toast(error)
        }
    }

    private func contact(for target: PaykitPaymentRequestTarget) -> PubkyContact? {
        contactsManager.contacts.first { PubkyPublicKeyFormat.matches($0.publicKey, target.publicKey) }
    }

    private func displayName(for target: PaykitPaymentRequestTarget) -> String {
        contact(for: target)?.displayName ?? target.publicKey
    }

    private var canSend: Bool {
        selectedTarget.map(recipientTargets.contains) == true
    }
}

struct PaymentRequestSentView: View {
    @EnvironmentObject private var sheets: SheetViewModel

    let request: PaykitPaymentRequest

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("wallet__payment_request_sent_title"))

            MoneyStack(
                sats: Int(clamping: request.amountSats),
                showSymbol: true,
                testIdPrefix: "PaymentRequestSentAmount"
            )

            Spacer()

            Image("check")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 180, maxHeight: 180)
                .padding(.bottom, 32)

            DisplayText(t("wallet__payment_request_sent_headline"))
                .multilineTextAlignment(.center)
                .padding(.bottom, 16)

            BodyMText(description, textColor: .white64)
                .multilineTextAlignment(.center)

            Spacer()

            CustomButton(title: t("common__ok")) {
                sheets.hideSheet(reason: "Payment request created")
            }
        }
        .padding(.horizontal, 16)
        .sheetBackground()
        .navigationBarHidden(true)
        .accessibilityIdentifier("PaymentRequestSent")
    }

    private var description: String {
        request.deliveryStatus == .sent
            ? t("wallet__payment_request_sent_description")
            : t("wallet__payment_request_queued_description")
    }
}
