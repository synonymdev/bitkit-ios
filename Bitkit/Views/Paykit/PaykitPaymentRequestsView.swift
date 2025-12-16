//
//  PaykitPaymentRequestsView.swift
//  Bitkit
//
//  Payment requests management view with full functionality
//

import SwiftUI

struct PaykitPaymentRequestsView: View {
    @StateObject private var viewModel = PaymentRequestsViewModel()
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var navigation: NavigationViewModel
    @EnvironmentObject private var sheets: SheetViewModel
    @State private var showingCreateRequest = false
    @State private var selectedFilter: RequestFilter = .all
    @State private var selectedStatusFilter: PaymentRequestStatus? = nil
    @State private var peerFilter: String = ""
    @State private var showingFilters = false
    @State private var selectedRequest: BitkitPaymentRequest? = nil
    @State private var showingRequestDetail = false
    
    enum RequestFilter: String, CaseIterable {
        case all = "All"
        case incoming = "Incoming"
        case outgoing = "Outgoing"
        case pending = "Pending"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(
                title: "Payment Requests",
                action: AnyView(
                    HStack(spacing: 16) {
                        Button {
                            showingFilters.toggle()
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .foregroundColor(hasActiveFilters ? .brandAccent : .textSecondary)
                        }
                        
                        Button {
                            showingCreateRequest = true
                        } label: {
                            Image(systemName: "plus")
                                .foregroundColor(.brandAccent)
                        }
                    }
                )
            )
            
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    // Direction Filter Picker
                    filterSection
                    
                    // Advanced Filters
                    if showingFilters {
                        advancedFiltersSection
                    }
                    
                    // Requests List
                    if viewModel.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    } else if filteredRequests.isEmpty {
                        emptyStateView
                    } else {
                        requestsList
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            viewModel.loadRequests()
        }
        .refreshable {
            viewModel.loadRequests()
        }
        .sheet(isPresented: $showingCreateRequest) {
            CreatePaymentRequestView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingRequestDetail) {
            if let request = selectedRequest {
                PaymentRequestDetailSheet(request: request, viewModel: viewModel)
            }
        }
    }
    
    private var hasActiveFilters: Bool {
        selectedStatusFilter != nil || !peerFilter.isEmpty
    }
    
    private var filterSection: some View {
        Picker("Filter", selection: $selectedFilter) {
            ForEach(RequestFilter.allCases, id: \.self) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.segmented)
    }
    
    private var advancedFiltersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyMText("Advanced Filters")
                .foregroundColor(.textSecondary)
            
            // Status Filter
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    RequestFilterChip(title: "Any Status", isSelected: selectedStatusFilter == nil) {
                        selectedStatusFilter = nil
                    }
                    ForEach(PaymentRequestStatus.allCases, id: \.self) { status in
                        RequestFilterChip(title: status.rawValue, isSelected: selectedStatusFilter == status) {
                            selectedStatusFilter = status
                        }
                    }
                }
            }
            
            // Peer Filter
            HStack {
                Image(systemName: "person.circle")
                    .foregroundColor(.textSecondary)
                TextField("Filter by peer pubkey...", text: $peerFilter)
                    .foregroundColor(.white)
                    .autocapitalization(.none)
                if !peerFilter.isEmpty {
                    Button {
                        peerFilter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.textSecondary)
                    }
                }
            }
            .padding(12)
            .background(Color.gray6)
            .cornerRadius(8)
        }
        .padding(16)
        .background(Color.gray5)
        .cornerRadius(12)
    }
    
    private var filteredRequests: [BitkitPaymentRequest] {
        var results = viewModel.requests
        
        // Direction filter
        switch selectedFilter {
        case .all:
            break
        case .incoming:
            results = results.filter { $0.direction == .incoming }
        case .outgoing:
            results = results.filter { $0.direction == .outgoing }
        case .pending:
            results = results.filter { $0.status == .pending }
        }
        
        // Status filter
        if let statusFilter = selectedStatusFilter {
            results = results.filter { $0.status == statusFilter }
        }
        
        // Peer filter
        if !peerFilter.isEmpty {
            let query = peerFilter.lowercased()
            results = results.filter {
                $0.fromPubkey.lowercased().contains(query) ||
                $0.toPubkey.lowercased().contains(query) ||
                $0.counterpartyName.lowercased().contains(query)
            }
        }
        
        return results.sorted { $0.createdAt > $1.createdAt }
    }
    
    private var requestsList: some View {
        VStack(spacing: 0) {
            ForEach(filteredRequests) { request in
                PaymentRequestRow(
                    request: request,
                    viewModel: viewModel,
                    onTap: {
                        selectedRequest = request
                        showingRequestDetail = true
                    },
                    onPayNow: {
                        initiatePayment(for: request)
                    }
                )
                
                if request.id != filteredRequests.last?.id {
                    Divider()
                        .background(Color.white16)
                }
            }
        }
        .background(Color.gray6)
        .cornerRadius(8)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Image(systemName: "bell.badge")
                .font(.system(size: 80))
                .foregroundColor(.textSecondary)
            
            BodyLText("No Payment Requests")
                .foregroundColor(.textPrimary)
            
            BodyMText("Create or receive payment requests")
                .foregroundColor(.textSecondary)
            
            Button {
                showingCreateRequest = true
            } label: {
                BodyMText("Create Request")
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.brandAccent)
                    .cornerRadius(8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    
    private func initiatePayment(for request: BitkitPaymentRequest) {
        Task {
            do {
                let result = try await PaykitPaymentService.shared.pay(
                    to: request.methodId == "lightning" ? "lightning:\(request.id)" : request.toPubkey,
                    amountSats: UInt64(request.amountSats),
                    peerPubkey: request.fromPubkey
                )
                
                if result.success {
                    var updatedRequest = request
                    updatedRequest.status = .paid
                    try viewModel.updateRequest(updatedRequest)
                    app.toast(type: .success, title: "Payment sent!")
                } else {
                    app.toast(type: .error, title: "Payment failed", description: result.error?.localizedDescription)
                }
            } catch {
                app.toast(error)
            }
        }
    }
}

// MARK: - Filter Chip

private struct RequestFilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            BodySText(title)
                .foregroundColor(isSelected ? .white : .textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.brandAccent : Color.gray5)
                .cornerRadius(16)
        }
    }
}

struct PaymentRequestRow: View {
    let request: BitkitPaymentRequest
    @ObservedObject var viewModel: PaymentRequestsViewModel
    var onTap: () -> Void = {}
    var onPayNow: () -> Void = {}
    @EnvironmentObject private var app: AppViewModel
    @State private var isProcessing = false
    
    var body: some View {
        Button(action: onTap) {
            HStack {
                // Direction indicator
                Image(systemName: request.direction == .incoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .foregroundColor(request.direction == .incoming ? .greenAccent : .brandAccent)
                    .font(.title2)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        BodyMBoldText(request.counterpartyName)
                            .foregroundColor(.white)
                        
                        Spacer()
                        
                        StatusBadge(status: request.status)
                    }
                    
                    BodyMText("\(formatSats(request.amountSats))")
                        .foregroundColor(.white)
                    
                    HStack(spacing: 8) {
                        BodySText(request.methodId.capitalized)
                            .foregroundColor(.textSecondary)
                        
                        if !request.description.isEmpty {
                            BodySText("• \(request.description)")
                                .foregroundColor(.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    
                    // Description preview (metadata-like)
                    if !request.description.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text")
                                .font(.caption2)
                            BodySText(request.description)
                        }
                        .foregroundColor(.brandAccent)
                    }
                    
                    // Expiry
                    if let expiresAt = request.expiresAt {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.caption2)
                            BodySText(expiryText(expiresAt))
                        }
                        .foregroundColor(isExpiringSoon(expiresAt) ? .orange : .textSecondary)
                    }
                }
                
                Spacer()
                
                // Action buttons
                if request.status == .pending {
                    actionButtons
                }
            }
            .padding(16)
        }
        .buttonStyle(.plain)
    }
    
    @ViewBuilder
    private var actionButtons: some View {
        if request.direction == .incoming {
            // Incoming: Approve, Decline, Pay Now
            VStack(spacing: 8) {
                Button {
                    isProcessing = true
                    onPayNow()
                } label: {
                    HStack(spacing: 4) {
                        if isProcessing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "bolt.fill")
                        }
                        BodySText("Pay")
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.greenAccent)
                    .cornerRadius(8)
                }
                .disabled(isProcessing)
                
                HStack(spacing: 8) {
                    Button {
                        approveRequest()
                    } label: {
                        Image(systemName: "checkmark")
                            .foregroundColor(.greenAccent)
                            .font(.caption)
                            .frame(width: 28, height: 28)
                            .background(Color.greenAccent.opacity(0.2))
                            .cornerRadius(6)
                    }
                    
                    Button {
                        declineRequest()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(.redAccent)
                            .font(.caption)
                            .frame(width: 28, height: 28)
                            .background(Color.redAccent.opacity(0.2))
                            .cornerRadius(6)
                    }
                }
            }
        } else {
            // Outgoing: Show status indicator
            Image(systemName: "chevron.right")
                .foregroundColor(.textSecondary)
                .font(.caption)
        }
    }
    
    private func approveRequest() {
        do {
            var updated = request
            updated.status = .accepted
            try viewModel.updateRequest(updated)
            app.toast(type: .success, title: "Request accepted")
        } catch {
            app.toast(error)
        }
    }
    
    private func declineRequest() {
        do {
            var updated = request
            updated.status = .declined
            try viewModel.updateRequest(updated)
            app.toast(type: .success, title: "Request declined")
        } catch {
            app.toast(error)
        }
    }
    
    private func formatSats(_ amount: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: amount)) ?? "\(amount)") sats"
    }
    
    private func expiryText(_ date: Date) -> String {
        if date < Date() {
            return "Expired"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Expires \(formatter.localizedString(for: date, relativeTo: Date()))"
    }
    
    private func isExpiringSoon(_ date: Date) -> Bool {
        let hoursUntilExpiry = date.timeIntervalSinceNow / 3600
        return hoursUntilExpiry < 24 && hoursUntilExpiry > 0
    }
}

struct StatusBadge: View {
    let status: PaymentRequestStatus
    
    var body: some View {
        HStack(spacing: 4) {
            statusIcon
            BodySText(status.rawValue)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor)
        .cornerRadius(8)
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
                .font(.caption2)
        case .accepted:
            Image(systemName: "checkmark")
                .font(.caption2)
        case .declined:
            Image(systemName: "xmark")
                .font(.caption2)
        case .paid:
            Image(systemName: "checkmark.seal.fill")
                .font(.caption2)
        case .expired:
            Image(systemName: "clock.badge.exclamationmark")
                .font(.caption2)
        }
    }
    
    private var statusColor: Color {
        switch status {
        case .pending: return .orange
        case .accepted: return .greenAccent
        case .declined: return .redAccent
        case .expired: return .gray2
        case .paid: return .greenAccent
        }
    }
}

// MARK: - Payment Request Detail Sheet

struct PaymentRequestDetailSheet: View {
    let request: BitkitPaymentRequest
    @ObservedObject var viewModel: PaymentRequestsViewModel
    @EnvironmentObject private var app: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isProcessingPayment = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    statusSection
                    peerSection
                    methodSection
                    
                    if !request.description.isEmpty {
                        descriptionSection
                    }
                    
                    if request.status == .pending {
                        actionsSection
                    }
                }
                .padding(20)
            }
            .background(Color.gray5)
            .navigationTitle("Request Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(request.direction == .incoming ? Color.greenAccent.opacity(0.2) : Color.brandAccent.opacity(0.2))
                    .frame(width: 72, height: 72)
                
                Image(systemName: request.direction == .incoming ? "arrow.down" : "arrow.up")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(request.direction == .incoming ? .greenAccent : .brandAccent)
            }
            
            HeadlineText(formatSats(request.amountSats))
                .foregroundColor(.white)
            
            if !request.description.isEmpty {
                BodyMText(request.description)
                    .foregroundColor(.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyMBoldText("Status")
                .foregroundColor(.textSecondary)
            
            HStack {
                StatusBadge(status: request.status)
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    BodySText("Created")
                        .foregroundColor(.textSecondary)
                    BodySText(formatDate(request.createdAt))
                        .foregroundColor(.white)
                }
            }
            
            if let expiresAt = request.expiresAt {
                HStack {
                    Image(systemName: "clock")
                        .foregroundColor(.textSecondary)
                    
                    if expiresAt < Date() {
                        BodyMText("Expired on \(formatDate(expiresAt))")
                            .foregroundColor(.redAccent)
                    } else {
                        BodyMText("Expires \(formatDate(expiresAt))")
                            .foregroundColor(.orange)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(12)
    }
    
    private var peerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyMBoldText(request.direction == .incoming ? "From" : "To")
                .foregroundColor(.textSecondary)
            
            HStack {
                ZStack {
                    Circle()
                        .fill(Color.brandAccent.opacity(0.2))
                        .frame(width: 44, height: 44)
                    
                    Text(String(request.counterpartyName.prefix(1)).uppercased())
                        .font(.headline)
                        .foregroundColor(.brandAccent)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    BodyMBoldText(request.counterpartyName)
                        .foregroundColor(.white)
                    
                    BodySText(truncatePubkey(request.direction == .incoming ? request.fromPubkey : request.toPubkey))
                        .foregroundColor(.textSecondary)
                }
                
                Spacer()
                
                Button {
                    let pubkey = request.direction == .incoming ? request.fromPubkey : request.toPubkey
                    UIPasteboard.general.string = pubkey
                    app.toast(type: .success, title: "Copied to clipboard")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(.brandAccent)
                }
            }
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(12)
    }
    
    private var methodSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyMBoldText("Payment Method")
                .foregroundColor(.textSecondary)
            
            HStack {
                Image(systemName: methodIcon)
                    .foregroundColor(.brandAccent)
                
                BodyMText(request.methodId.capitalized)
                    .foregroundColor(.white)
                
                Spacer()
            }
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(12)
    }
    
    private var methodIcon: String {
        switch request.methodId.lowercased() {
        case "lightning": return "bolt.fill"
        case "onchain", "bitcoin": return "bitcoinsign.circle.fill"
        case "noise": return "antenna.radiowaves.left.and.right"
        default: return "creditcard.fill"
        }
    }
    
    private func metadataSection(_ metadata: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            BodyMBoldText("Invoice Details")
                .foregroundColor(.textSecondary)
            
            ForEach(Array(metadata.keys.sorted()), id: \.self) { key in
                if let value = metadata[key] {
                    HStack {
                        BodySText(key.capitalized)
                            .foregroundColor(.textSecondary)
                        Spacer()
                        BodySText(value)
                            .foregroundColor(.white)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(12)
    }
    
    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            BodyMBoldText("Description")
                .foregroundColor(.textSecondary)
            
            BodyMText(request.description)
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(12)
    }
    
    private var actionsSection: some View {
        VStack(spacing: 12) {
            if request.direction == .incoming {
                Button {
                    isProcessingPayment = true
                    executePayment()
                } label: {
                    HStack {
                        if isProcessingPayment {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Image(systemName: "bolt.fill")
                        }
                        BodyMBoldText("Pay Now")
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.greenAccent)
                    .cornerRadius(12)
                }
                .disabled(isProcessingPayment)
                
                HStack(spacing: 12) {
                    Button {
                        approveRequest()
                    } label: {
                        HStack {
                            Image(systemName: "checkmark")
                            BodyMText("Accept")
                        }
                        .foregroundColor(.greenAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.greenAccent.opacity(0.2))
                        .cornerRadius(12)
                    }
                    
                    Button {
                        declineRequest()
                    } label: {
                        HStack {
                            Image(systemName: "xmark")
                            BodyMText("Decline")
                        }
                        .foregroundColor(.redAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.redAccent.opacity(0.2))
                        .cornerRadius(12)
                    }
                }
            }
        }
    }
    
    private func executePayment() {
        Task {
            defer { isProcessingPayment = false }
            
            do {
                let result = try await PaykitPaymentService.shared.pay(
                    to: request.methodId == "lightning" ? "lightning:\(request.id)" : request.toPubkey,
                    amountSats: UInt64(request.amountSats),
                    peerPubkey: request.fromPubkey
                )
                
                if result.success {
                    var updated = request
                    updated.status = .paid
                    try viewModel.updateRequest(updated)
                    app.toast(type: .success, title: "Payment sent!")
                    dismiss()
                } else {
                    app.toast(type: .error, title: "Payment failed", description: result.error?.localizedDescription)
                }
            } catch {
                app.toast(error)
            }
        }
    }
    
    private func approveRequest() {
        do {
            var updated = request
            updated.status = .accepted
            try viewModel.updateRequest(updated)
            app.toast(type: .success, title: "Request accepted")
            dismiss()
        } catch {
            app.toast(error)
        }
    }
    
    private func declineRequest() {
        do {
            var updated = request
            updated.status = .declined
            try viewModel.updateRequest(updated)
            app.toast(type: .success, title: "Request declined")
            dismiss()
        } catch {
            app.toast(error)
        }
    }
    
    private func formatSats(_ amount: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: amount)) ?? "\(amount)") sats"
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    private func truncatePubkey(_ pubkey: String) -> String {
        guard pubkey.count > 16 else { return pubkey }
        return "\(pubkey.prefix(8))...\(pubkey.suffix(8))"
    }
}

struct CreatePaymentRequestView: View {
    @ObservedObject var viewModel: PaymentRequestsViewModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppViewModel
    
    @State private var toPubkey = ""
    @State private var amount: Int64 = 1000
    @State private var methodId = "lightning"
    @State private var description = ""
    @State private var expiresInDays: Int = 7
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        BodyLText("Recipient")
                            .foregroundColor(.textPrimary)
                        
                        TextField("Recipient Public Key (z-base32)", text: $toPubkey)
                            .foregroundColor(.white)
                            .autocapitalization(.none)
                            .padding(12)
                            .background(Color.gray6)
                            .cornerRadius(8)
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        BodyLText("Payment Details")
                            .foregroundColor(.textPrimary)
                        
                        HStack {
                            BodyMText("Amount:")
                                .foregroundColor(.textSecondary)
                            Spacer()
                            TextField("sats", text: Binding(
                                get: { String(amount) },
                                set: { amount = Int64($0) ?? 0 }
                            ))
                                .foregroundColor(.white)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .padding(12)
                                .background(Color.gray6)
                                .cornerRadius(8)
                                .frame(width: 120)
                        }
                        
                        Picker("Payment Method", selection: $methodId) {
                            Text("Lightning").tag("lightning")
                            Text("On-Chain").tag("onchain")
                        }
                        .pickerStyle(.segmented)
                        
                        TextField("Description (optional)", text: $description)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.gray6)
                            .cornerRadius(8)
                        
                        HStack {
                            BodyMText("Expires in:")
                                .foregroundColor(.textSecondary)
                            Spacer()
                            Picker("Days", selection: $expiresInDays) {
                                Text("1 day").tag(1)
                                Text("7 days").tag(7)
                                Text("30 days").tag(30)
                                Text("90 days").tag(90)
                            }
                        }
                    }
                    
                    Button {
                        let expiresAt = Calendar.current.date(byAdding: .day, value: expiresInDays, to: Date())
                        let fromPubkey = PaykitKeyManager.shared.getCurrentPublicKeyZ32() ?? ""
                        
                        let request = BitkitPaymentRequest(
                            id: UUID().uuidString,
                            fromPubkey: fromPubkey,
                            toPubkey: toPubkey,
                            amountSats: amount,
                            currency: "SAT",
                            methodId: methodId,
                            description: description,
                            createdAt: Date(),
                            expiresAt: expiresAt,
                            status: .pending,
                            direction: .outgoing
                        )
                        
                        do {
                            try viewModel.addRequest(request)
                            app.toast(type: .success, title: "Request created")
                            dismiss()
                        } catch {
                            app.toast(error)
                        }
                    } label: {
                        BodyMText("Create Request")
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.brandAccent)
                            .cornerRadius(8)
                    }
                    .disabled(toPubkey.isEmpty || amount <= 0)
                }
                .padding(16)
            }
            .navigationTitle("Create Request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// ViewModel for Payment Requests
@MainActor
class PaymentRequestsViewModel: ObservableObject {
    @Published var requests: [BitkitPaymentRequest] = []
    @Published var isLoading = false
    
    private let storage: PaymentRequestStorage
    private let identityName: String
    
    init(identityName: String = "default") {
        self.identityName = identityName
        self.storage = PaymentRequestStorage(identityName: identityName)
    }
    
    func loadRequests() {
        isLoading = true
        requests = storage.listRequests()
        isLoading = false
    }
    
    func addRequest(_ request: BitkitPaymentRequest) throws {
        try storage.addRequest(request)
        loadRequests()
    }
    
    func updateRequest(_ request: BitkitPaymentRequest) throws {
        try storage.updateRequest(request)
        loadRequests()
    }
    
    func deleteRequest(_ request: BitkitPaymentRequest) throws {
        try storage.deleteRequest(id: request.id)
        loadRequests()
    }
}


