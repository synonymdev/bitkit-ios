//
//  ProfileView.swift
//  Bitkit
//
//  Create and edit Pubky profile using the Pubky SDK.
//  Profiles are stored on the user's homeserver at /pub/pubky.app/profile.json
//

import SwiftUI
import BitkitCore

struct ProfileView: View {
    @EnvironmentObject var app: AppViewModel
    @Environment(\.dismiss) private var dismiss
    
    @StateObject private var viewModel = ProfileViewModel()
    
    var body: some View {
        VStack(spacing: 0) {
            NavigationBar(
                title: viewModel.hasIdentity ? "Edit Profile" : t("slashtags__profile_create"),
                action: viewModel.hasIdentity && viewModel.hasChanges && !viewModel.isSaving ? AnyView(
                    Button("Save") {
                        Task { await viewModel.saveProfile() }
                    }
                    .foregroundColor(.brandAccent)
                ) : nil,
                onBack: { dismiss() }
            )
            
            Group {
                if viewModel.isLoading {
                    loadingView
                } else if !viewModel.hasIdentity {
                    noIdentityView
                } else {
                    profileEditorView
                }
            }
        }
        .background(Color.black)
        .task {
            await viewModel.checkIdentityAndLoadProfile()
        }
    }
    
    // MARK: - Loading View
    
    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.5)
            BodyMText("Loading...")
                .foregroundColor(.textSecondary)
                .padding(.top, 16)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - No Identity View
    
    private var noIdentityView: some View {
        VStack(spacing: 0) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(Color.brandAccent.opacity(0.1))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "person.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.brandAccent)
            }
            
            Spacer().frame(height: 32)
            
            HeadlineText("Set Up Your Profile")
                .foregroundColor(.white)
            
            Spacer().frame(height: 16)
            
            BodyMText("Create a public profile so others can find and pay you. Your profile is published to your Pubky homeserver.")
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            Spacer().frame(height: 48)
            
            // Connect with Pubky Ring button
            Button {
                viewModel.connectPubkyRing()
            } label: {
                HStack {
                    if viewModel.isConnecting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: 20))
                    }
                    Text(viewModel.isConnecting ? "Connecting..." : "Connect with Pubky Ring")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.brandAccent)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(viewModel.isConnecting)
            .padding(.horizontal, 32)
            
            // Error message
            if let error = viewModel.errorMessage {
                Spacer().frame(height: 24)
                HStack {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .foregroundColor(.red)
                        .font(.footnote)
                }
                .padding()
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal, 32)
            }
            
            Spacer()
        }
    }
    
    // MARK: - Profile Editor View
    
    private var profileEditorView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Pubky ID Card
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        BodySText("Your Pubky ID")
                            .foregroundColor(.textSecondary)
                        Spacer()
                        Button {
                            Task { await viewModel.checkIdentityAndLoadProfile() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.textSecondary)
                        }
                    }
                    
                    BodySText(viewModel.truncatedPubkyId)
                        .foregroundColor(.white)
                }
                .padding()
                .background(Color.gray6)
                .cornerRadius(12)
                
                // Avatar
                HStack {
                    Spacer()
                    ZStack {
                        Circle()
                            .fill(Color.brandAccent.opacity(0.2))
                            .frame(width: 80, height: 80)
                        
                        if viewModel.name.isEmpty {
                            Image(systemName: "person.fill")
                                .font(.system(size: 40))
                                .foregroundColor(.brandAccent)
                        } else {
                            Text(String(viewModel.name.prefix(1)).uppercased())
                                .font(.title)
                                .fontWeight(.bold)
                                .foregroundColor(.brandAccent)
                        }
                    }
                    Spacer()
                }
                
                // Display Name
                VStack(alignment: .leading, spacing: 8) {
                    BodySText("Display Name")
                        .foregroundColor(.textSecondary)
                    
                    TextField("Enter your name", text: $viewModel.name)
                        .padding()
                        .background(Color.gray6)
                        .cornerRadius(8)
                        .foregroundColor(.textPrimary)
                        .onChange(of: viewModel.name) { _ in
                            viewModel.updateHasChanges()
                        }
                }
                
                // Bio
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        BodySText("Bio")
                            .foregroundColor(.textSecondary)
                        Spacer()
                        BodySText("\(viewModel.bio.count)/160")
                            .foregroundColor(viewModel.bio.count > 160 ? .red : .textSecondary)
                    }
                    
                    TextField("Tell people about yourself", text: $viewModel.bio, axis: .vertical)
                        .padding()
                        .background(Color.gray6)
                        .cornerRadius(8)
                        .foregroundColor(.textPrimary)
                        .frame(minHeight: 80, alignment: .top)
                        .onChange(of: viewModel.bio) { _ in
                            viewModel.updateHasChanges()
                        }
                }
                
                // Links
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        BodySText("Links")
                            .foregroundColor(.textSecondary)
                        Spacer()
                        Button {
                            viewModel.addLink()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                Text("Add Link")
                            }
                            .foregroundColor(.brandAccent)
                            .font(.footnote)
                        }
                    }
                    
                    ForEach($viewModel.links) { $link in
                        ProfileLinkEditorCard(
                            link: $link,
                            onDelete: { viewModel.removeLink(link) },
                            onChange: { viewModel.updateHasChanges() }
                        )
                    }
                }
                
                // Error/Success messages
                if let error = viewModel.errorMessage {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                }
                
                if let success = viewModel.successMessage {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(success)
                            .foregroundColor(.green)
                            .font(.footnote)
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(8)
                }
                
                // Publish button
                Button {
                    Task { await viewModel.saveProfile() }
                } label: {
                    HStack {
                        if viewModel.isSaving {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .frame(width: 20, height: 20)
                            Text("Publishing...")
                        } else {
                            Text("Publish Profile")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(viewModel.hasChanges && !viewModel.isSaving ? Color.brandAccent : Color.gray6)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(!viewModel.hasChanges || viewModel.isSaving)
                
                Spacer().frame(height: 24)
                
                // Disconnect button
                Button {
                    viewModel.disconnectIdentity()
                } label: {
                    HStack {
                        Image(systemName: "arrow.right.square")
                        Text("Disconnect Identity")
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.gray6)
                    .foregroundColor(.red)
                    .cornerRadius(12)
                }
                
                Spacer().frame(height: 32)
            }
            .padding()
        }
    }
}

// MARK: - Link Editor Card

struct ProfileLinkEditorCard: View {
    @Binding var link: ProfileEditableLink
    let onDelete: () -> Void
    let onChange: () -> Void
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Title", text: $link.title)
                    .padding()
                    .background(Color.gray6)
                    .cornerRadius(8)
                    .foregroundColor(.textPrimary)
                    .onChange(of: link.title) { _ in onChange() }
                
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
            }
            
            TextField("URL", text: $link.url)
                .padding()
                .background(Color.gray6)
                .cornerRadius(8)
                .foregroundColor(.textPrimary)
                .onChange(of: link.url) { _ in onChange() }
        }
        .padding()
        .background(Color.gray6.opacity(0.5))
        .cornerRadius(8)
    }
}

// MARK: - ViewModel

@MainActor
class ProfileViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var isConnecting = false
    @Published var isSaving = false
    @Published var hasIdentity = false
    @Published var pubkyId = ""
    @Published var name = ""
    @Published var bio = ""
    @Published var links: [ProfileEditableLink] = []
    @Published var hasChanges = false
    @Published var errorMessage: String?
    @Published var successMessage: String?
    
    private var originalName = ""
    private var originalBio = ""
    private var originalLinksCount = 0
    private let keychain = PaykitKeychainStorage()
    
    private enum Keys {
        static let secretKey = "pubky.identity.secret"
        static let publicKey = "pubky.identity.public"
        static let sessionSecret = "pubky.session.secret"
        static let deviceId = "pubky.paykit.deviceId"  // Device ID for noise key derivation
    }
    
    var truncatedPubkyId: String {
        guard pubkyId.count > 28 else { return pubkyId }
        return "\(pubkyId.prefix(20))...\(pubkyId.suffix(8))"
    }
    
    func checkIdentityAndLoadProfile() async {
        isLoading = true
        
        // Check for stored pubky identity
        if let pubkeyData = try? keychain.retrieve(key: Keys.publicKey),
           let pubkey = String(data: pubkeyData, encoding: .utf8) {
            hasIdentity = true
            pubkyId = pubkey
            
            // Restore session if we have the session secret stored
            if let sessionData = try? keychain.retrieve(key: Keys.sessionSecret),
               let sessionSecret = String(data: sessionData, encoding: .utf8) {
                do {
                    _ = try PubkySDKService.shared.importSession(pubkey: pubkey, sessionSecret: sessionSecret)
                    Logger.debug("Session restored for \(pubkey.prefix(12))...", context: "ProfileViewModel")
                } catch {
                    Logger.error("Failed to restore session: \(error)", context: "ProfileViewModel")
                    errorMessage = "Session expired. Please reconnect with Pubky Ring."
                }
            }
            
            // Load from local cache first (fast)
            await MainActor.run {
                name = UserDefaults.standard.string(forKey: "profileName") ?? ""
                bio = UserDefaults.standard.string(forKey: "profileBio") ?? ""
                originalName = name
                originalBio = bio
            }
            
            // Then try to fetch from homeserver (slower, but fresh)
            await loadProfile(pubkey: pubkey)
        } else {
            hasIdentity = false
        }
        
        isLoading = false
    }
    
    private func loadProfile(pubkey: String) async {
        do {
            let profile = try await PubkySDKService.shared.fetchProfile(pubkey: pubkey)
            originalName = profile.name ?? ""
            originalBio = profile.bio ?? ""
            name = originalName
            bio = originalBio
            // Note: PubkyProfile.links is [String] not structured links
            // For now, we don't load links from existing profile
            originalLinksCount = 0
            links = []
        } catch {
            Logger.debug("No existing profile found: \(error)", context: "ProfileViewModel")
        }
    }
    
    func connectPubkyRing() {
        isConnecting = true
        errorMessage = nil
        
        Task {
            // Check if Pubky Ring is installed
            guard PubkyRingBridge.shared.isPubkyRingInstalled else {
                errorMessage = "Pubky Ring app is not installed. Please install it first."
                isConnecting = false
                return
            }
            
            do {
                // Request complete Paykit setup from Pubky Ring (session + noise keys in one request)
                // This ensures we have everything we need even if Ring becomes unavailable later
                let setupResult = try await PubkyRingBridge.shared.requestPaykitSetup()
                
                // Import the session into PubkySDK using the session token
                // Note: importSession is synchronous (uses Tokio runtime internally)
                _ = try PubkySDKService.shared.importSession(
                    pubkey: setupResult.session.pubkey,
                    sessionSecret: setupResult.session.sessionSecret
                )
                Logger.info("Imported session to Pubky SDK from Pubky Ring", context: "ProfileViewModel")
                
                // Store pubkey AND session secret so we can restore the session on app restart
                try keychain.store(key: Keys.publicKey, data: setupResult.session.pubkey.data(using: .utf8)!)
                try keychain.store(key: Keys.sessionSecret, data: setupResult.session.sessionSecret.data(using: .utf8)!)
                
                // Store device ID for future noise key requests
                try keychain.store(key: Keys.deviceId, data: setupResult.deviceId.data(using: .utf8)!)
                
                // Log noise key status
                if setupResult.hasNoiseKeys {
                    Logger.info("Received noise keypairs for Paykit (epoch 0 & 1)", context: "ProfileViewModel")
                } else {
                    Logger.warning("No noise keypairs received - Paykit P2P features may be limited", context: "ProfileViewModel")
                }
                
                // Update UI state
                await MainActor.run {
                    self.hasIdentity = true
                    self.pubkyId = setupResult.session.pubkey
                    self.isConnecting = false
                    self.successMessage = "Connected to Pubky Ring!"
                }
                
                // Load the profile
                await loadProfile(pubkey: setupResult.session.pubkey)
                
                Logger.info("Successfully connected to Pubky Ring: \(setupResult.session.pubkey.prefix(16))...", context: "ProfileViewModel")
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to connect: \(error.localizedDescription)"
                    self.isConnecting = false
                }
                Logger.error("Failed to connect to Pubky Ring: \(error)", context: "ProfileViewModel")
            }
        }
    }
    
    func createNewIdentity() async {
        isConnecting = true
        errorMessage = nil
        
        do {
            // Generate new keypair using PaykitKeyManager (which uses paykit FFI)
            let keypair = try await PaykitKeyManager.shared.generateNewIdentity()
            
            // Store the pubky identity separately
            try keychain.store(key: Keys.secretKey, data: keypair.secretKeyHex.data(using: .utf8)!)
            try keychain.store(key: Keys.publicKey, data: keypair.publicKeyHex.data(using: .utf8)!)
            
            // Sign up to default homeserver using PubkySDK
            do {
                let defaultHomeserver = "8pinxxgqs41n4aididenw5apqp1urfmzdztr8jt4abrkdn435ewo"
                _ = try await PubkySDKService.shared.signUp(
                    secretKeyHex: keypair.secretKeyHex,
                    homeserverPubkey: defaultHomeserver
                )
                Logger.info("Signed up to homeserver with new identity", context: "ProfileViewModel")
            } catch {
                Logger.debug("Signup failed, trying signin: \(error)", context: "ProfileViewModel")
                do {
                    _ = try await PubkySDKService.shared.signIn(secretKeyHex: keypair.secretKeyHex)
                    Logger.info("Signed in to homeserver with existing identity", context: "ProfileViewModel")
                } catch {
                    Logger.debug("Signin also failed: \(error)", context: "ProfileViewModel")
                }
            }
            
            hasIdentity = true
            pubkyId = keypair.publicKeyHex
            isConnecting = false
            
            Logger.info("Created new Pubky identity: \(keypair.publicKeyHex.prefix(16))...", context: "ProfileViewModel")
            
        } catch {
            Logger.error("Failed to create identity: \(error)", context: "ProfileViewModel")
            errorMessage = "Failed to create identity: \(error.localizedDescription)"
            isConnecting = false
        }
    }
    
    func disconnectIdentity() {
        // Clear stored keys and session
        keychain.deleteQuietly(key: Keys.publicKey)
        keychain.deleteQuietly(key: Keys.secretKey)
        keychain.deleteQuietly(key: Keys.sessionSecret)
        keychain.deleteQuietly(key: Keys.deviceId)
        
        // Clear cached session and noise keys from PubkyRingBridge
        if !pubkyId.isEmpty {
            PubkyRingBridge.shared.clearSession(pubkey: pubkyId)
        }
        PubkyRingBridge.shared.clearCache()  // Clear noise keypair cache as well
        
        // Reset all state
        hasIdentity = false
        pubkyId = ""
        name = ""
        bio = ""
        links = []
        originalName = ""
        originalBio = ""
        originalLinksCount = 0
        hasChanges = false
        errorMessage = nil
        successMessage = "Identity disconnected"
        
        Logger.info("Disconnected identity and cleared profile state", context: "ProfileViewModel")
    }
    
    func updateHasChanges() {
        let validLinks = links.filter { !$0.title.isEmpty && !$0.url.isEmpty }
        
        hasChanges = name != originalName ||
                     bio != originalBio ||
                     validLinks.count != originalLinksCount ||
                     !name.isEmpty || !bio.isEmpty || !validLinks.isEmpty
        
        errorMessage = nil
        successMessage = nil
    }
    
    func addLink() {
        links.append(ProfileEditableLink(title: "", url: ""))
        updateHasChanges()
    }
    
    func removeLink(_ link: ProfileEditableLink) {
        links.removeAll { $0.id == link.id }
        updateHasChanges()
    }
    
    func saveProfile() async {
        isSaving = true
        errorMessage = nil
        successMessage = nil
        
        // Check if we have an identity (pubkey)
        guard !pubkyId.isEmpty else {
            errorMessage = "No identity found. Please connect with Pubky Ring first."
            isSaving = false
            return
        }
        
        // Ensure we have an active session - restore if needed
        let hasSession = await PubkySDKService.shared.hasSession(pubkey: pubkyId)
        if !hasSession {
            if let sessionData = try? keychain.retrieve(key: Keys.sessionSecret),
               let sessionSecret = String(data: sessionData, encoding: .utf8) {
                do {
                    _ = try PubkySDKService.shared.importSession(pubkey: pubkyId, sessionSecret: sessionSecret)
                    Logger.debug("Session restored before save", context: "ProfileViewModel")
                } catch {
                    Logger.error("Failed to restore session: \(error)", context: "ProfileViewModel")
                    errorMessage = "Session expired. Please reconnect with Pubky Ring."
                    isSaving = false
                    return
                }
            } else {
                errorMessage = "No session found. Please connect with Pubky Ring."
                isSaving = false
                return
            }
        }
        
        // Build profile JSON
        var profileDict: [String: Any] = [:]
        let trimmedName = name.trimmingCharacters(in: CharacterSet.whitespaces)
        let trimmedBio = bio.trimmingCharacters(in: CharacterSet.whitespaces)
        
        if !trimmedName.isEmpty {
            profileDict["name"] = trimmedName
        }
        if !trimmedBio.isEmpty {
            profileDict["bio"] = trimmedBio
        }
        
        let validLinks = links.filter {
            !$0.title.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty &&
            !$0.url.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty
        }
        if !validLinks.isEmpty {
            profileDict["links"] = validLinks.map {
                ["title": $0.title.trimmingCharacters(in: CharacterSet.whitespaces),
                 "url": $0.url.trimmingCharacters(in: CharacterSet.whitespaces)]
            }
        }
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: profileDict)
            
            // Put profile to homeserver using the active session from Pubky SDK
            // sessionPut is now synchronous - run it in a background task
            try await Task {
                try PubkySDKService.shared.sessionPut(
                    pubkey: pubkyId,
                    path: "/pub/pubky.app/profile.json",
                    content: jsonData
                )
            }.value
            
            originalName = trimmedName
            originalBio = trimmedBio
            originalLinksCount = validLinks.count
            hasChanges = false
            successMessage = "Profile published successfully!"
            Logger.info("Profile published to homeserver", context: "ProfileViewModel")
            
            // Save locally for display on home screen
            await MainActor.run {
                UserDefaults.standard.set(trimmedName, forKey: "profileName")
                UserDefaults.standard.set(trimmedBio, forKey: "profileBio")
                UserDefaults.standard.set(pubkyId, forKey: "profilePubkyId")
            }
            
        } catch {
            Logger.error("Failed to publish profile: \(error)", context: "ProfileViewModel")
            errorMessage = "Failed to publish: \(error.localizedDescription)"
        }
        
        isSaving = false
    }
}

// MARK: - Models

struct ProfileEditableLink: Identifiable {
    let id = UUID()
    var title: String
    var url: String
}

// MARK: - Preview

#Preview {
    ProfileView()
        .environmentObject(AppViewModel())
        .preferredColorScheme(.dark)
}
