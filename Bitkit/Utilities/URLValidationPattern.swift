import Foundation

/// Linear (non-backtracking) regex fragments for hostname / URL validation.
///
/// Labels are length-bounded to the DNS maximum, so the composed patterns cannot
/// backtrack catastrophically on long dotless input (ReDoS). Fragments are lowercase;
/// each call site applies its own case sensitivity (e.g. `.caseInsensitive`).
enum URLValidationPattern {
    /// Maximum length of a DNS name; hosts longer than this are rejected before running the regex.
    static let maxHostLength = 253

    /// A single DNS label: starts and ends alphanumeric, hyphens allowed inside, up to 63 chars.
    static let hostLabel = #"[a-z\d](?:[a-z\d-]{0,61}[a-z\d])?"#

    /// One or more dot-terminated labels, e.g. "sub.example." — combine with a trailing TLD.
    static let dotSeparatedLabels = #"(?:\#(hostLabel)\.)+"#

    /// A dotted-decimal IPv4 address.
    static let ipv4 = #"(?:\d{1,3}\.){3}\d{1,3}"#

    /// A hostname requiring a public-style alphabetic TLD of >= 2 chars, e.g. "example.com".
    static let domainWithPublicTld = #"\#(dotSeparatedLabels)[a-z]{2,}"#

    /// A hostname allowing any final label, e.g. custom TLDs like ".local".
    static let domainWithAnyTld = #"\#(dotSeparatedLabels)[a-z\d-]+"#

    /// Full RGS server URL: optional scheme, a domain-or-IPv4 host, optional port and path.
    static let rgsServerUrl = #"^(https?://)?(\#(domainWithPublicTld)|\#(ipv4))(:\d+)?(/[-a-z\d%_.~+]*)*"#

    /// Electrum host: a domain with any TLD, or an IPv4 address.
    static let electrumHost = #"^\#(domainWithAnyTld)|\#(ipv4)$"#
}
