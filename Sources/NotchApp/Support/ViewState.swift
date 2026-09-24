import SwiftUI

/// Drop-in replacement for `@State`.
///
/// In the macOS 26 SDK `@State` is implemented as a macro, and its expansion
/// plugin (`SwiftUIMacros`) ships with Xcode rather than the Command Line Tools.
/// On a CLT-only machine any view using `@State` fails to build.
///
/// `State` the *type* is unaffected, and SwiftUI discovers nested
/// `DynamicProperty` members by reflection — so wrapping it gives identical
/// storage and invalidation behaviour with no macro involved. `@Namespace`,
/// `@Environment`, `@Binding`, `@AppStorage`, `@FocusState` and `@GestureState`
/// are all plain property wrappers and need no equivalent.
///
/// If this ever gets built with a full Xcode install, `@ViewState` → `@State` is
/// a safe find-and-replace.
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
