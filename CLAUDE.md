# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Bitkit iOS is a native Swift implementation of a Bitcoin and Lightning Network wallet. This is a work-in-progress repository that is **NOT** the live production app. The production app uses React Native and is at github.com/synonymdev/bitkit.

This app integrates with:
- **LDK Node** (Lightning Development Kit) for Lightning Network functionality
- **BitkitCore** (Rust-based core library) for Bitcoin operations
- **Electrum/Esplora** for blockchain data
- **Blocktank** for Lightning channel services

## Build & Development Commands

### Building
```bash
# Standard build - Open Bitkit.xcodeproj in Xcode and build

# E2E test build (uses local Electrum backend)
xcodebuild -workspace Bitkit.xcodeproj/project.xcworkspace \
  -scheme Bitkit \
  -configuration Debug \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) E2E_BUILD' \
  build
```

### Code Formatting
```bash
# Install SwiftFormat
brew install swiftformat

# Format all Swift code
swiftformat .

# Setup git hooks for automatic formatting on commits
npm install -g git-format-staged
./scripts/setup-hooks.sh
```

### Localization
```bash
# Validate translations (checks for missing translations and validates translation keys)
node scripts/validate-translations.js
```

**Note:** Localization files are synced from Transifex using [bitkit-transifex-sync](https://github.com/synonymdev/bitkit-transifex-sync).

### Testing
```bash
# Run tests via Xcode Test Navigator or:
# Cmd+U in Xcode
```

## Architecture

### SwiftUI Patterns (CRITICAL)

This project follows **modern SwiftUI patterns** and explicitly **AVOIDS traditional MVVM with ViewModels**. The architecture uses:

1. **@Observable Objects for Business Logic**
   - Use `@Observable class` for shared business logic instead of ViewModels
   - Inject via `.environment(businessLogic)`
   - Retrieve with `@Environment(BusinessLogic.self)`
   - Example: `@Observable class UserManager { var users: [User] = []; func loadUsers() async { } }`

2. **Native SwiftUI Data Flow**
   - `@State` for local view state only
   - `@Binding` for two-way data flow between parent/child views
   - `@Observable` for shared business logic objects
   - All state mutations must happen on `@MainActor`

3. **Lifecycle Management**
   - Use `.task` modifier for async operations (NOT `.onAppear`)
   - `.task` automatically cancels when view disappears
   - Async operations should delegate to `@Observable` business logic objects

4. **Component Design**
   - Decompose views into small, focused, single-purpose components
   - Use descriptive names (e.g., `UserProfileCard` not `Card`)
   - Prefer composition over deep view hierarchies
   - Components should be independent and reusable with generic data types

### Core Architecture Layers

```
┌─────────────────────────────────────────────────┐
│              Views (SwiftUI)                    │
│  - MainNavView, Activity, Wallet, Settings     │
│  - Small, focused components                    │
└─────────────────┬───────────────────────────────┘
                  │
┌─────────────────▼───────────────────────────────┐
│        @Observable Business Logic               │
│  - AppViewModel, WalletViewModel, etc.          │
│  - Injected via .environment()                  │
└─────────────────┬───────────────────────────────┘
                  │
┌─────────────────▼───────────────────────────────┐
│              Services                           │
│  - CoreService (BitkitCore bridge)              │
│  - LightningService (LDK Node)                  │
│  - TransferService, CurrencyService             │
└─────────────────┬───────────────────────────────┘
                  │
┌─────────────────▼───────────────────────────────┐
│         External Dependencies                   │
│  - BitkitCore (Rust): Bitcoin operations        │
│  - LDKNode: Lightning Network operations        │
│  - Electrum/Esplora: Blockchain data            │
└─────────────────────────────────────────────────┘
```

### Key Components

**App Entry Point:**
- `BitkitApp.swift`: Main app entry, handles AppDelegate setup, push notifications, quick actions
- `AppScene.swift`: Root scene coordinator, manages app-wide ViewModels and lifecycle
- `ContentView.swift`: Root content view

**Services Layer:**
- `CoreService`: Bridge to BitkitCore (Rust), handles Bitcoin operations and activity storage
- `LightningService`: Manages LDK Node lifecycle, Lightning operations, channel management
- `TransferService`: Orchestrates Bitcoin/Lightning transfers (send/receive)
- `TransferStorage`: Persists pending transfer state
- `CurrencyService`: Currency conversion and exchange rates
- `ElectrumConfigService`, `RgsConfigService`: Backend configuration
- `ServiceQueue`: Queue system for background operations (`.core`, `.ldk` queues)

**Managers:**
- `SessionManager`: User session state
- `PushNotificationManager`: Push notification handling for incoming payments
- `ScannerManager`: QR code scanning for payments
- `ToastWindowManager`: App-wide toast notifications
- `TransferTrackingManager`: Tracks pending transfers (new feature)
- `TimedSheets/`: Timed sheet management (backup reminders, high balance warnings)
- `SuggestionsManager`, `TagManager`, `LanguageManager`, `NetworkMonitor`

**ViewModels (Legacy):**
While the project is transitioning away from traditional ViewModels, these still exist but should follow `@Observable` patterns:
- `AppViewModel`: App-wide state (toasts, errors)
- `WalletViewModel`: Wallet state, balance, node lifecycle
- `ActivityListViewModel`: Transaction/payment history
- `TransferViewModel`: Transfer flows (send/receive)
- `NavigationViewModel`, `SheetViewModel`: UI navigation state
- `BlocktankViewModel`: Lightning channel ordering via Blocktank

**Key Directories:**
- `Components/`: Reusable UI components (buttons, sliders, widgets)
- `Views/`: Feature-specific views (Onboarding, Backup, Security, Wallets, Settings, Transfer)
- `Extensions/`: Swift extensions for utilities and mock data
- `Utilities/`: Helper utilities (Logger, Keychain, Crypto, Haptics, StateLocker)
- `Models/`: Data models (Toast, ElectrumServer, NodeLifecycleState, etc.)
- `Styles/`: Fonts and sheet styles

### Service Queue Pattern

Operations that interact with `CoreService` or `LightningService` must use `ServiceQueue`:

```swift
// For BitkitCore operations
try await ServiceQueue.background(.core) {
    // Core operations here
}

// For LDK Node operations
try await ServiceQueue.background(.ldk) {
    // Lightning operations here
}
```

### State Management Patterns

**Node Lifecycle:**
The Lightning node has distinct lifecycle states tracked via `NodeLifecycleState`:
- `.notStarted` → `.initializing` → `.running` → `.stopped`
- Error states: `.errorStarting(String)`

**Transfer Tracking:**
New feature (`TransferTrackingManager`) tracks pending transfers to handle edge cases where transfers are initiated but not completed.

## Important Development Notes

### Security & Bitcoin/Lightning

- Use proper Bitcoin/Lightning terminology in code and naming
- All Bitcoin/Lightning operations belong in the service layer, never in views
- The app uses `StateLocker` to prevent concurrent Lightning operations (`.lightning` lock)
- Keychain is used for sensitive data (mnemonics, passphrases)

### Network Configuration

- The app currently runs on **regtest only** (see `LightningService.swift:92` guard)
- VSS (Versioned Storage Service) authentication is not yet implemented
- Electrum/Esplora server URLs are configurable via `Env`
- E2E builds use local Electrum backend via `E2E_BUILD` compilation flag

### Error Handling

- Use `do-catch` blocks for async operations
- Provide user feedback via toasts: `app.toast(type: .error, title: "...", description: "...")`
- Handle loading, error, and empty states comprehensively
- Consider using `enum LoadingState<T> { case idle, loading, loaded(T), error(Error) }`

### iOS Version Compatibility

- Xcode previews only work with iOS 17 and below (due to Rust dependencies)
- Use availability checks for iOS 18/26 features:
  ```swift
  if #available(iOS 18.0, *) {
      // Use iOS 18+ features
  } else {
      // Fallback
  }
  ```

### Performance

- Avoid expensive operations in view body
- Move heavy computations to `@Observable` objects
- Use proper state granularity to minimize view updates
- Use `@ViewBuilder` for repetitive view code

### Accessibility

Ensure accessibility modifiers and labels are added to custom components.

## Code Style & Conventions

- **SwiftFormat** configuration in `.swiftformat`
- Max line width: 150 characters
- Swift version: 5.10
- Use descriptive names: `isLoadingUsers` not `loading`
- Follow Apple's SwiftUI best practices

## Common Workflows

### Adding a New Feature

1. Identify if business logic should live in an `@Observable` object or existing ViewModel
2. Create UI components in `Components/` or feature-specific views in `Views/`
3. Wire up via `.environment()` injection in `AppScene.swift`
4. Use `.task` for async initialization
5. Add error handling and user feedback (toasts)

### Working with Lightning

1. All Lightning operations go through `LightningService.shared`
2. Lock the Lightning state with `StateLocker.lock(.lightning)` for critical operations
3. Listen to LDK events via `wallet.addOnEvent(id:)` pattern
4. Sync activity list after Lightning events

### Working with Bitcoin

1. Use `CoreService` for Bitcoin operations
2. Activity tracking handles both on-chain and Lightning payments
3. RBF (Replace-By-Fee) is tracked via `ActivityService.replacementTransactions`

### Localization Changes

1. Update translation keys in code
2. Run `node scripts/validate-translations.js` to check for issues
3. Sync with Transifex using `bitkit-transifex-sync` tool