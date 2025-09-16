When performing a code review, respond in English.

## Architecture & Patterns

When performing a code review, ensure no ViewModels are used in SwiftUI code. If ViewModels are found, suggest refactoring to use native SwiftUI data flow patterns with @Observable objects: `@Observable class BusinessLogic { }` and inject via `.environment(businessLogic)`, retrieve with `@Environment(BusinessLogic.self)`.

When performing a code review, verify that business logic is extracted into @Observable objects when shared across multiple views. If business logic is found directly in views, suggest creating an @Observable class: 
```swift
@Observable class UserManager {
    var users: [User] = []
    func loadUsers() async { /* logic */ }
}
```

When performing a code review, ensure proper dependency injection using `.environment()` and `@Environment`. If manual dependency passing is found, suggest: `.environment(dependency)` in parent view and `@Environment(Dependency.self) var dependency` in child view.

When performing a code review, check that views are decomposed into small, focused components. If large views with mixed concerns are found, suggest breaking them into smaller, single-purpose components with descriptive names.

## State Management

When performing a code review, verify proper use of @State for local view state. If inappropriate state management is found, suggest: `@State private var isLoading = false` for local state that belongs to the view.

When performing a code review, ensure @Binding is used correctly for two-way data flow between parent and child views. If direct state manipulation is found across view boundaries, suggest: `@Binding var selectedItem: Item` in child view.

When performing a code review, check that @Observable is used for shared business logic objects. If singleton patterns or global state are found, suggest refactoring to @Observable objects with proper injection.

When performing a code review, verify that state mutations happen on the main actor. If background thread UI updates are found, suggest: `await MainActor.run { /* UI updates */ }` or `@MainActor` annotations.

## Modern iOS APIs & Features

When performing a code review, ensure iOS 18/26 features have proper availability checks. If modern APIs are used without guards, suggest:
```swift
if #available(iOS 18.0, *) {
    // Use iOS 18+ features
} else {
    // Fallback implementation
}
```

When performing a code review, check for proper implementation of iOS 26 Liquid Glass effects. If outdated visual effects are used, suggest migrating to new Liquid Glass APIs with availability checks.

When performing a code review, verify that enhanced scrolling and text capabilities from iOS 18/26 are used appropriately. If legacy implementations are found, suggest modernizing with new APIs.

## Async & Lifecycle

When performing a code review, ensure .task modifier is used instead of .onAppear for async operations. If .onAppear with async code is found, suggest:
```swift
.task {
    await loadData()
}
```

When performing a code review, verify understanding of .task vs .onAppear lifecycle differences. If incorrect usage is found, explain that .task automatically cancels when view disappears and suggest appropriate usage.

When performing a code review, check that async operations in views use environment objects. If complex async logic is in view extensions, suggest moving to @Observable business logic objects:
```swift
extension MyView {
    func loadData() async {
        await environment.businessLogic.loadData()
    }
}
```

## Component Design & Reusability

When performing a code review, ensure components are truly independent and reusable. If tightly coupled components are found, suggest refactoring to accept generic data types and use proper @Binding or environment injection.

When performing a code review, verify that each component has a single responsibility. If multi-purpose components are found, suggest breaking them down: `UserCard`, `UserList`, `UserDetail` instead of one large `UserView`.

When performing a code review, check that composition is preferred over complex view hierarchies. If deeply nested views are found, suggest flattening with reusable components.

## Code Quality & Style

When performing a code review, ensure descriptive names are used for components and state properties. If unclear names are found, suggest: `isLoadingUsers` instead of `loading`, `UserProfileCard` instead of `Card`.

When performing a code review, verify that SwiftUI conventions are followed. If non-standard patterns are found, suggest Apple's recommended approaches from official documentation.

When performing a code review, check that small business logic in view extensions is appropriate. If complex business logic is found in views, suggest extracting to @Observable objects.

When performing a code review, ensure proper separation of concerns between UI and business logic. If mixed responsibilities are found, suggest clear boundaries with injected dependencies.

## Performance & Best Practices

When performing a code review, verify that expensive operations are not performed directly in view body. If heavy computations are found, suggest moving to @Observable objects or using proper caching mechanisms.

When performing a code review, check for proper use of @ViewBuilder and custom view builders. If repetitive view code is found, suggest creating reusable view builders.

When performing a code review, ensure that unnecessary view updates are avoided. If frequent recomputations are found, suggest proper state granularity and @Observable property organization.

## Error Handling & Edge Cases

When performing a code review, verify proper error handling in async operations. If unhandled errors are found, suggest proper do-catch blocks and user feedback mechanisms.

When performing a code review, check that loading states and empty states are properly handled. If missing states are found, suggest comprehensive state management:
```swift
enum LoadingState<T> {
    case idle, loading, loaded(T), error(Error)
}
```

When performing a code review, ensure accessibility is considered in custom components. If accessibility features are missing, suggest proper accessibility modifiers and labels.

## Documentation & Testing

When performing a code review, verify that complex business logic in @Observable objects is properly documented. If undocumented logic is found, suggest adding clear comments explaining the purpose and behavior.

When performing a code review, check that components are designed for testability. If hard-to-test code is found, suggest refactoring with proper dependency injection and observable patterns.

When performing a code review, ensure that modern SwiftUI patterns are used correctly according to Apple's latest best practices. If outdated patterns are found, suggest consulting Apple's official documentation and updating to current recommendations.


## Lightning & Bitcoin Specific

When performing a code review, verify that Bitcoin/Lightning operations are properly handled in the service layer.

When performing a code review, verify that propper Bitcoin and Lightning technical terms are used when naming code components
