import SwiftUI

struct SendContactHeaderAvatar: View {
    @EnvironmentObject private var app: AppViewModel
    @EnvironmentObject private var contactsManager: ContactsManager

    var body: some View {
        if let contact {
            PubkyContactAvatar(contact: contact, size: 32)
        } else {
            Spacer()
                .frame(width: 24, height: 24)
        }
    }

    private var contact: PubkyContact? {
        guard let publicKey = app.contactPaymentContext?.publicKey else {
            return nil
        }

        return contactsManager.contacts.first(where: { PubkyPublicKeyFormat.matches($0.publicKey, publicKey) })
    }
}
