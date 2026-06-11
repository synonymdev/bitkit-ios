import Foundation

struct Toast: Equatable {
    enum ToastType {
        case success, info, lightning, warning, error
    }

    /// Brief visibility for transient feedback (e.g. blocked number pad input).
    static let visibilityTimeShort = 1.5

    let id: UUID
    let type: ToastType
    let title: String
    let description: String?
    let autoHide: Bool
    let visibilityTime: Double
    let accessibilityIdentifier: String?

    init(
        id: UUID = UUID(),
        type: ToastType,
        title: String,
        description: String? = nil,
        autoHide: Bool = true,
        visibilityTime: Double = 4.0,
        accessibilityIdentifier: String? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.description = description
        self.autoHide = autoHide
        self.visibilityTime = visibilityTime
        self.accessibilityIdentifier = accessibilityIdentifier
    }
}
