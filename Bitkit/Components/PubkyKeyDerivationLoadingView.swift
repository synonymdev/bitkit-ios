import SwiftUI

struct PubkyKeyDerivationLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ActivityIndicator(size: 32)
            BodyMText(t("profile__deriving_keys"), textColor: .white64)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
