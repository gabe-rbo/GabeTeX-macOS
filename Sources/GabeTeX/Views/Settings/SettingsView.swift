import SwiftUI

/// The Settings window: General, Editor and TeX.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }
            Tab("Editor", systemImage: "character.cursor.ibeam") {
                EditorSettingsView()
            }
            Tab("TeX", systemImage: "function") {
                TeXSettingsView()
            }
        }
        .scenePadding()
        .frame(width: 560)
    }
}
