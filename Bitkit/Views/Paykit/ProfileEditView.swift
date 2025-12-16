//
//  ProfileEditView.swift
//  Bitkit
//
//  Edit and publish profile to Pubky directory
//

import SwiftUI

struct ProfileEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    
    // Profile fields
    @State private var name: String = ""
    @State private var bio: String = ""
    @State private var links: [EditableLink] = []
    
    // Original profile for comparison
    @State private var originalProfile: PubkyProfile?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationBar(
                title: "Edit Profile",
                leftButton: NavigationBarButton(
                    type: .close,
                    action: { dismiss() }
                ),
                rightButton: hasChanges ? NavigationBarButton(
                    type: .textButton(text: "Save"),
                    action: { Task { await saveProfile() } }
                ) : nil
            )
            
            if isLoading {
                VStack {
                    Spacer()
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                    BodyMText("Loading profile...")
                        .foregroundColor(.textSecondary)
                        .padding(.top, 16)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 24) {
                        // Profile Avatar
                        profileAvatarSection
                        
                        // Name field
                        VStack(alignment: .leading, spacing: 8) {
                            BodySText("Display Name")
                                .foregroundColor(.textSecondary)
                            
                            TextField("Enter your name", text: $name)
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(Color.gray6)
                                .cornerRadius(8)
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 16)
                        
                        // Bio field
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                BodySText("Bio")
                                    .foregroundColor(.textSecondary)
                                Spacer()
                                BodyXSText("\(bio.count)/160")
                                    .foregroundColor(bio.count > 160 ? .red : .textSecondary)
                            }
                            
                            TextEditor(text: $bio)
                                .frame(minHeight: 80)
                                .padding(8)
                                .background(Color.gray6)
                                .cornerRadius(8)
                                .foregroundColor(.white)
                                .scrollContentBackground(.hidden)
                        }
                        .padding(.horizontal, 16)
                        
                        // Links section
                        linksSection
                        
                        // Error/Success messages
                        if let error = errorMessage {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                BodySText(error)
                                    .foregroundColor(.red)
                            }
                            .padding(.horizontal, 16)
                        }
                        
                        if let success = successMessage {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                BodySText(success)
                                    .foregroundColor(.green)
                            }
                            .padding(.horizontal, 16)
                        }
                        
                        // Preview section
                        if hasChanges {
                            previewSection
                        }
                        
                        // Save button
                        Button {
                            Task { await saveProfile() }
                        } label: {
                            HStack {
                                if isSaving {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .frame(width: 20, height: 20)
                                } else {
                                    Image(systemName: "arrow.up.circle.fill")
                                }
                                Text("Publish to Pubky")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(hasChanges ? Color.brandAccent : Color.gray6)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                        .disabled(!hasChanges || isSaving)
                        .padding(.horizontal, 16)
                        
                        Spacer(minLength: 32)
                    }
                    .padding(.top, 16)
                }
            }
        }
        .background(Color.gray8)
        .onAppear {
            Task {
                await loadCurrentProfile()
            }
        }
    }
    
    // MARK: - Subviews
    
    private var profileAvatarSection: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Circle()
                    .fill(Color.brandAccent.opacity(0.2))
                    .frame(width: 80, height: 80)
                    .overlay {
                        if !name.isEmpty {
                            Text(String(name.prefix(1)).uppercased())
                                .font(.title)
                                .foregroundColor(.brandAccent)
                        } else {
                            Image(systemName: "person.fill")
                                .font(.title)
                                .foregroundColor(.brandAccent)
                        }
                    }
                
                BodyXSText("Tap to change avatar")
                    .foregroundColor(.textSecondary)
            }
            Spacer()
        }
    }
    
    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                BodySText("Links")
                    .foregroundColor(.textSecondary)
                Spacer()
                Button {
                    links.append(EditableLink(title: "", url: ""))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Link")
                    }
                    .font(.caption)
                    .foregroundColor(.brandAccent)
                }
            }
            
            ForEach(links.indices, id: \.self) { index in
                VStack(spacing: 8) {
                    HStack {
                        TextField("Title", text: $links[index].title)
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(Color.gray6)
                            .cornerRadius(6)
                            .foregroundColor(.white)
                        
                        Button {
                            links.remove(at: index)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                    }
                    
                    TextField("URL", text: $links[index].url)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(Color.gray6)
                        .cornerRadius(6)
                        .foregroundColor(.white)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(12)
                .background(Color.gray7)
                .cornerRadius(8)
            }
        }
        .padding(.horizontal, 16)
    }
    
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            BodySText("Preview")
                .foregroundColor(.textSecondary)
                .padding(.horizontal, 16)
            
            ProfilePreviewCard(profile: currentProfile)
                .padding(.horizontal, 16)
        }
    }
    
    // MARK: - Computed Properties
    
    private var currentProfile: PubkyProfile {
        PubkyProfile(
            name: name.isEmpty ? nil : name,
            bio: bio.isEmpty ? nil : bio,
            avatar: nil,
            links: links.isEmpty ? nil : links.filter { !$0.title.isEmpty && !$0.url.isEmpty }.map {
                PubkyProfileLink(title: $0.title, url: $0.url)
            }
        )
    }
    
    private var hasChanges: Bool {
        guard let original = originalProfile else {
            return !name.isEmpty || !bio.isEmpty || !links.isEmpty
        }
        
        let currentLinks = links.filter { !$0.title.isEmpty && !$0.url.isEmpty }
        let originalLinks = original.links ?? []
        
        return name != (original.name ?? "") ||
               bio != (original.bio ?? "") ||
               currentLinks.count != originalLinks.count
    }
    
    // MARK: - Actions
    
    private func loadCurrentProfile() async {
        isLoading = true
        errorMessage = nil
        
        guard let pubkey = PaykitKeyManager.shared.getCurrentPublicKeyZ32() else {
            await MainActor.run {
                self.isLoading = false
            }
            return
        }
        
        do {
            if let profile = try await DirectoryService.shared.fetchProfile(for: pubkey) {
                await MainActor.run {
                    self.originalProfile = profile
                    self.name = profile.name ?? ""
                    self.bio = profile.bio ?? ""
                    self.links = profile.links?.map {
                        EditableLink(title: $0.title, url: $0.url)
                    } ?? []
                    self.isLoading = false
                }
            } else {
                await MainActor.run {
                    self.isLoading = false
                }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Failed to load profile: \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }
    
    private func saveProfile() async {
        isSaving = true
        errorMessage = nil
        successMessage = nil
        
        do {
            try await DirectoryService.shared.publishProfile(currentProfile)
            await MainActor.run {
                self.originalProfile = self.currentProfile
                self.successMessage = "Profile published successfully!"
                self.isSaving = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Failed to publish: \(error.localizedDescription)"
                self.isSaving = false
            }
        }
    }
}

// MARK: - Supporting Types

struct EditableLink: Identifiable {
    let id = UUID()
    var title: String
    var url: String
}

// MARK: - Preview

#Preview {
    ProfileEditView()
}

