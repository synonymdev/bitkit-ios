import Foundation

private enum TestFailure: Error {
    case assertion(String)
}

private func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw TestFailure.assertion(message) }
}

private func generate(_ translations: [String: String], language: String, root: URL) throws -> (Int32, URL) {
    let source = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let directory = source.appendingPathComponent("\(language).lproj", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: translations, format: .xml, options: 0)
    try data.write(to: directory.appendingPathComponent("Localizable.strings"))
    let output = root.appendingPathComponent("\(UUID().uuidString).bundle", isDirectory: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--sdk", "macosx", "swift", "scripts/generate-plural-localizations.swift", source.path, output.path]
    try process.run()
    process.waitUntilExit()
    return (process.terminationStatus, output.appendingPathComponent("\(language).lproj"))
}

do {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitkit-plural-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let (status, directory) = try generate([
        "message": "💸 {owner}: {count, plural, other {# inputs, ₿ {funds}, 100%} one {1 input, ₿ {funds}, 100%}} Done.",
        "empty": "{count, plural, one {} other {#}}",
        "plain": "No plural here",
    ], language: "en", root: root)
    try check(status == 0, "Valid templates must compile")
    let bundle = Bundle(path: directory.path)!
    let format = bundle.localizedString(forKey: "message", value: nil, table: "LocalizablePlurals")
    try check(
        String(format: format, locale: Locale(identifier: "en"), arguments: ["Alice", Int64(2), "100"]) == "💸 Alice: 2 inputs, ₿ 100, 100% Done.",
        "Unicode, placeholders inside/outside plural branches, literal percent signs and reordered branches must survive conversion"
    )
    try check(
        String(format: format, locale: Locale(identifier: "en"), arguments: ["Alice", Int64(1), "100"]) == "💸 Alice: 1 input, ₿ 100, 100% Done.",
        "Singular branches must retain named argument positions"
    )
    let emptyFormat = bundle.localizedString(forKey: "empty", value: nil, table: "LocalizablePlurals")
    try check(String(format: emptyFormat, locale: Locale(identifier: "en"), arguments: [Int64(1)]) == "", "Empty branches must be supported")
    try check(
        bundle.localizedString(forKey: "plain", value: nil, table: "LocalizablePlurals") == "plain",
        "Ordinary translations must stay in their original table"
    )

    let (arabicStatus, arabicDirectory) = try generate([
        "categories": "{count, plural, zero {ZERO} one {ONE} two {TWO} few {FEW} many {MANY} other {OTHER}}",
    ], language: "ar", root: root)
    try check(arabicStatus == 0, "All six Arabic categories must compile")
    let arabic = Bundle(path: arabicDirectory.path)!
    let arabicFormat = arabic.localizedString(forKey: "categories", value: nil, table: "LocalizablePlurals")
    for (count, expected): (Int64, String) in [(0, "ZERO"), (1, "ONE"), (2, "TWO"), (3, "FEW"), (11, "MANY"), (101, "OTHER")] {
        try check(
            String(format: arabicFormat, locale: Locale(identifier: "ar"), arguments: [count]) == expected,
            "Arabic category for '\(count)' must be '\(expected)'"
        )
    }

    for invalid in [
        "{count, plural, one {One}}",
        "{count, plural, one {One} other {Many}",
        "{count, plural, one {One} one {Duplicate} other {Many}}",
        "{count, plural, offset:1 one {One} other {Many}}",
    ] {
        let (invalidStatus, _) = try generate(["invalid": invalid], language: "en", root: root)
        try check(invalidStatus != 0, "Malformed or unsupported templates must stop the build rather than ship raw syntax")
    }
    print("Passed native plural conversion checks")
} catch {
    FileHandle.standardError.write(Data("Plural conversion test failed: \(error)\n".utf8))
    exit(1)
}
