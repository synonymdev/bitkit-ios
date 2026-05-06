import BitkitCore

extension Activity {
    func contact(in contacts: [PubkyContact]) -> PubkyContact? {
        guard let contactPublicKey else { return nil }
        return contacts.first(where: { PubkyPublicKeyFormat.matches($0.publicKey, contactPublicKey) })
    }

    private var contactPublicKey: String? {
        switch self {
        case let .lightning(lightning):
            return lightning.contact

        case let .onchain(onchain):
            return onchain.contact
        }
    }
}
