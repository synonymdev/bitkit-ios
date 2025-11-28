import Foundation

struct Toast: Equatable {
    enum ToastType {
        case success, info, lightning, warning, error
    }

    let id: UUID
    let type: ToastType
    let title: String
    let description: String?
    let autoHide: Bool
    let visibilityTime: Double

    init(id: UUID = UUID(), type: ToastType, title: String, description: String? = nil, autoHide: Bool = true, visibilityTime: Double = 4.0) {
        self.id = id
        self.type = type
        self.title = title
        self.description = description
        self.autoHide = autoHide
        self.visibilityTime = visibilityTime
    }
}
