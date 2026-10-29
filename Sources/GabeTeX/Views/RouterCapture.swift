import SwiftUI

/// Hands SwiftUI’s window actions to `AppRouter` so Finder/Dock opens and menus can open windows.
struct RouterCapture: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onAppear {
            AppRouter.shared.dismissWindow = dismissWindow
            AppRouter.shared.openWindow = openWindow
        }
    }
}

extension View {
    func capturesWindowActions() -> some View { modifier(RouterCapture()) }
}
