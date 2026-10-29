import SwiftUI

/// Drop-in replacement for `@State`.
///
/// In the macOS 27 SDK `@State` is a macro whose compiler plug-in (`SwiftUIMacros`) ships only with the
/// full Xcode, so a Command Line Tools build cannot use it. `State<Value>` itself is still an ordinary
/// `DynamicProperty` struct; wrapping it keeps the familiar `@LocalState var x = …` / `$x` syntax and
/// identical semantics (view-local storage that survives re-renders).
@propertyWrapper
struct LocalState<Value>: DynamicProperty {
    private let storage: State<Value>

    init(wrappedValue: Value) {
        storage = State<Value>(initialValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}
