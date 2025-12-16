//
//  ProfileImportView.swift
//  Bitkit
//
//  Import profile from Pubky-app via Pubky-ring
//

import SwiftUI

struct ProfileImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = false
    @State private var profile: PubkyProfile?
    @State private var errorMessage: String?
    @State private var pubkeyToImport: String = ""
    @State private var importedSuccessfully = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(
                title: "Import Profile",
                leftButton: NavigationBarButton(
                    type: .close,
                    action: { dismiss() }
                )
            )
            
            ScrollView {
                VStack(spacing: 24) {
                    // Instructions
                    VStack(alignment: .leading, spacing: 12) {
                        BodyMText("Import your profile from the Pubky directory. This will sync your name, bio, and other profile information.")
                            .foregroundColor(.textSecondary)
                    }
                    .padding(.horizontal, 16)
                    
                    // Pubkey input
                    VStack(alignment: .leading, spacing: 8) {
                        BodySText("Public Key (z-base32)")
                            .foregroundColor(.textSecondary)
                        
                        TextField("Enter pubkey to import from", text: $pubkeyToImport)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(Color.gray6)
                            .cornerRadius(8)
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 16)
                    
                    // Search button
                    Button {
                        Task {
                            await lookupProfile()
                        }
                    } label: {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .frame(width: 20, height: 20)
                            } else {
                                Image(systemName: "magnifyingglass")
                            }
                            Text("Lookup Profile")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(pubkeyToImport.isEmpty ? Color.gray6 : Color.brandAccent)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    .disabled(pubkeyToImport.isEmpty || isLoading)
                    .padding(.horizontal, 16)
                    
                    // Error message
                    if let error = errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            BodySText(error)
                                .foregroundColor(.red)
                        }
                        .padding(.horizontal, 16)
                    }
                    
                    // Profile preview
                    if let profile = profile {
                        ProfilePreviewCard(profile: profile)
                            .padding(.horizontal, 16)
                        
                        // Import button
                        Button {
                            Task {
                                await importProfile()
                            }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.down.circle.fill")
                                Text("Import This Profile")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                        .padding(.horizontal, 16)
                    }
                    
                    // Success message
                    if importedSuccessfully {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            BodyMText("Profile imported successfully!")
                                .foregroundColor(.green)
                        }
                        .padding(.horizontal, 16)
                    }
                    
                    Spacer()
                }
                .padding(.top, 16)
            }
        }
        .background(Color.gray8)
        .onAppear {
            // Pre-fill with current pubkey if available
            if let currentPubkey = PaykitKeyManager.shared.getCurrentPublicKeyZ32() {
                pubkeyToImport = currentPubkey
            }
        }
    }
    
    private func lookupProfile() async {
        isLoading = true
        errorMessage = nil
        profile = nil
        
        do {
            let fetchedProfile = try await DirectoryService.shared.fetchProfile(for: pubkeyToImport)
            await MainActor.run {
                if let fetchedProfile = fetchedProfile {
                    self.profile = fetchedProfile
                } else {
                    self.errorMessage = "No profile found for this public key"
                }
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }
    
    private func importProfile() async {
        guard let profile = profile else { return }
        
        isLoading = true
        errorMessage = nil
        
        do {
            try await DirectoryService.shared.publishProfile(profile)
            await MainActor.run {
                self.importedSuccessfully = true
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }
}

struct ProfilePreviewCard: View {
    let profile: PubkyProfile
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                // Avatar placeholder
                Circle()
                    .fill(Color.brandAccent.opacity(0.2))
                    .frame(width: 60, height: 60)
                    .overlay {
                        if let name = profile.name {
                            Text(String(name.prefix(1)).uppercased())
                                .font(.title2)
                                .foregroundColor(.brandAccent)
                        } else {
                            Image(systemName: "person.fill")
                                .foregroundColor(.brandAccent)
                        }
                    }
                
                VStack(alignment: .leading, spacing: 4) {
                    if let name = profile.name {
                        BodyLText(name)
                            .foregroundColor(.white)
                    }
                    
                    if let bio = profile.bio {
                        BodySText(bio)
                            .foregroundColor(.textSecondary)
                            .lineLimit(2)
                    }
                }
            }
            
            // Links
            if let links = profile.links, !links.isEmpty {
                Divider()
                    .background(Color.white16)
                
                VStack(alignment: .leading, spacing: 8) {
                    BodySText("Links")
                        .foregroundColor(.textSecondary)
                    
                    ForEach(links, id: \.url) { link in
                        HStack {
                            Image(systemName: "link")
                                .foregroundColor(.brandAccent)
                                .frame(width: 20)
                            
                            VStack(alignment: .leading) {
                                BodySText(link.title)
                                    .foregroundColor(.white)
                                BodyXSText(link.url)
                                    .foregroundColor(.textSecondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color.gray6)
        .cornerRadius(12)
    }
}

#Preview {
    ProfileImportView()
}

