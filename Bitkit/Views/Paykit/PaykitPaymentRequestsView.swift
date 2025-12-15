//
//  PaykitPaymentRequestsView.swift
//  Bitkit
//
//  Payment requests management view
//

import SwiftUI

struct PaykitPaymentRequestsView: View {
    @StateObject private var viewModel = PaymentRequestsViewModel()
    @EnvironmentObject private var app: AppViewModel
    @State private var showingCreateRequest = false
    @State private var selectedFilter: RequestFilter = .all
    
    enum RequestFilter: String, CaseIterable {
        case all = "All"
        case incoming = "Incoming"
        case outgoing = "Outgoing"
        case pending = "Pending"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: "Payment Requests")
            
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    // Filter Picker
                    filterSection
                    
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
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            viewModel.loadRequests()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingCreateRequest = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundColor(.brandAccent)
                }
            }
        }
        .sheet(isPresented: $showingCreateRequest) {
            CreatePaymentRequestView(viewModel: viewModel)
        }
    }
    
    private var filterSection: some View {
        Picker("Filter", selection: $selectedFilter) {
            ForEach(RequestFilter.allCases, id: \.self) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.segmented)
    }
    
    private var filteredRequests: [PaymentRequest] {
        let all = viewModel.requests
        switch selectedFilter {
        case .all:
            return all
        case .incoming:
            return all.filter { $0.direction == .incoming }
        case .outgoing:
            return all.filter { $0.direction == .outgoing }
        case .pending:
            return all.filter { $0.status == .pending }
        }
    }
    
    private var requestsList: some View {
        VStack(spacing: 0) {
            ForEach(filteredRequests) { request in
                PaymentRequestRow(request: request, viewModel: viewModel)
                
                if request.id != filteredRequests.last?.id {
                    Divider()
                        .background(Color.white16)
                }
            }
        }
        .background(Color.gray900)
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
}

struct PaymentRequestRow: View {
    let request: PaymentRequest
    @ObservedObject var viewModel: PaymentRequestsViewModel
    @EnvironmentObject private var app: AppViewModel
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    BodyMBoldText(request.counterpartyName)
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    StatusBadge(status: request.status)
                }
                
                BodyMText("\(formatSats(request.amountSats)) via \(request.methodId)")
                    .foregroundColor(.textSecondary)
                
                if !request.description.isEmpty {
                    BodySText(request.description)
                        .foregroundColor(.textSecondary)
                }
                
                HStack {
                    BodySText(request.direction == .incoming ? "Incoming" : "Outgoing")
                        .foregroundColor(.textSecondary)
                    
                    if let expiresAt = request.expiresAt {
                        BodySText("• Expires: \(formatDate(expiresAt))")
                            .foregroundColor(.textSecondary)
                    }
                }
            }
            
            if request.direction == .incoming && request.status == .pending {
                Spacer()
                
                VStack(spacing: 8) {
                    Button {
                        do {
                            var updated = request
                            updated.status = .accepted
                            try viewModel.updateRequest(updated)
                            app.toast(type: .success, title: "Request accepted")
                        } catch {
                            app.toast(error)
                        }
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.greenAccent)
                            .font(.title3)
                    }
                    
                    Button {
                        do {
                            var updated = request
                            updated.status = .declined
                            try viewModel.updateRequest(updated)
                            app.toast(type: .success, title: "Request declined")
                        } catch {
                            app.toast(error)
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.redAccent)
                            .font(.title3)
                    }
                }
            }
        }
        .padding(16)
    }
    
    private func formatSats(_ amount: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: amount)) ?? "\(amount)") sats"
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct StatusBadge: View {
    let status: PaymentRequestStatus
    
    var body: some View {
        BodySText(status.rawValue)
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor)
            .cornerRadius(8)
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
                            .background(Color.gray900)
                            .cornerRadius(8)
                    }
                    
                    VStack(alignment: .leading, spacing: 12) {
                        BodyLText("Payment Details")
                            .foregroundColor(.textPrimary)
                        
                        HStack {
                            BodyMText("Amount:")
                                .foregroundColor(.textSecondary)
                            Spacer()
                            TextField("sats", value: $amount, format: .number)
                                .foregroundColor(.white)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .padding(12)
                                .background(Color.gray900)
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
                            .background(Color.gray900)
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
                        // TODO: Get current user's pubkey
                        let fromPubkey = "current_user_pubkey" // Replace with actual
                        
                        let request = PaymentRequest(
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
    @Published var requests: [PaymentRequest] = []
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
    
    func addRequest(_ request: PaymentRequest) throws {
        try storage.addRequest(request)
        loadRequests()
    }
    
    func updateRequest(_ request: PaymentRequest) throws {
        try storage.updateRequest(request)
        loadRequests()
    }
    
    func deleteRequest(_ request: PaymentRequest) throws {
        try storage.deleteRequest(id: request.id)
        loadRequests()
    }
}

