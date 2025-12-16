//
//  ContactDiscoveryView.swift
//  Bitkit
//
//  Contact discovery from Pubky follows directory with method health status
//

import SwiftUI

struct ContactDiscoveryView: View {
    @StateObject private var viewModel = ContactDiscoveryViewModel()
    @EnvironmentObject private var app: AppViewModel
    @State private var searchQuery = ""
    @State private var filterMethod: String? = nil
    @State private var showingFilters = false
    @State private var selectedContact: DirectoryDiscoveredContact? = nil
    @State private var showingContactDetail = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(
                title: "Discover Contacts",
                action: AnyView(
                    HStack(spacing: 12) {
                        Button {
                            showingFilters.toggle()
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .foregroundColor(filterMethod != nil ? .brandAccent : .textSecondary)
                        }
                        
                        Button {
                            viewModel.refreshDiscovery()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.brandAccent)
                        }
                    }
                )
            )
            
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    // Directory Health Status
                    directoryHealthCard
                    
                    // Search Section
                    searchSection
                    
                    // Method Filters
                    if showingFilters {
                        methodFiltersSection
                    }
                    
                    // Results
                    if viewModel.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    } else if filteredContacts.isEmpty {
                        emptyStateView
                    } else {
                        // Summary
                        HStack {
                            BodySText("\(filteredContacts.count) contact\(filteredContacts.count == 1 ? "" : "s") found")
                                .foregroundColor(.textSecondary)
                            
                            Spacer()
                            
                            BodySText("\(viewModel.totalHealthyEndpoints) healthy endpoint\(viewModel.totalHealthyEndpoints == 1 ? "" : "s")")
                                .foregroundColor(.greenAccent)
                        }
                        
                        discoveredContactsList
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            viewModel.loadFollows()
        }
        .refreshable {
            viewModel.refreshDiscovery()
        }
        .sheet(isPresented: $showingContactDetail) {
            if let contact = selectedContact {
                ContactDetailSheet(contact: contact, viewModel: viewModel)
            }
        }
    }
    
    // MARK: - Directory Health Card
    
    private var directoryHealthCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    Circle()
                        .fill(viewModel.directoryHealthColor.opacity(0.2))
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: viewModel.directoryHealthIcon)
                        .foregroundColor(viewModel.directoryHealthColor)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    BodyMBoldText("Directory Status")
                        .foregroundColor(.white)
                    
                    BodySText(viewModel.directoryHealthMessage)
                        .foregroundColor(.textSecondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    BodySText("Last sync")
                        .foregroundColor(.textSecondary)
                    BodySText(viewModel.lastSyncText)
                        .foregroundColor(.white)
                }
            }
            
            // Method health breakdown
            HStack(spacing: 16) {
                methodHealthPill(method: "lightning", count: viewModel.lightningEndpoints, healthy: viewModel.healthyLightningEndpoints)
                methodHealthPill(method: "onchain", count: viewModel.onchainEndpoints, healthy: viewModel.healthyOnchainEndpoints)
                methodHealthPill(method: "noise", count: viewModel.noiseEndpoints, healthy: viewModel.healthyNoiseEndpoints)
            }
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(12)
    }
    
    private func methodHealthPill(method: String, count: Int, healthy: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: methodIcon(method))
                .font(.caption)
            
            BodySText("\(healthy)/\(count)")
        }
        .foregroundColor(healthy == count ? .greenAccent : (healthy > 0 ? .orange : .redAccent))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((healthy == count ? Color.greenAccent : (healthy > 0 ? Color.orange : Color.redAccent)).opacity(0.2))
        .cornerRadius(12)
    }
    
    private func methodIcon(_ method: String) -> String {
        switch method {
        case "lightning": return "bolt.fill"
        case "onchain": return "bitcoinsign.circle.fill"
        case "noise": return "antenna.radiowaves.left.and.right"
        default: return "creditcard.fill"
        }
    }
    
    private var searchSection: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.textSecondary)
            
            TextField("Search by name or pubkey", text: $searchQuery)
                .foregroundColor(.white)
            
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
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
    
    private var methodFiltersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            BodySText("Filter by method")
                .foregroundColor(.textSecondary)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    DiscoveryFilterChip(title: "All", isSelected: filterMethod == nil) {
                        filterMethod = nil
                    }
                    DiscoveryFilterChip(title: "⚡ Lightning", isSelected: filterMethod == "lightning") {
                        filterMethod = "lightning"
                    }
                    DiscoveryFilterChip(title: "₿ On-chain", isSelected: filterMethod == "onchain") {
                        filterMethod = "onchain"
                    }
                    DiscoveryFilterChip(title: "📡 Noise", isSelected: filterMethod == "noise") {
                        filterMethod = "noise"
                    }
                }
            }
        }
        .padding(12)
        .background(Color.gray5)
        .cornerRadius(8)
    }
    
    private var filteredContacts: [DirectoryDiscoveredContact] {
        var results = viewModel.discoveredContacts
        
        // Search filter
        if !searchQuery.isEmpty {
            let query = searchQuery.lowercased()
            results = results.filter {
                ($0.name?.lowercased().contains(query) ?? false) ||
                $0.pubkey.lowercased().contains(query)
            }
        }
        
        // Method filter
        if let method = filterMethod {
            results = results.filter { $0.supportedMethods.contains(method) }
        }
        
        return results
    }
    
    private var discoveredContactsList: some View {
        VStack(spacing: 0) {
            ForEach(filteredContacts) { contact in
                Button {
                    selectedContact = contact
                    showingContactDetail = true
                } label: {
                    DiscoveredContactRow(contact: contact, viewModel: viewModel)
                }
                .buttonStyle(.plain)
                
                if contact.id != filteredContacts.last?.id {
                    Divider()
                        .background(Color.white16)
                }
            }
        }
        .background(Color.gray6)
        .cornerRadius(12)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 80))
                .foregroundColor(.textSecondary)
            
            BodyLText("No Contacts Found")
                .foregroundColor(.textPrimary)
            
            BodyMText(filterMethod != nil ?
                "No contacts with \(filterMethod!) endpoints found" :
                "No contacts with payment endpoints found in your follows directory"
            )
            .foregroundColor(.textSecondary)
            .multilineTextAlignment(.center)
            
            Button {
                filterMethod = nil
                viewModel.refreshDiscovery()
            } label: {
                BodyMText("Refresh Discovery")
                    .foregroundColor(.brandAccent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

struct DiscoveredContactRow: View {
    let contact: DirectoryDiscoveredContact
    @ObservedObject var viewModel: ContactDiscoveryViewModel
    @EnvironmentObject private var app: AppViewModel
    
    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.brandAccent.opacity(0.2))
                .frame(width: 48, height: 48)
                .overlay {
                    Text(String((contact.name ?? contact.pubkey).prefix(1)).uppercased())
                        .foregroundColor(.brandAccent)
                        .font(.headline)
                }
            
            VStack(alignment: .leading, spacing: 4) {
                BodyMBoldText(contact.name ?? contact.pubkey)
                    .foregroundColor(.white)
                
                BodySText(contact.abbreviatedPubkey)
                    .foregroundColor(.textSecondary)
                
                // Method health indicators
                HStack(spacing: 8) {
                    ForEach(contact.supportedMethods, id: \.self) { method in
                        methodHealthIndicator(method: method, isHealthy: contact.isMethodHealthy(method))
                    }
                }
            }
            
            Spacer()
            
            // Overall health indicator
            VStack(spacing: 4) {
                Image(systemName: contact.overallHealthIcon)
                    .foregroundColor(contact.overallHealthColor)
                    .font(.title3)
                
                BodySText(contact.healthStatus)
                    .foregroundColor(contact.overallHealthColor)
            }
            
            Button {
                do {
                    try viewModel.addContact(contact)
                    app.toast(type: .success, title: "Contact added")
                } catch {
                    app.toast(error)
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(.brandAccent)
                    .font(.title2)
            }
        }
        .padding(16)
    }
    
    private func methodHealthIndicator(method: String, isHealthy: Bool) -> some View {
        HStack(spacing: 2) {
            Image(systemName: methodIcon(method))
                .font(.caption2)
            Circle()
                .fill(isHealthy ? Color.greenAccent : Color.redAccent)
                .frame(width: 6, height: 6)
        }
        .foregroundColor(isHealthy ? .greenAccent : .redAccent)
    }
    
    private func methodIcon(_ method: String) -> String {
        switch method {
        case "lightning": return "bolt.fill"
        case "onchain": return "bitcoinsign.circle.fill"
        case "noise": return "antenna.radiowaves.left.and.right"
        default: return "creditcard.fill"
        }
    }
}

// MARK: - Contact Detail Sheet

struct ContactDetailSheet: View {
    let contact: DirectoryDiscoveredContact
    @ObservedObject var viewModel: ContactDiscoveryViewModel
    @EnvironmentObject private var app: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isCheckingHealth = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    headerSection
                    
                    // Endpoints section
                    endpointsSection
                    
                    // Actions
                    actionsSection
                }
                .padding(20)
            }
            .background(Color.gray5)
            .navigationTitle("Contact Details")
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
            Circle()
                .fill(Color.brandAccent.opacity(0.2))
                .frame(width: 80, height: 80)
                .overlay {
                    Text(String((contact.name ?? contact.pubkey).prefix(1)).uppercased())
                        .foregroundColor(.brandAccent)
                        .font(.largeTitle)
                }
            
            HeadlineText(contact.name ?? "Unknown")
                .foregroundColor(.white)
            
            Button {
                UIPasteboard.general.string = contact.pubkey
                app.toast(type: .success, title: "Copied to clipboard")
            } label: {
                HStack(spacing: 4) {
                    BodySText(contact.abbreviatedPubkey)
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .foregroundColor(.brandAccent)
            }
            
            // Overall health status
            HStack(spacing: 4) {
                Circle()
                    .fill(contact.overallHealthColor)
                    .frame(width: 8, height: 8)
                BodyMText(contact.healthStatus)
                    .foregroundColor(contact.overallHealthColor)
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    private var endpointsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                BodyMBoldText("Payment Endpoints")
                    .foregroundColor(.textSecondary)
                
                Spacer()
                
                Button {
                    checkHealth()
                } label: {
                    HStack(spacing: 4) {
                        if isCheckingHealth {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .brandAccent))
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        BodySText("Check")
                    }
                    .foregroundColor(.brandAccent)
                }
                .disabled(isCheckingHealth)
            }
            
            VStack(spacing: 0) {
                ForEach(contact.supportedMethods, id: \.self) { method in
                    EndpointRow(
                        method: method,
                        isHealthy: contact.isMethodHealthy(method),
                        lastChecked: contact.lastHealthCheck(method)
                    )
                    
                    if method != contact.supportedMethods.last {
                        Divider().background(Color.white16)
                    }
                }
            }
            .background(Color.gray6)
            .cornerRadius(12)
        }
    }
    
    private var actionsSection: some View {
        VStack(spacing: 12) {
            Button {
                do {
                    try viewModel.addContact(contact)
                    app.toast(type: .success, title: "Contact added!")
                    dismiss()
                } catch {
                    app.toast(error)
                }
            } label: {
                HStack {
                    Image(systemName: "person.badge.plus")
                    BodyMBoldText("Add to Contacts")
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.brandAccent)
                .cornerRadius(12)
            }
            
            Button {
                // Navigate to send payment
            } label: {
                HStack {
                    Image(systemName: "paperplane.fill")
                    BodyMText("Send Payment")
                }
                .foregroundColor(.brandAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.brandAccent.opacity(0.2))
                .cornerRadius(12)
            }
        }
    }
    
    private func checkHealth() {
        isCheckingHealth = true
        Task {
            await viewModel.checkEndpointHealth(for: contact)
            isCheckingHealth = false
        }
    }
}

struct EndpointRow: View {
    let method: String
    let isHealthy: Bool
    let lastChecked: Date?
    
    var body: some View {
        HStack {
            Image(systemName: methodIcon)
                .foregroundColor(isHealthy ? .greenAccent : .redAccent)
                .frame(width: 28)
            
            VStack(alignment: .leading, spacing: 2) {
                BodyMText(methodName)
                    .foregroundColor(.white)
                
                if let date = lastChecked {
                    BodySText("Checked \(formatDate(date))")
                        .foregroundColor(.textSecondary)
                }
            }
            
            Spacer()
            
            HStack(spacing: 4) {
                Circle()
                    .fill(isHealthy ? Color.greenAccent : Color.redAccent)
                    .frame(width: 8, height: 8)
                BodySText(isHealthy ? "Healthy" : "Unreachable")
                    .foregroundColor(isHealthy ? .greenAccent : .redAccent)
            }
        }
        .padding(16)
    }
    
    private var methodIcon: String {
        switch method {
        case "lightning": return "bolt.fill"
        case "onchain": return "bitcoinsign.circle.fill"
        case "noise": return "antenna.radiowaves.left.and.right"
        default: return "creditcard.fill"
        }
    }
    
    private var methodName: String {
        switch method {
        case "lightning": return "Lightning Network"
        case "onchain": return "On-Chain Bitcoin"
        case "noise": return "Noise Protocol"
        default: return method.capitalized
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// ViewModel for Contact Discovery
@MainActor
class ContactDiscoveryViewModel: ObservableObject {
    @Published var discoveredContacts: [DirectoryDiscoveredContact] = []
    @Published var isLoading = false
    @Published var lastSyncDate: Date?
    
    // Health tracking
    @Published var lightningEndpoints = 0
    @Published var healthyLightningEndpoints = 0
    @Published var onchainEndpoints = 0
    @Published var healthyOnchainEndpoints = 0
    @Published var noiseEndpoints = 0
    @Published var healthyNoiseEndpoints = 0
    
    var totalHealthyEndpoints: Int {
        healthyLightningEndpoints + healthyOnchainEndpoints + healthyNoiseEndpoints
    }
    
    var directoryHealthColor: Color {
        if discoveredContacts.isEmpty { return .textSecondary }
        let healthyPercent = Double(totalHealthyEndpoints) / Double(lightningEndpoints + onchainEndpoints + noiseEndpoints)
        if healthyPercent >= 0.8 { return .greenAccent }
        if healthyPercent >= 0.5 { return .orange }
        return .redAccent
    }
    
    var directoryHealthIcon: String {
        if discoveredContacts.isEmpty { return "antenna.radiowaves.left.and.right.slash" }
        let healthyPercent = Double(totalHealthyEndpoints) / Double(max(1, lightningEndpoints + onchainEndpoints + noiseEndpoints))
        if healthyPercent >= 0.8 { return "checkmark.shield.fill" }
        if healthyPercent >= 0.5 { return "exclamationmark.shield.fill" }
        return "xmark.shield.fill"
    }
    
    var directoryHealthMessage: String {
        if discoveredContacts.isEmpty { return "No contacts discovered yet" }
        return "\(totalHealthyEndpoints) of \(lightningEndpoints + onchainEndpoints + noiseEndpoints) endpoints healthy"
    }
    
    var lastSyncText: String {
        guard let date = lastSyncDate else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    private let directoryService: DirectoryService
    private let contactStorage: ContactStorage
    private let identityName: String
    
    init(identityName: String = "default") {
        self.identityName = identityName
        self.directoryService = DirectoryService()
        self.contactStorage = ContactStorage(identityName: identityName)
    }
    
    func loadFollows() {
        isLoading = true
        
        Task {
            do {
                let contacts = try await directoryService.discoverContactsFromFollows()
                
                await MainActor.run {
                    self.discoveredContacts = contacts
                    self.lastSyncDate = Date()
                    self.updateHealthStats()
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    Logger.error("ContactDiscovery: Failed to load follows: \(error)", context: "ContactDiscovery")
                }
            }
        }
    }
    
    func refreshDiscovery() {
        loadFollows()
    }
    
    private func updateHealthStats() {
        lightningEndpoints = 0
        healthyLightningEndpoints = 0
        onchainEndpoints = 0
        healthyOnchainEndpoints = 0
        noiseEndpoints = 0
        healthyNoiseEndpoints = 0
        
        for contact in discoveredContacts {
            for method in contact.supportedMethods {
                switch method {
                case "lightning":
                    lightningEndpoints += 1
                    if contact.isMethodHealthy(method) { healthyLightningEndpoints += 1 }
                case "onchain":
                    onchainEndpoints += 1
                    if contact.isMethodHealthy(method) { healthyOnchainEndpoints += 1 }
                case "noise":
                    noiseEndpoints += 1
                    if contact.isMethodHealthy(method) { healthyNoiseEndpoints += 1 }
                default:
                    break
                }
            }
        }
    }
    
    func search(query: String) {
        if query.isEmpty {
            loadFollows()
        } else {
            let queryLower = query.lowercased()
            discoveredContacts = discoveredContacts.filter { contact in
                (contact.name?.lowercased().contains(queryLower) ?? false) ||
                contact.pubkey.lowercased().contains(queryLower)
            }
        }
    }
    
    func addContact(_ discoveredContact: DirectoryDiscoveredContact) throws {
        let contact = Contact(
            publicKeyZ32: discoveredContact.pubkey,
            name: discoveredContact.name ?? discoveredContact.pubkey,
            notes: "Discovered from Pubky follows"
        )
        try contactStorage.saveContact(contact)
    }
    
    func checkEndpointHealth(for contact: DirectoryDiscoveredContact) async {
        // TODO: Implement endpoint health check when DirectoryService supports it
        // For now, just refresh data
        loadFollows()
    }
}

// Extension for DirectoryDiscoveredContact view convenience
extension DirectoryDiscoveredContact {
    var abbreviatedPubkey: String {
        guard pubkey.count > 16 else { return pubkey }
        let prefix = pubkey.prefix(8)
        let suffix = pubkey.suffix(8)
        return "\(prefix)...\(suffix)"
    }
    
    var paymentMethods: [String] {
        return supportedMethods
    }
    
    func isMethodHealthy(_ method: String) -> Bool {
        // Check if method endpoint is reachable
        // For now, assume healthy if method is supported
        // In real implementation, this would check endpoint health cache
        return endpointHealth[method] ?? true
    }
    
    func lastHealthCheck(_ method: String) -> Date? {
        return lastHealthCheckDates[method]
    }
    
    var healthyMethodCount: Int {
        supportedMethods.filter { isMethodHealthy($0) }.count
    }
    
    var healthStatus: String {
        if supportedMethods.isEmpty { return "No endpoints" }
        if healthyMethodCount == supportedMethods.count { return "All healthy" }
        if healthyMethodCount > 0 { return "\(healthyMethodCount)/\(supportedMethods.count) healthy" }
        return "Unreachable"
    }
    
    var overallHealthColor: Color {
        if supportedMethods.isEmpty { return .textSecondary }
        if healthyMethodCount == supportedMethods.count { return .greenAccent }
        if healthyMethodCount > 0 { return .orange }
        return .redAccent
    }
    
    var overallHealthIcon: String {
        if supportedMethods.isEmpty { return "questionmark.circle" }
        if healthyMethodCount == supportedMethods.count { return "checkmark.circle.fill" }
        if healthyMethodCount > 0 { return "exclamationmark.circle.fill" }
        return "xmark.circle.fill"
    }
}

private struct DiscoveryFilterChip: View {
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

