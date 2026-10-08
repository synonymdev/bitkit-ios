import Foundation

private struct FormatArgument: Codable, Equatable {
    let name: String
    let isPlural: Bool
}

private indirect enum MessagePart {
    case text(String)
    case argument(String)
    case plural(String, [String: [MessagePart]])
}

private enum ConversionError: Error {
    case invalidPattern(String)
    case conflictingArgument(String)
    case invalidStringsFile(String)
}

private struct MessageParser {
    let characters: [Character]
    var index = 0

    mutating func parse(inBranch: Bool = false) throws -> [MessagePart] {
        var parts: [MessagePart] = []
        var text = ""
        while index < characters.count {
            let character = characters[index]
            if character == "}" {
                guard inBranch else { throw invalidPattern() }
                index += 1
                if !text.isEmpty {
                    parts.append(.text(text))
                }
                return parts
            }
            guard character == "{" else {
                text.append(character)
                index += 1
                continue
            }
            if !text.isEmpty {
                parts.append(.text(text))
                text = ""
            }
            index += 1
            let name = readToken()
            guard !name.isEmpty, index < characters.count else { throw invalidPattern() }
            if characters[index] == "}" {
                index += 1
                parts.append(.argument(name))
                continue
            }
            guard characters[index] == "," else { throw invalidPattern() }
            index += 1
            guard readToken() == "plural", index < characters.count, characters[index] == "," else { throw invalidPattern() }
            index += 1
            var branches: [String: [MessagePart]] = [:]
            while true {
                skipWhitespace()
                guard index < characters.count else { throw invalidPattern() }
                if characters[index] == "}" {
                    index += 1
                    break
                }
                let category = readToken()
                guard ["zero", "one", "two", "few", "many", "other"].contains(category),
                      branches[category] == nil, index < characters.count, characters[index] == "{"
                else { throw invalidPattern() }
                index += 1
                branches[category] = try parse(inBranch: true)
            }
            guard branches["other"] != nil else { throw invalidPattern() }
            parts.append(.plural(name, branches))
        }
        guard !inBranch else { throw invalidPattern() }
        if !text.isEmpty {
            parts.append(.text(text))
        }
        return parts
    }

    private mutating func readToken() -> String {
        skipWhitespace()
        let start = index
        while index < characters.count, !characters[index].isWhitespace, !["{", "}", ","].contains(characters[index]) {
            index += 1
        }
        let token = String(characters[start ..< index])
        skipWhitespace()
        return token
    }

    private mutating func skipWhitespace() {
        while index < characters.count, characters[index].isWhitespace {
            index += 1
        }
    }

    private func invalidPattern() -> ConversionError {
        .invalidPattern(String(characters))
    }
}

private struct NativeMessage {
    var arguments: [FormatArgument] = []
    var rules: [String: Any] = [:]

    mutating func compile(_ parts: [MessagePart], countPosition: Int? = nil) throws -> String {
        var format = ""
        for part in parts {
            switch part {
            case let .text(text):
                var escaped = text.replacingOccurrences(of: "%", with: "%%")
                if let countPosition {
                    escaped = escaped.replacingOccurrences(of: "#", with: "%\(countPosition)$lld")
                }
                format += escaped
            case let .argument(name):
                let position = try argumentPosition(name: name, isPlural: false)
                format += "%\(position)$@"
            case let .plural(name, branches):
                let position = try argumentPosition(name: name, isPlural: true)
                guard rules[name] == nil else { throw ConversionError.conflictingArgument(name) }
                var rule: [String: Any] = [
                    "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                    "NSStringFormatValueTypeKey": "lld",
                ]
                for (category, branch) in branches.sorted(by: { $0.key < $1.key }) {
                    rule[category] = try compile(branch, countPosition: position)
                }
                rules[name] = rule
                format += "%\(position)$#@\(name)@"
            }
        }
        return format
    }

    private mutating func argumentPosition(name: String, isPlural: Bool) throws -> Int {
        if let index = arguments.firstIndex(where: { $0.name == name }) {
            guard arguments[index].isPlural == isPlural else { throw ConversionError.conflictingArgument(name) }
            return index + 1
        }
        arguments.append(FormatArgument(name: name, isPlural: isPlural))
        return arguments.count
    }
}

private func generate(source: URL, destination: URL) throws {
    let directories = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "lproj" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    var total = 0
    for directory in directories {
        let sourceFile = directory.appendingPathComponent("Localizable.strings")
        let data = try Data(contentsOf: sourceFile)
        guard let translations = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String] else {
            throw ConversionError.invalidStringsFile(sourceFile.path)
        }
        var messages: [String: Any] = [:]
        var metadata: [String: [FormatArgument]] = [:]
        for (key, pattern) in translations.sorted(by: { $0.key < $1.key }) {
            guard pattern.range(of: #"\{\s*\w+(?:\s*,\s*|\s+)plural\b"#, options: .regularExpression) != nil else { continue }
            do {
                var parser = MessageParser(characters: Array(pattern))
                let parts = try parser.parse()
                var message = NativeMessage()
                let format = try message.compile(parts)
                var entry = message.rules
                entry["NSStringLocalizedFormatKey"] = format
                messages[key] = entry
                metadata[key] = message.arguments
            } catch {
                FileHandle.standardError.write(Data("error: Invalid plural translation '\(key)' in '\(sourceFile.path)'\n".utf8))
                throw error
            }
        }
        let output = destination.appendingPathComponent(directory.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let nativeData = try PropertyListSerialization.data(fromPropertyList: messages, format: .xml, options: 0)
        try nativeData.write(to: output.appendingPathComponent("LocalizablePlurals.stringsdict"), options: .atomic)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(metadata).write(to: output.appendingPathComponent("PluralArguments.plist"), options: .atomic)
        total += messages.count
    }
    print("Generated \(total) native plural translations for \(directories.count) languages")
}

do {
    guard CommandLine.arguments.count == 3 else {
        FileHandle.standardError.write(Data("Usage: swift generate-plural-localizations.swift <source-localizations> <bundle-resources>\n".utf8))
        exit(1)
    }
    try generate(
        source: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true),
        destination: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    )
} catch {
    FileHandle.standardError.write(Data("error: Failed to generate native plural localizations: \(error)\n".utf8))
    exit(1)
}
