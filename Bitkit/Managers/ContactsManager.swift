import Foundation
import SwiftUI

private let pubkyPrefix = "pubky"

private func ensurePubkyPrefix(_ key: String) -> String {
    key.hasPrefix(pubkyPrefix) ? key : "\(pubkyPrefix)\(key)"
}

struct PubkyContact: Identifiable, Hashable, Sendable {
    let id: String
    let publicKey: String
    let profile: PubkyProfile

    static func == (lhs: PubkyContact, rhs: PubkyContact) -> Bool {
        lhs.publicKey == rhs.publicKey
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(publicKey)
    }

    var displayName: String {
        profile.name
    }

    var sortLetter: String {
        let firstChar = displayName.first.map { String($0).uppercased() } ?? "#"
        return firstChar.first?.isLetter == true ? firstChar : "#"
    }

    init(publicKey: String, profile: PubkyProfile) {
        id = publicKey
        self.publicKey = publicKey
        self.profile = profile
    }
}

struct ContactSection: Identifiable {
    let id: String
    let letter: String
    let contacts: [PubkyContact]
}

@MainActor
class ContactsManager: ObservableObject {
    @Published var contacts: [PubkyContact] = []
    @Published var isLoading = false
    @Published var hasLoaded = false

    var groupedContacts: [ContactSection] {
        let grouped = Dictionary(grouping: contacts) { $0.sortLetter }
        return grouped.keys.sorted().map { letter in
            ContactSection(id: letter, letter: letter, contacts: grouped[letter] ?? [])
        }
    }

    func reset() {
        contacts = []
        isLoading = false
        hasLoaded = false
    }

    func loadContacts(for publicKey: String) async throws {
        guard !isLoading else { return }

        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }

        do {
            let contactKeys = try await Task.detached {
                try await PubkyService.getContacts(publicKey: publicKey)
            }.value

            Logger.debug("Fetched \(contactKeys.count) contact keys", context: "ContactsManager")

            let loaded: [PubkyContact] = await withTaskGroup(of: PubkyContact.self) { group in
                for key in contactKeys {
                    let prefixedKey = ensurePubkyPrefix(key)
                    group.addTask {
                        let profile: PubkyProfile
                        do {
                            let dto = try await PubkyService.getProfile(publicKey: prefixedKey)
                            profile = PubkyProfile(publicKey: prefixedKey, ffiProfile: dto)
                        } catch {
                            Logger.warn("Failed to load contact profile '\(prefixedKey)': \(error)", context: "ContactsManager")
                            profile = PubkyProfile.placeholder(publicKey: prefixedKey)
                        }
                        return PubkyContact(publicKey: prefixedKey, profile: profile)
                    }
                }
                var results: [PubkyContact] = []
                for await contact in group {
                    results.append(contact)
                }
                return results
            }

            contacts = loaded.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        } catch {
            Logger.error("Failed to load contacts: \(error)", context: "ContactsManager")
            throw error
        }
    }

    func fetchContactProfile(publicKey: String) async -> PubkyProfile? {
        let prefixedKey = ensurePubkyPrefix(publicKey)
        do {
            let dto = try await Task.detached {
                try await PubkyService.getProfile(publicKey: prefixedKey)
            }.value
            return PubkyProfile(publicKey: prefixedKey, ffiProfile: dto)
        } catch {
            Logger.error("Failed to fetch contact profile: \(error)", context: "ContactsManager")
            return nil
        }
    }
}
