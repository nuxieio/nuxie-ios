<p align="center">
  <a href="https://nuxie.io" target="_blank" rel="noopener">
    <img alt="Nuxie" src="https://nuxie.io/favicon-192.png" width="64" height="64" />
  </a>
</p>

<div align="center">
  <strong>Nuxie iOS SDK</strong>
  <br />
  Bring targeted in‑app flows, paywalls, and analytics to your iOS app.
  <br /><br />
  <a href="https://nuxie.io" target="_blank" rel="noopener">Website</a>
</div>

---

## What is Nuxie?

Nuxie is a platform for running targeted in‑app flows such as paywalls, upgrade prompts, surveys, and more — without shipping new app releases. This SDK connects your iOS app to Nuxie so you can track events, identify users, and automatically present flows configured in the Nuxie dashboard.

Learn more at https://nuxie.io

## Features

- Event tracking: send custom events with properties and user traits.
- User identity: anonymous IDs, `identify`, and event linking on login.
- Campaigns & flows: server‑driven campaigns that can present in‑app UI.
- Session tracking: automatic sessioning with manual controls when needed.
- Purchases: delegate‑based StoreKit integration for buy/restore.
- Plugins: lightweight lifecycle/plugins system you can extend.
- Privacy & controls: do‑not‑track, property sanitization, beforeSend hook.
- Offline-first: events are queued and sent when online.

## Requirements

- iOS 15+
- Swift 5.9+ (Xcode 15+)

## Installation (Swift Package Manager)

Add the package to your app:

1) Xcode → File → Add Package Dependencies…
- Package URL: `https://github.com/nuxieio/nuxie-ios`
- Add the `Nuxie` product to your app target

Or via `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/nuxieio/nuxie-ios", from: "0.1.0")
]
```

## Quick Start

Initialize early (e.g., in your app entry point) with your API key from the Nuxie dashboard.

SwiftUI App:

```swift
import SwiftUI
import Nuxie

@main
struct MyApp: App {
  init() {
    var config = NuxieConfiguration(apiKey: "NX_…")
    config.environment = .production // .staging, .development, or .custom
    config.logLevel = .info
    // Optional: configure purchases
    // config.purchaseDelegate = MyPurchaseDelegate()

    do { try NuxieSDK.shared.setup(with: config) }
    catch { print("Nuxie setup failed: \(error)") }
  }

  var body: some Scene { WindowGroup { ContentView() } }
}
```

UIKit (AppDelegate):

```swift
import UIKit
import Nuxie

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
    let config = NuxieConfiguration(apiKey: "NX_…")
    config.environment = .production
    config.logLevel = .warning

    do { try NuxieSDK.shared.setup(with: config) }
    catch { print("Nuxie setup failed: \(error)") }
    return true
  }
}
```

Identify a user (login):

```swift
NuxieSDK.shared.identify(
  "user_123",
  userProperties: ["plan": "free"],
  userPropertiesSetOnce: ["signup_at": Date()]
)
```

Track events (optionally observe immediate outcomes):

```swift
NuxieSDK.shared.track(
  "premium_feature_tapped",
  properties: ["feature": "pro_filters"]
) { result in
  switch result {
  case .noInteraction:
    break // Event recorded, no immediate flow was shown
  case .flow(let completion):
    // Inspect outcome (purchase, dismissed, etc.)
    print("Flow \(completion.flowId) outcome: \(completion.outcome)")
  case .failed(let error):
    print("Track failed: \(error)")
  }
}
```

Logout / clear identity:

```swift
NuxieSDK.shared.reset() // keepAnonymousId = true by default
```

## API Overview

- `NuxieSDK.shared.setup(with:)`: initialize the SDK (call once).
- `NuxieSDK.shared.identify(_:userProperties:userPropertiesSetOnce:)`: identify a user and set traits.
- `NuxieSDK.shared.track(_:properties:userProperties:userPropertiesSetOnce:completion:)`: track events; optional completion reports immediate flow outcomes.
- `NuxieSDK.shared.reset(keepAnonymousId:)`: clear identity (e.g., logout).
- `NuxieSDK.shared.version`: current SDK version string.
- `NuxieSDK.shared.getDistinctId()`: current distinct ID (identified or anonymous).
- Session: `startNewSession()`, `endSession()`, `resetSession()`, `getCurrentSessionId()`, `setSessionId(_:)`.
- Plugins: `installPlugin(_:)`, `uninstallPlugin(_:)`, `startPlugin(_:)`, `stopPlugin(_:)`, `isPluginInstalled(_:)`.
- `NuxieSDK.shared.shutdown()`: tear down services (usually not needed).

### Flows

- `NuxieSDK.shared.getFlowViewController(with:)`: asynchronously returns a view controller for a specific flow ID using the flow cache (or fetches on-demand). Useful for debugging a flow directly.
- `NuxieSDK.shared.showFlow(with:)`: presents a flow by ID in a dedicated overlay window.

Example (UIKit):

```swift
@MainActor
func debugFlow() async {
  do {
    let vc = try await NuxieSDK.shared.getFlowViewController(id: "your_flow_id")
    present(vc, animated: true)
  } catch {
    print("Failed to load flow: \(error)")
  }
}
```

## Configuration Highlights

Create with `NuxieConfiguration(apiKey:)` and optionally set:

- `environment`: `.production` (default), `.staging`, `.development`, `.custom` (+ `apiEndpoint`).
- Logging: `logLevel`, `enableConsoleLogging`, `enableFileLogging`, `redactSensitiveData`.
- Batching: `eventBatchSize`, `flushAt`, `flushInterval`, `maxQueueSize`, retries/timeouts.
- Hooks: `beforeSend` to transform or drop events; `propertiesSanitizer`.
- Flows: cache size/expiration and download concurrency/timeouts.
- Purchases: `purchaseDelegate` to handle StoreKit buy/restore in your app.
- Plugins: `enablePlugins` and `plugins` to register custom plugins.

Minimal example:

```swift
var config = NuxieConfiguration(apiKey: "NX_…")
config.environment = .staging
config.beforeSend = { event in
  // Example: drop noisy dev events
  event.name.hasPrefix("dev_") ? nil : event
}
```

### Purchases (optional)

Provide a purchase delegate if your flows include purchases:

```swift
import StoreKit

final class MyPurchaseDelegate: NuxiePurchaseDelegate {
  func purchase(_ product: any StoreProductProtocol) async -> PurchaseResult {
    // Integrate with StoreKit here
    return .success
  }

  func restore() async -> RestoreResult {
    // Restore previous purchases
    return .noPurchases
  }
}
```

## Need Help?

- Learn more and get access at https://nuxie.io

## License

Licensed under the terms in `LICENSE`.
