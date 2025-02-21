import Foundation

func LocalizedRandom(_ key: String, comment: String) -> String {
    let localizedString = NSLocalizedString(key, comment: comment)
    let components = localizedString.components(separatedBy: "\n")
    guard components.count > 1 else { return localizedString }
    return components.randomElement() ?? localizedString
}
