//
//  ContactDiscoveryView.swift
//  Bitkit
//
//  Contact discovery from Pubky follows directory
//

import SwiftUI

struct ContactDiscoveryView: View {
    @StateObject private var viewModel = ContactDiscoveryViewModel()
    @EnvironmentObject private var app: AppViewModel
    @State private var searchQuery = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: "Discover Contacts")
            
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    // Info Section
                    infoSection
                    
                    // Search Section
                    searchSection
                    
                    // Results
                    if viewModel.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    } else if viewModel.discoveredContacts.isEmpty {
                        emptyStateView
                    } else {
                        discoveredContactsList
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            viewModel.loadFollows()
        }
    }
    
    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            BodyLText("Discover from Pubky")
                .foregroundColor(.textPrimary)
            
            BodyMText("Find contacts from your Pubky follows directory. Contacts with published payment endpoints will appear here.")
                .foregroundColor(.textSecondary)
        }
        .padding(16)
        .background(Color.gray900)
        .cornerRadius(8)
    }
    
    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.textSecondary)
                
                TextField("Search by name or pubkey", text: $searchQuery)
                    .foregroundColor(.white)
                    .onChange(of: searchQuery) { newValue in
                        viewModel.search(query: newValue)
                    }
            }
            .padding(12)
            .background(Color.gray900)
            .cornerRadius(8)
        }
    }
    
    private var discoveredContactsList: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.discoveredContacts) { contact in
                DiscoveredContactRow(contact: contact, viewModel: viewModel)
                
                if contact.id != viewModel.discoveredContacts.last?.id {
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
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 80))
                .foregroundColor(.textSecondary)
            
            BodyLText("No Contacts Found")
                .foregroundColor(.textPrimary)
            
            BodyMText("No contacts with payment endpoints found in your follows directory")
                .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

struct DiscoveredContactRow: View {
    let contact: DiscoveredContact
    @ObservedObject var viewModel: ContactDiscoveryViewModel
    @EnvironmentObject private var app: AppViewModel
    
    var body: some View {
        HStack {
            Circle()
                .fill(Color.brandAccent.opacity(0.2))
                .frame(width: 40, height: 40)
                .overlay {
                    Text(String(contact.name.prefix(1)).uppercased())
                        .foregroundColor(.brandAccent)
                        .font(.headline)
                }
            
            VStack(alignment: .leading, spacing: 4) {
                BodyMBoldText(contact.name)
                    .foregroundColor(.white)
                
                BodySText(contact.abbreviatedPubkey)
                    .foregroundColor(.textSecondary)
                
                if !contact.paymentMethods.isEmpty {
                    BodySText("\(contact.paymentMethods.count) payment method\(contact.paymentMethods.count == 1 ? "" : "s")")
                        .foregroundColor(.brandAccent)
                }
            }
            
            Spacer()
            
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
                    .font(.title3)
            }
        }
        .padding(16)
    }
}

// ViewModel for Contact Discovery
@MainActor
class ContactDiscoveryViewModel: ObservableObject {
    @Published var discoveredContacts: [DiscoveredContact] = []
    @Published var isLoading = false
    
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
                // Discover contacts from Pubky follows directory
                let contacts = try await directoryService.discoverContactsFromFollows()
                
                await MainActor.run {
                    self.discoveredContacts = contacts
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
    
    func search(query: String) {
        if query.isEmpty {
            loadFollows()
        } else {
            let queryLower = query.lowercased()
            discoveredContacts = discoveredContacts.filter { contact in
                contact.name.lowercased().contains(queryLower) ||
                contact.pubkey.lowercased().contains(queryLower)
            }
        }
    }
    
    func addContact(_ discoveredContact: DiscoveredContact) throws {
        let contact = Contact(
            publicKeyZ32: discoveredContact.pubkey,
            name: discoveredContact.name,
            notes: "Discovered from Pubky follows"
        )
        try contactStorage.saveContact(contact)
    }
}

// Model for discovered contacts
struct DiscoveredContact: Identifiable {
    let id: String
    let pubkey: String
    let name: String
    let paymentMethods: [String]
    
    var abbreviatedPubkey: String {
        guard pubkey.count > 16 else { return pubkey }
        let prefix = pubkey.prefix(8)
        let suffix = pubkey.suffix(8)
        return "\(prefix)...\(suffix)"
    }
}

