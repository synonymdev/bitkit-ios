import SwiftUI

/// A view modifier that detects when a user interacts with a UIButton or UIControl
/// This is useful for determining if a tap occurred on a native iOS button or control
private struct ButtonDetectionModifier: ViewModifier {
    /// Callback that is triggered when a button is detected
    /// - Parameter isButton: Boolean indicating whether the tap occurred on a button/control
    let onButtonDetected: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { _ in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            // Using DragGesture with minimumDistance: 0 to detect taps
                            DragGesture(minimumDistance: 0)
                                .onChanged { gesture in
                                    // Get the tap location
                                    let location = gesture.startLocation

                                    // Perform hit testing to determine what was tapped
                                    let hitTest = UIApplication.shared.connectedScenes
                                        .first(where: { $0 is UIWindowScene })
                                        .flatMap { $0 as? UIWindowScene }?.windows
                                        .first?
                                        .hitTest(location, with: nil)

                                    // Check if the tapped view is a UIButton or UIControl
                                    let isButton = hitTest is UIButton || hitTest is UIControl
                                    onButtonDetected(isButton)
                                }
                        )
                }
            )
    }
}

extension View {
    /// Adds button detection capability to any SwiftUI view
    /// - Parameter onDetected: Closure that is called when a button is detected
    /// - Returns: A modified view with button detection
    func detectButton(onDetected: @escaping (Bool) -> Void) -> some View {
        modifier(ButtonDetectionModifier(onButtonDetected: onDetected))
    }
}
