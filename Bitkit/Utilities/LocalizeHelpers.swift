import Foundation

func localizedRandom(_ key: String, comment: String) -> String {
    let localizedString = NSLocalizedString(key, comment: comment)
    let components = localizedString.components(separatedBy: "\n")
    guard components.count > 1 else { return localizedString }
    return components.randomElement() ?? localizedString
}

func localizedString(_ key: String, comment: String = "", variables: [String: String] = [:]) -> String {
    var localizedString = NSLocalizedString(key, comment: comment)

    for (name, value) in variables {
        localizedString = localizedString.replacingOccurrences(of: "{\(name)}", with: value)
    }

    return localizedString
}

func localizedRandomWithVariables(_ key: String, comment: String, variables: [String: String] = [:]) -> String {
    let localizedString = NSLocalizedString(key, comment: comment)
    let components = localizedString.components(separatedBy: "\n")

    var result = components.count > 1 ? (components.randomElement() ?? localizedString) : localizedString

    for (name, value) in variables {
        result = result.replacingOccurrences(of: "{\(name)}", with: value)
    }

    return result
}
