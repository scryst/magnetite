import SwiftUI

/// Drop-in replacement for `@State`.
///
/// In the macOS 26 SDK `@State` is a macro whose plugin (`SwiftUIMacros`) ships with
/// Xcode, not the Command Line Tools, so any view using `@State` fails to build on a
/// CLT-only machine. The `State` type is unaffected and SwiftUI finds nested
/// `DynamicProperty` members by reflection, so wrapping it gives the same storage
/// and invalidation without a macro. The other property wrappers are plain and need
/// no equivalent.
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    private var storage: State<Value>

    init(wrappedValue: Value) {
        storage = State(initialValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}
