import SwiftUI

struct AddLinkSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Marks a profile link, which pubky.app publishes: it must be a web link that meets its rules.
    var webLinksOnly = false
    let onSave: (String, String) -> Void

    @State private var label: String = ""
    @State private var url: String = ""
    @State private var showSuggestionsSheet = false

    private var linkError: PubkyAppLinkError? {
        webLinksOnly ? PubkyAppProfileStore.linkError(label: label, url: url, webOnly: true) : nil
    }

    private var labelError: String? {
        linkError == .labelTooLong ? linkError?.message : nil
    }

    private var urlError: String? {
        linkError?.isLabelError == false ? linkError?.message : nil
    }

    private var canSave: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && linkError == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: t("profile__add_link_title"))

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    CaptionMText(t("profile__add_link_label"), textColor: .white64)

                    labelFieldWithSuggestions

                    if let labelError {
                        BodySText(labelError, textColor: .redAccent)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("AddLinkLabelError")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    CaptionMText(t("profile__add_link_url"), textColor: .white64)

                    TextField(
                        t("profile__add_link_url_placeholder"),
                        text: $url,
                        backgroundColor: .white08,
                        testIdentifier: "AddLinkUrl"
                    )
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    if let urlError {
                        BodySText(urlError, textColor: .redAccent)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("AddLinkUrlError")
                    }
                }

                CaptionText(t("profile__add_link_note"), textColor: .white50)

                CustomButton(title: t("common__save")) {
                    onSave(
                        label.trimmingCharacters(in: .whitespacesAndNewlines),
                        url.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    dismiss()
                }
                .disabled(!canSave)
                .accessibilityIdentifier("AddLinkSave")
            }
            .padding(.horizontal, 16)

            Spacer()
        }
        .sheetBackground()
        .presentationDetents([.height(460)])
        .presentationCornerRadius(32)
        .presentationDragIndicator(.visible)
        .onChange(of: label) { _, value in
            let printable = String(String.UnicodeScalarView(value.unicodeScalars.map {
                $0.properties.generalCategory == .control ? " " : $0
            }))
            if printable != value {
                label = printable
            }
        }
        .sheet(isPresented: $showSuggestionsSheet) {
            LinkSuggestionsSheet(webLinksOnly: webLinksOnly) { suggestion in
                label = suggestion
            }
        }
    }

    private var labelFieldWithSuggestions: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                if label.isEmpty {
                    Text(t("profile__add_link_label_placeholder"))
                        .foregroundColor(.secondary)
                        .font(.custom(Fonts.semiBold, size: 15))
                }

                SwiftUI.TextField("", text: $label)
                    .accentColor(.brandAccent)
                    .font(.custom(Fonts.semiBold, size: 15))
                    .accessibilityIdentifier("AddLinkLabel")
            }

            Button {
                showSuggestionsSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image("lightbulb")
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)

                    Text(t("slashtags__profile_link_suggestions"))
                        .font(Fonts.semiBold(size: 13))
                        .foregroundColor(.pubkyGreen)
                }
                .padding(.horizontal, 8)
            }
            .accessibilityLabel(t("slashtags__profile_link_suggestions"))
            .accessibilityIdentifier("AddLinkSuggestions")
        }
        .padding()
        .background(Color.white08)
        .cornerRadius(8)
    }
}

extension String {
    /// Whether this is an http(s) link, with or without its scheme: the only links a social v1 profile accepts.
    /// A value with any other scheme, including a bare `host:port`, is refused, as the profile write keeps it unchanged.
    /// Paykit needs the literal `http://` or `https://`, so a scheme without `//`, or a `\` in the authority, is refused.
    var isWebLink: Bool {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return false }
        let hasScheme = value.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil
        if !hasScheme, value.prefix(while: { $0 != "/" }).contains("@") {
            return false
        }
        let url = hasScheme ? value : "https://\(value)"
        guard let colon = url.firstIndex(of: ":") else { return false }
        let afterScheme = url[url.index(after: colon)...]
        guard ["http", "https"].contains(url[..<colon].lowercased()), afterScheme.hasPrefix("//") else { return false }
        let authority = afterScheme.dropFirst(2).prefix { !"/?#".contains($0) }
        let hostAndPort = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? ""
        let rawHost = hostAndPort.hasPrefix("[") ? hostAndPort : hostAndPort.prefix { $0 != ":" }
        guard !authority.contains("\\"), !rawHost.isEmpty, var host = PubkyAppProfileStore.linkUrlHost(url)
        else { return false }
        if host.hasSuffix(".") {
            host.removeLast()
        }
        guard host.contains("."), let topLabel = host.split(separator: ".").last, !topLabel.allSatisfy(\.isNumber)
        else { return false }
        return true
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            AddLinkSheet { _, _ in }
        }
        .preferredColorScheme(.dark)
}
