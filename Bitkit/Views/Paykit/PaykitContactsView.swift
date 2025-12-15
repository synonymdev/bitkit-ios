//
//  PaykitContactsView.swift
//  Bitkit
//
//  Contact list and management view
//

import SwiftUI

struct PaykitContactsView: View {
    @StateObject private var viewModel = ContactsViewModel()
    @State private var showingAddContact = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(title: "Contacts")
            
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.textSecondary)
                        
                        TextField("Search contacts", text: $viewModel.searchQuery)
                            .foregroundColor(.white)
                            .onChange(of: viewModel.searchQuery) { _ in
                                viewModel.searchContacts()
                            }
                    }
                    .padding(12)
                    .background(Color.gray900)
                    .cornerRadius(8)
                    
                    // Contact list
                    if viewModel.contacts.isEmpty {
                        EmptyStateView(
                            type: .home,
                            onClose: nil
                        )
                    } else {
                        VStack(spacing: 0) {
                            ForEach(viewModel.contacts) { contact in
                                ContactRow(contact: contact)
                                
                                if contact.id != viewModel.contacts.last?.id {
                                    Divider()
                                        .background(Color.white16)
                                }
                            }
                        }
                        .background(Color.gray900)
                        .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            viewModel.loadContacts()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingAddContact = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundColor(.brandAccent)
                }
            }
        }
        .sheet(isPresented: $showingAddContact) {
            AddContactView(viewModel: viewModel)
        }
    }
}

struct ContactRow: View {
    let contact: Contact
    
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
                BodyMText(contact.name)
                    .foregroundColor(.white)
                
                BodySText(contact.abbreviatedKey)
                    .foregroundColor(.textSecondary)
            }
            
            Spacer()
            
            if contact.paymentCount > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    BodySText("\(contact.paymentCount) payment\(contact.paymentCount == 1 ? "" : "s")")
                        .foregroundColor(.textSecondary)
                    
                    if let lastPayment = contact.lastPaymentAt {
                        BodySText(formatDate(lastPayment))
                            .foregroundColor(.textSecondary)
                    }
                }
            }
        }
        .padding(16)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct AddContactView: View {
    @ObservedObject var viewModel: ContactsViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var name = ""
    @State private var publicKey = ""
    @State private var notes = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section("Contact Information") {
                    TextField("Name", text: $name)
                    TextField("Public Key (z-base32)", text: $publicKey)
                    TextField("Notes (optional)", text: $notes)
                }
            }
            .navigationTitle("Add Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        let contact = Contact(
                            publicKeyZ32: publicKey,
                            name: name,
                            notes: notes.isEmpty ? nil : notes
                        )
                        do {
                            try viewModel.addContact(contact)
                            dismiss()
                        } catch {
                            // Handle error
                        }
                    }
                    .disabled(name.isEmpty || publicKey.isEmpty)
                }
            }
        }
    }
}

