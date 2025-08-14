## Architecture overview

This document describes the main app layers and the key types in each layer with their responsibilities. It also outlines how state flows through the app and how the reset lifecycle works.

### Layer definitions

- **View**: SwiftUI views; declarative UI only. Reads observable state and sends user intents.
- **ViewModel**: UI-facing state for a screen or flow. Translates domain/service results into presentation state; orchestrates user intents. Runs on `@MainActor` and exposes `@Published` / `@AppStorage`.
- **Manager / Coordinator**: Cross-view UI orchestration or global utilities that don’t represent a single screen (e.g., session lifecycle, toasts, timed sheets). Often singletons or shared `ObservableObject`s.
- **Service**: Domain/IO layer. Talks to SDKs, databases, background queues, networking. No UI knowledge. Usually not `ObservableObject`.
- **Utility / Helper**: Stateless helpers (formatting, storage paths, etc.).

---

## Composition and data flow

- `BitkitApp` → `ContentView` → `AppScene`
  - `AppScene` constructs all core `@StateObject` view models and injects them via `.environmentObject(...)`.
  - `MainNavView` hosts the `NavigationStack` with `navigationDestination(for:)` for typed routes and binds to `SheetViewModel` items for sheets.

- Unidirectional flow
  - View → ViewModel: user intent via actions/bindings.
  - ViewModel → Service: async/await work dispatched to `ServiceQueue`.
  - Service → ViewModel: results/events (e.g., LDK events) update `@Published` on main.
  - ViewModel → View: state changes trigger re-render; global UI (sheets/toasts/navigation) is updated centrally.

---

## When to add what

- Add a new **ViewModel** when you need UI-facing state for a screen/flow and you’re orchestrating user intents.
- Add a **Manager/Coordinator** when you need cross-view UI orchestration (session, toasts, timed sheets) or a global utility.
- Add a **Service** when integrating external SDKs, IO, or long-running/background operations. Keep it UI-agnostic.
- Prefer `ServiceQueue.background(_:)` for heavy work and `@MainActor` for anything that touches UI.
