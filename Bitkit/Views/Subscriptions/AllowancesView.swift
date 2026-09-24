import SwiftUI

// MARK: - Allowances tab

struct AllowancesTab: View {
    @Environment(PaykitAllowanceManager.self) private var allowances
    @EnvironmentObject private var sheets: SheetViewModel

    var body: some View {
        Group {
            if allowances.entries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .task {
            await allowances.refresh()
        }
    }

    private var list: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            LazyVStack(spacing: 12) {
                ForEach(allowances.entries) { entry in
                    Button {
                        let route: SubscriptionSheetItem.Route = entry.primary.isAnswerable
                            ? .allowanceReview(entry)
                            : .allowanceDetail(entry)
                        sheets.showSheet(.subscription, data: SubscriptionSheetItem(route: route))
                    } label: {
                        AllowanceRow(entry: entry, now: context.date)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 32)
            .padding(.bottom, ScreenLayout.floatingFooterClearance)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            Image("group")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 256, height: 256)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)

            Spacer().frame(height: 32)

            DisplayText(t("subscriptions__allowances_empty_headline"), accentColor: .purpleAccent)
            Spacer().frame(height: 8)
            BodyMText(t("subscriptions__allowances_empty_description"), textColor: .white64)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, ScreenLayout.floatingFooterClearance)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("AllowancesEmpty")
    }
}

struct AllowanceRow: View {
    @Environment(PaykitAllowanceManager.self) private var allowances
    @EnvironmentObject private var currency: CurrencyViewModel

    let entry: PaykitAllowanceEntry
    let now: Date

    private var status: PaykitAllowance.Status {
        entry.status(at: now)
    }

    var body: some View {
        HStack(spacing: 16) {
            AllowanceCounterpartyAvatar(counterparty: entry.counterparty, size: 40)

            VStack(alignment: .leading, spacing: 0) {
                AllowanceCounterpartyName(counterparty: entry.counterparty)
                CaptionBText(subtitle, textColor: .white64)
                    .lineLimit(1)
                    .accessibilityIdentifier("AllowanceRowStatus")
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 0) {
                AllowanceMoney(usd: entry.limits?.monthlyUsd, sats: entry.monthlyLimitSats, size: .bodyMSB)
                CaptionBText(t("subscriptions__allowance_monthly_limit"), textColor: .white64)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .background(Color.gray6)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .opacity(isInactive ? 0.64 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("AllowanceRow-\(entry.id)")
    }

    private var isInactive: Bool {
        switch status {
        case .ended, .declined, .expired, .conflicted: true
        default: false
        }
    }

    private var subtitle: String {
        let perPayment = AllowanceAmountText.perPayment(entry, currency: currency)
        switch status {
        case .active:
            return [t("subscriptions__allowance_status_active"), perPayment].compactMap { $0 }.joined(separator: " · ")
        case .awaitingAnswer:
            return t("subscriptions__allowance_status_waiting")
        case .awaitingMyAnswer:
            return t("subscriptions__allowance_status_needs_answer")
        case .notYetActive:
            return t("subscriptions__allowance_status_scheduled")
        case .expired:
            return t("subscriptions__allowance_status_expired")
        case .declined:
            return t("subscriptions__allowance_status_declined")
        case .conflicted:
            return t("subscriptions__allowance_status_conflicted")
        case .ended:
            let paid = allowances.autoPaidSats(for: entry)
            guard paid > 0 else { return t("subscriptions__allowance_status_ended") }
            return t("subscriptions__allowance_status_ended") + " · " +
                t("subscriptions__allowance_paid_automatically", variables: ["amount": AllowanceAmountText.fiat(sats: paid, currency: currency)])
        }
    }
}

// MARK: - Shared pieces

struct AllowanceCounterpartyAvatar: View {
    @EnvironmentObject private var contactsManager: ContactsManager

    let counterparty: String
    let size: CGFloat

    var body: some View {
        if let contact = contactsManager.contacts.first(where: { PubkyPublicKeyFormat.matches($0.publicKey, counterparty) }) {
            PubkyContactAvatar(contact: contact, size: size)
        } else {
            ContactAvatarLetter(source: counterparty, size: size)
        }
    }
}

struct AllowanceCounterpartyName: View {
    @EnvironmentObject private var contactsManager: ContactsManager

    let counterparty: String

    var body: some View {
        BodyMSBText(name)
            .lineLimit(1)
    }

    private var name: String {
        contactsManager.contacts.first { PubkyPublicKeyFormat.matches($0.publicKey, counterparty) }?.displayName
            ?? PubkyPublicKeyFormat.displayTruncated(counterparty)
    }
}

/// A limit shown in dollars: the label the Allower picked when there is one, otherwise the BTC terms at today's rate.
struct AllowanceMoney: View {
    @EnvironmentObject private var currency: CurrencyViewModel

    enum Size {
        case bodyMSB
        case title
    }

    let usd: Decimal?
    let sats: UInt64?
    var size: Size = .bodyMSB

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            text("$", color: .white64)
            text(amount, color: .textPrimary)
        }
    }

    private var amount: String {
        if let usd {
            return AllowanceAmountText.formatted(usd)
        }
        guard let sats else { return "—" }
        return AllowanceAmountText.fiatValue(sats: sats, currency: currency)
    }

    @ViewBuilder
    private func text(_ value: String, color: Color) -> some View {
        switch size {
        case .bodyMSB: BodyMSBText(value, textColor: color)
        case .title: TitleText(value, textColor: color)
        }
    }
}

enum AllowanceAmountText {
    static func formatted(_ usd: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: usd as NSDecimalNumber) ?? "\(usd)"
    }

    static func short(_ usd: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.locale = Locale(identifier: "en_US")
        return "$" + (formatter.string(from: usd as NSDecimalNumber) ?? "\(usd)")
    }

    @MainActor
    static func fiatValue(sats: UInt64, currency: CurrencyViewModel) -> String {
        guard let converted = currency.convert(sats: sats, to: "USD") else { return "—" }
        return formatted(converted.value)
    }

    @MainActor
    static func fiat(sats: UInt64, currency: CurrencyViewModel) -> String {
        "$" + fiatValue(sats: sats, currency: currency)
    }

    @MainActor
    static func perPayment(_ entry: PaykitAllowanceEntry, currency: CurrencyViewModel) -> String? {
        if let usd = entry.limits?.perPaymentUsd {
            return t("subscriptions__allowance_per_payment_short", variables: ["amount": short(usd)])
        }
        guard let sats = entry.perPaymentMaxSats else { return nil }
        return t("subscriptions__allowance_per_payment_short", variables: ["amount": fiat(sats: sats, currency: currency)])
    }
}

private struct AllowanceLimitsGrid: View {
    @EnvironmentObject private var currency: CurrencyViewModel

    let entry: PaykitAllowanceEntry

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            cell(
                title: t("subscriptions__allowance_per_payment"),
                usd: entry.limits?.perPaymentUsd,
                sats: entry.perPaymentMaxSats,
                identifier: "AllowancePerPaymentValue"
            )
            cell(
                title: t("subscriptions__allowance_each_month"),
                usd: entry.limits?.monthlyUsd,
                sats: entry.monthlyLimitSats,
                identifier: "AllowanceMonthlyValue"
            )
        }
    }

    private func cell(title: String, usd: Decimal?, sats: UInt64?, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionMText(title.localizedUppercase, textColor: .white64)
            BodySSBText(t("subscriptions__allowance_up_to", variables: ["amount": usd.map { "$" + AllowanceAmountText.formatted($0) } ?? sats.map { AllowanceAmountText.fiat(sats: $0, currency: currency) } ?? "—"]))
                .accessibilityIdentifier(identifier)
            if let sats {
                CaptionText("₿ " + sats.formattedWithSpaces, textColor: .white64)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AllowanceCounterpartyCard: View {
    @EnvironmentObject private var contactsManager: ContactsManager

    let counterparty: String

    var body: some View {
        HStack(spacing: 16) {
            AllowanceCounterpartyAvatar(counterparty: counterparty, size: 48)
            VStack(alignment: .leading, spacing: 0) {
                CaptionMText(PubkyPublicKeyFormat.displayTruncated(counterparty).localizedUppercase, textColor: .white64)
                AllowanceCounterpartyName(counterparty: counterparty)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("AllowanceCounterparty")
    }
}

extension UInt64 {
    var formattedWithSpaces: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}

// MARK: - Choose a contact

struct AllowanceContactView: View {
    @EnvironmentObject private var contactsManager: ContactsManager

    let onSelect: (PubkyContact) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("subscriptions__allowance_choose_contact"))

            if contactsManager.contacts.isEmpty {
                BodyMText(t("subscriptions__allowance_no_contacts"), textColor: .white64)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 16)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(contactsManager.contacts) { contact in
                            Button {
                                onSelect(contact)
                            } label: {
                                HStack(spacing: 16) {
                                    PubkyContactAvatar(contact: contact, size: 48)
                                    VStack(alignment: .leading, spacing: 0) {
                                        CaptionMText(contact.profile.truncatedPublicKey.localizedUppercase, textColor: .white64)
                                        BodyMSBText(contact.displayName)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("AllowanceContact-\(contact.displayName)")
                            CustomDivider()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Set Allowance

struct SetAllowanceView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
    @Environment(PaykitAllowanceManager.self) private var allowances

    let contact: PubkyContact
    let onBack: () -> Void
    let onSaved: () -> Void

    @State private var perPaymentIndex = 1
    @State private var monthlyIndex = 2

    private var perPaymentUsd: Decimal { PaykitAllowanceLimits.perPaymentStopsUsd[perPaymentIndex] }
    private var monthlyUsd: Decimal { PaykitAllowanceLimits.monthlyStopsUsd[monthlyIndex] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("subscriptions__allowance_set_title"), showBackButton: true, onBack: onBack)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AllowanceCounterpartyCard(counterparty: contact.publicKey)

                    BodyMText(
                        t("subscriptions__allowance_set_explanation", variables: ["name": contact.displayName]),
                        textColor: .white64
                    )

                    VStack(alignment: .leading, spacing: 0) {
                        CaptionMText(t("subscriptions__allowance_payment_limit").localizedUppercase, textColor: .white64)
                            .padding(.vertical, 16)
                        AllowanceStepSlider(
                            stops: PaykitAllowanceLimits.perPaymentStopsUsd,
                            selectedIndex: $perPaymentIndex,
                            identifier: "AllowancePerPayment"
                        )
                    }

                    CustomDivider()

                    VStack(alignment: .leading, spacing: 0) {
                        CaptionMText(t("subscriptions__allowance_monthly_allowance").localizedUppercase, textColor: .white64)
                            .padding(.vertical, 16)
                        AllowanceStepSlider(
                            stops: PaykitAllowanceLimits.monthlyStopsUsd,
                            selectedIndex: $monthlyIndex,
                            identifier: "AllowanceMonthly"
                        )
                    }

                    CustomDivider()

                    BodySText(
                        t(
                            "subscriptions__allowance_set_summary",
                            variables: [
                                "perPayment": AllowanceAmountText.short(perPaymentUsd),
                                "monthly": AllowanceAmountText.short(monthlyUsd),
                            ]
                        ),
                        textColor: .white64
                    )
                    .accessibilityIdentifier("AllowanceSummary")
                }
                .padding(.bottom, 16)
            }

            CustomButton(title: t("subscriptions__allowance_save"), variant: .secondary, isLoading: allowances.isWorking) {
                await save()
            }
            .accessibilityIdentifier("AllowanceSave")
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SetAllowance")
    }

    private func save() async {
        guard let perPaymentSats = currency.convert(fiatAmount: NSDecimalNumber(decimal: perPaymentUsd).doubleValue, from: "USD"),
              let monthlySats = currency.convert(fiatAmount: NSDecimalNumber(decimal: monthlyUsd).doubleValue, from: "USD")
        else {
            app.toast(PaykitAllowanceError.unavailable)
            return
        }
        let limits = PaykitAllowanceLimits(
            perPaymentUsd: perPaymentUsd,
            monthlyUsd: monthlyUsd,
            perPaymentSats: perPaymentSats,
            monthlySats: monthlySats
        )
        do {
            try await allowances.propose(to: contact, limits: limits)
            onSaved()
        } catch {
            app.toast(error)
        }
    }
}

/// A slider that snaps to fixed stops, drawn like the Figma allowance limits: a track, a tick per stop, and a knob.
struct AllowanceStepSlider: View {
    let stops: [Decimal]
    @Binding var selectedIndex: Int
    let identifier: String

    private let knobSize: CGFloat = 32
    private let trackHeight: CGFloat = 8

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.purpleAccent.opacity(0.32))
                        .frame(height: trackHeight)
                    Capsule()
                        .fill(Color.purpleAccent)
                        .frame(width: position(for: selectedIndex, width: width), height: trackHeight)
                    ForEach(stops.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white)
                            .frame(width: 4, height: 16)
                            .offset(x: min(max(position(for: index, width: width) - 2, 0), width - 4))
                    }
                    Circle()
                        .fill(Color.purpleAccent)
                        .frame(width: knobSize, height: knobSize)
                        .overlay(Circle().fill(Color.white).frame(width: 16, height: 16))
                        .offset(x: position(for: selectedIndex, width: width) - knobSize / 2)
                }
                .frame(height: knobSize)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            select(nearestIndex(to: value.location.x, width: width))
                        }
                )
            }
            .frame(height: knobSize)

            HStack(spacing: 0) {
                ForEach(stops.indices, id: \.self) { index in
                    Button {
                        select(index)
                    } label: {
                        CaptionMText(AllowanceAmountText.short(stops[index]), textColor: .textPrimary)
                            .frame(maxWidth: .infinity, alignment: alignment(for: index))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("\(identifier)Stop-\(index)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(AllowanceAmountText.short(stops[selectedIndex]))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: select(selectedIndex + 1)
            case .decrement: select(selectedIndex - 1)
            @unknown default: break
            }
        }
    }

    private func select(_ index: Int) {
        let clamped = min(max(index, 0), stops.count - 1)
        guard clamped != selectedIndex else { return }
        selectedIndex = clamped
        Haptics.play(.light)
    }

    private func position(for index: Int, width: CGFloat) -> CGFloat {
        guard stops.count > 1 else { return width / 2 }
        return width * CGFloat(index) / CGFloat(stops.count - 1)
    }

    private func nearestIndex(to x: CGFloat, width: CGFloat) -> Int {
        guard stops.count > 1, width > 0 else { return 0 }
        return Int((x / width * CGFloat(stops.count - 1)).rounded())
    }

    private func alignment(for index: Int) -> Alignment {
        if index == 0 { return .leading }
        if index == stops.count - 1 { return .trailing }
        return .center
    }
}

// MARK: - Review (the side that answers a proposal)

struct AllowanceReviewView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @EnvironmentObject private var contactsManager: ContactsManager
    @Environment(PaykitAllowanceManager.self) private var allowances

    let entry: PaykitAllowanceEntry

    private var counterpartyName: String {
        contactsManager.contacts.first { PubkyPublicKeyFormat.matches($0.publicKey, entry.counterparty) }?.displayName
            ?? PubkyPublicKeyFormat.displayTruncated(entry.counterparty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("subscriptions__allowance_title"))

            DisplayText(
                entry.role == .allowee
                    ? t("subscriptions__allowance_offer_headline", variables: ["name": counterpartyName])
                    : t("subscriptions__allowance_request_headline", variables: ["name": counterpartyName]),
                accentColor: .purpleAccent
            )
            .padding(.top, 16)
            .padding(.bottom, 16)

            AllowanceCounterpartyCard(counterparty: entry.counterparty)
                .padding(16)
                .background(Color.gray6)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            AllowanceLimitsGrid(entry: entry)
                .padding(.top, 24)

            BodyMText(
                entry.role == .allowee
                    ? t("subscriptions__allowance_offer_explanation", variables: ["name": counterpartyName])
                    : t("subscriptions__allowance_request_explanation", variables: ["name": counterpartyName]),
                textColor: .white64
            )
            .padding(.top, 24)

            Spacer()

            HStack(spacing: 16) {
                CustomButton(title: t("subscriptions__allowance_decline"), variant: .secondary, isDisabled: allowances.isWorking) {
                    await respond(accept: false)
                }
                .accessibilityIdentifier("AllowanceDecline")
                CustomButton(title: t("subscriptions__allowance_accept"), isLoading: allowances.isWorking) {
                    await respond(accept: true)
                }
                .accessibilityIdentifier("AllowanceAccept")
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("AllowanceReview")
        .task {
            await allowances.markProposalPresented(entry)
        }
    }

    private func respond(accept: Bool) async {
        do {
            if accept {
                try await allowances.accept(entry)
            } else {
                try await allowances.reject(entry)
            }
            sheets.hideSheet(reason: accept ? "Allowance accepted" : "Allowance declined")
        } catch {
            app.toast(error)
        }
    }
}

// MARK: - Detail

struct AllowanceDetailView: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var currency: CurrencyViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @Environment(PaykitAllowanceManager.self) private var allowances

    let entry: PaykitAllowanceEntry

    private var current: PaykitAllowanceEntry {
        allowances.entry(id: entry.id) ?? entry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: t("subscriptions__allowance_title"))

            AllowanceCounterpartyCard(counterparty: current.counterparty)
                .padding(16)
                .background(Color.gray6)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            AllowanceLimitsGrid(entry: current)
                .padding(.top, 24)

            VStack(alignment: .leading, spacing: 8) {
                CaptionMText(t("subscriptions__allowance_paid_so_far").localizedUppercase, textColor: .white64)
                BodySSBText(AllowanceAmountText.fiat(sats: allowances.autoPaidSats(for: current), currency: currency))
                    .accessibilityIdentifier("AllowancePaidSoFar")
            }
            .padding(.top, 24)

            BodyMText(explanation, textColor: .white64)
                .padding(.top, 24)
                .accessibilityIdentifier("AllowanceDetailStatus")

            Spacer()

            if current.canEnd {
                SwipeButton(
                    title: current.primary.lifecycleState == .proposed
                        ? t("subscriptions__allowance_swipe_withdraw")
                        : t("subscriptions__allowance_swipe_end"),
                    accentColor: .purpleAccent,
                    isLoading: allowances.isWorking
                ) {
                    do {
                        try await allowances.end(current)
                        sheets.hideSheet(reason: "Allowance ended")
                    } catch {
                        app.toast(error)
                        throw error
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("AllowanceDetail")
    }

    private var explanation: String {
        switch current.status(at: Date()) {
        case .active:
            current.role == .allower
                ? t("subscriptions__allowance_detail_active_allower")
                : t("subscriptions__allowance_detail_active_allowee")
        case .awaitingAnswer:
            t("subscriptions__allowance_status_waiting")
        case .awaitingMyAnswer:
            t("subscriptions__allowance_status_needs_answer")
        case .notYetActive:
            t("subscriptions__allowance_status_scheduled")
        case .expired:
            t("subscriptions__allowance_status_expired")
        case .declined:
            t("subscriptions__allowance_status_declined")
        case .ended:
            t("subscriptions__allowance_detail_ended")
        case .conflicted:
            t("subscriptions__allowance_status_conflicted")
        }
    }
}
