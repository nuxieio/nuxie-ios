# Nuxie Demo Apps

Six standalone SwiftUI apps, each showcasing specific Nuxie SDK features through realistic, well-designed experiences.

## Philosophy

- **Real apps, not demos**: Each app feels like something you'd actually ship
- **Beautiful by default**: Clean, modern SwiftUI design that feels good to use
- **One focus per app**: Each app highlights specific SDK capabilities
- **SwiftUI first**: Starting with SwiftUI, UIKit versions can come later

---

## The Six Apps

| App | Concept | Primary SDK Features |
|-----|---------|---------------------|
| **Starter** | First-launch onboarding | Flows, `$app_installed` trigger |
| **Lockbox** | Notes app with Pro features | Feature gating, paywalls, `TriggerUpdate` |
| **Coinverse** | Virtual item shop | Credit system, `useFeature()`, reactive balance |
| **Quota** | AI quote generator | Metered usage, `useFeatureAndWait()`, limits |
| **Persona** | Personality quiz | View model binding, data flow to/from flows |
| **Bridge** | Native action playground | `call_delegate`, NotificationCenter |

---

## 1. Starter

**Concept**: A minimal app that demonstrates first-launch onboarding. The entire app is essentially "complete the onboarding to see the main screen."

**What it showcases**:
- Automatic flow trigger on `$app_installed`
- Flow presentation and completion handling
- Conditional UI based on onboarding state

### Screens

**Launch → Onboarding Flow → Home**

**Home Screen** (after onboarding):
- Clean welcome message with user's name (from onboarding)
- "What you told us" card showing collected preferences
- "Reset & Try Again" button (clears state, re-triggers onboarding)

### Design Direction

Minimal, calm aesthetic. Soft gradients, generous whitespace. The focus is entirely on the onboarding flow itself.

```
┌─────────────────────────────┐
│                             │
│     Welcome back, Sarah     │
│                             │
│  ┌───────────────────────┐  │
│  │  Your Preferences     │  │
│  │                       │  │
│  │  Theme: Dark          │  │
│  │  Notifications: On    │  │
│  │  Goal: Productivity   │  │
│  └───────────────────────┘  │
│                             │
│                             │
│    [ Reset & Try Again ]    │
│                             │
└─────────────────────────────┘
```

### SDK Integration

```swift
@main
struct StarterApp: App {
    @State private var hasCompletedOnboarding = false
    @State private var onboardingData: OnboardingData?

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                HomeView(data: onboardingData)
            } else {
                OnboardingTriggerView(
                    onComplete: { data in
                        onboardingData = data
                        hasCompletedOnboarding = true
                    }
                )
            }
        }
    }
}

struct OnboardingTriggerView: View {
    let onComplete: (OnboardingData) -> Void

    var body: some View {
        Color.clear
            .task {
                // Trigger onboarding flow
                let handle = NuxieSDK.shared.trigger("$app_installed")

                for await update in handle {
                    if case .journey(let journey) = update,
                       journey.exitReason == .completed {
                        // Extract data from journey context
                        let data = OnboardingData(from: journey.context)
                        onComplete(data)
                    }
                }
            }
    }
}
```

---

## 2. Lockbox

**Concept**: A simple notes app where some features (folders, tags, export) are locked behind Pro.

**What it showcases**:
- Boolean feature gating with `hasFeature()`
- Trigger-based paywall presentation
- Handling `TriggerUpdate` stream for entitlement changes
- Real-time UI updates after purchase

### Screens

**Notes List → Note Detail → (Pro Feature tap) → Paywall**

**Notes List**:
- List of notes with titles and previews
- Floating "+" button to add note
- Bottom tab bar: Notes, Folders (🔒), Tags (🔒), Settings

**Locked Feature Tap**:
- Tapping Folders or Tags triggers paywall
- After purchase, tabs unlock immediately

**Settings**:
- Current plan display (Free / Pro)
- Restore purchases button
- Feature comparison (what Pro includes)

### Design Direction

Clean iOS-native feel. Uses system colors, subtle shadows on cards. The lock icons are tasteful, not obnoxious.

```
┌─────────────────────────────┐
│  Lockbox            [ + ]   │
├─────────────────────────────┤
│  ┌───────────────────────┐  │
│  │ Meeting Notes         │  │
│  │ Discussed Q4 goals... │  │
│  └───────────────────────┘  │
│  ┌───────────────────────┐  │
│  │ Shopping List         │  │
│  │ Milk, eggs, bread...  │  │
│  └───────────────────────┘  │
│  ┌───────────────────────┐  │
│  │ Ideas                 │  │
│  │ App concept for...    │  │
│  └───────────────────────┘  │
├─────────────────────────────┤
│  📝 Notes   📁🔒   🏷️🔒   ⚙️  │
└─────────────────────────────┘
```

### SDK Integration

```swift
struct ContentView: View {
    @ObservedObject var features = NuxieSDK.shared.features

    var hasPro: Bool {
        features.isAllowed("pro")
    }

    var body: some View {
        TabView {
            NotesListView()
                .tabItem { Label("Notes", systemImage: "note.text") }

            Group {
                if hasPro {
                    FoldersView()
                } else {
                    LockedFeatureView(feature: "folders")
                }
            }
            .tabItem {
                Label("Folders", systemImage: hasPro ? "folder" : "folder.badge.lock")
            }

            // ... similar for Tags
        }
    }
}

struct LockedFeatureView: View {
    let feature: String
    @State private var isProcessing = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Unlock \(feature.capitalized)")
                .font(.title2.bold())

            Text("Upgrade to Pro to organize your notes with \(feature).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Upgrade to Pro") {
                unlockFeature()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isProcessing)
        }
        .padding()
    }

    func unlockFeature() {
        isProcessing = true

        Task {
            let handle = NuxieSDK.shared.trigger("\(feature)_tapped")

            for await update in handle {
                switch update {
                case .entitlement(.allowed):
                    // Purchase successful - UI updates automatically via @ObservedObject
                    isProcessing = false
                    return
                case .entitlement(.denied):
                    isProcessing = false
                    return
                default:
                    break
                }
            }
        }
    }
}
```

---

## 3. Coinverse

**Concept**: A virtual shop where you spend coins on digital items (stickers, themes, avatars). See your balance, buy things, run out, top up.

**What it showcases**:
- Credit system balance display
- `useFeature()` for spending credits
- Reactive balance updates via `@ObservedObject`
- Triggering flows when balance is insufficient

### Screens

**Shop Grid → Item Detail → Purchase Confirmation**

**Shop Grid**:
- Coin balance prominently at top
- Grid of purchasable items with coin prices
- Items you own show checkmark
- "Get More Coins" button

**Item Detail**:
- Large preview of item
- Price and "Buy" button
- If owned: "Owned" badge instead

**Insufficient Coins**:
- Attempting to buy without enough coins triggers top-up flow

### Design Direction

Playful, colorful. Think mobile game shop but tasteful. Coins have a satisfying visual treatment.

```
┌─────────────────────────────┐
│  Coinverse                  │
│  ┌─────────────────────┐    │
│  │  🪙 47 coins        │    │
│  │  [ Get More ]       │    │
│  └─────────────────────┘    │
├─────────────────────────────┤
│  ┌─────┐ ┌─────┐ ┌─────┐   │
│  │ ⭐  │ │ 🔥  │ │ 🌙  │   │
│  │ 5🪙 │ │ 10🪙│ │ 15🪙│   │
│  └─────┘ └─────┘ └─────┘   │
│  ┌─────┐ ┌─────┐ ┌─────┐   │
│  │ 🤖  │ │ 🎨  │ │ ✨  │   │
│  │ 20🪙│ │ 25🪙│ │ 50🪙│   │
│  └─────┘ └─────┘ └─────┘   │
│                             │
│  ───── Owned ─────          │
│  ┌─────┐ ┌─────┐            │
│  │ ✓🎯 │ │ ✓💎 │            │
│  └─────┘ └─────┘            │
└─────────────────────────────┘
```

### SDK Integration

```swift
struct ShopView: View {
    @ObservedObject var features = NuxieSDK.shared.features
    @State private var ownedItems: Set<String> = []
    @State private var purchaseInProgress: String?

    var coinBalance: Int {
        features.balance("coins") ?? 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Balance header
                    CoinBalanceCard(balance: coinBalance) {
                        NuxieSDK.shared.trigger("get_more_coins_tapped")
                    }

                    // Item grid
                    LazyVGrid(columns: [.init(), .init(), .init()], spacing: 16) {
                        ForEach(ShopItem.all) { item in
                            ShopItemCard(
                                item: item,
                                isOwned: ownedItems.contains(item.id),
                                canAfford: coinBalance >= item.cost,
                                isPurchasing: purchaseInProgress == item.id
                            ) {
                                purchaseItem(item)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Shop")
        }
    }

    func purchaseItem(_ item: ShopItem) {
        guard coinBalance >= item.cost else {
            // Not enough coins - trigger top-up flow
            NuxieSDK.shared.trigger("insufficient_coins", properties: [
                "item_id": item.id,
                "item_cost": item.cost,
                "current_balance": coinBalance
            ])
            return
        }

        purchaseInProgress = item.id

        // Deduct coins (fire-and-forget for instant UI feedback)
        NuxieSDK.shared.useFeature("coins", amount: Double(item.cost))

        // Track purchase
        NuxieSDK.shared.trigger("item_purchased", properties: [
            "item_id": item.id,
            "cost": item.cost
        ])

        // Mark as owned
        ownedItems.insert(item.id)
        purchaseInProgress = nil
    }
}
```

---

## 4. Quota

**Concept**: An AI-powered inspirational quote generator. Free users get 5 quotes per day. Shows remaining quota, handles limit gracefully.

**What it showcases**:
- Metered feature with balance
- `useFeatureAndWait()` for confirmed usage
- Limit enforcement with upgrade prompt
- Usage resets (daily/monthly concept)

### Screens

**Home → Generate → Result**

**Home**:
- Large "Generate Quote" button
- Quota display: "4 of 5 remaining today"
- Previous quotes in a feed below
- When at limit: upgrade prompt replaces button

**Generating**:
- Nice loading animation
- Simulated 2-second "AI thinking" delay

**Result**:
- Beautiful quote card
- Share button
- Save to favorites

### Design Direction

Elegant, inspirational. Soft typography, muted colors. The quotes themselves are the star.

```
┌─────────────────────────────┐
│          Quota              │
│                             │
│   ┌─────────────────────┐   │
│   │                     │   │
│   │   [ Generate ]      │   │
│   │                     │   │
│   │   4 of 5 remaining  │   │
│   └─────────────────────┘   │
│                             │
│   ─── Today's Quotes ───    │
│                             │
│   "The only way to do       │
│    great work is to love    │
│    what you do."            │
│                    — Jobs   │
│                             │
│   "In the middle of         │
│    difficulty lies          │
│    opportunity."            │
│                  — Einstein │
│                             │
└─────────────────────────────┘
```

### SDK Integration

```swift
struct QuotaHomeView: View {
    @ObservedObject var features = NuxieSDK.shared.features
    @State private var quotes: [Quote] = []
    @State private var isGenerating = false
    @State private var showUpgrade = false

    var quotesRemaining: Int {
        features.balance("daily_quotes") ?? 0
    }

    var isUnlimited: Bool {
        features.feature("daily_quotes")?.unlimited ?? false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    // Generator card
                    GeneratorCard(
                        remaining: quotesRemaining,
                        isUnlimited: isUnlimited,
                        isGenerating: isGenerating
                    ) {
                        generateQuote()
                    }

                    // Quote feed
                    if !quotes.isEmpty {
                        QuoteFeed(quotes: quotes)
                    }
                }
                .padding()
            }
            .navigationTitle("Quota")
        }
    }

    func generateQuote() {
        Task {
            isGenerating = true

            // Use feature with server confirmation
            let result = try? await NuxieSDK.shared.useFeatureAndWait("daily_quotes")

            if result?.success == true {
                // Simulate AI generation
                try? await Task.sleep(nanoseconds: 2_000_000_000)

                let quote = QuoteGenerator.random()
                quotes.insert(quote, at: 0)

                NuxieSDK.shared.trigger("quote_generated", properties: [
                    "quote_id": quote.id
                ])
            } else {
                // At limit - trigger upgrade flow
                NuxieSDK.shared.trigger("quota_limit_reached")
            }

            isGenerating = false
        }
    }
}

struct GeneratorCard: View {
    let remaining: Int
    let isUnlimited: Bool
    let isGenerating: Bool
    let onGenerate: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Button(action: onGenerate) {
                HStack {
                    if isGenerating {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(isGenerating ? "Generating..." : "Generate Quote")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(remaining > 0 || isUnlimited ? Color.accentColor : Color.secondary)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(isGenerating || (remaining <= 0 && !isUnlimited))

            if isUnlimited {
                Text("Unlimited quotes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(remaining) of 5 remaining today")
                    .font(.subheadline)
                    .foregroundStyle(remaining > 0 ? .secondary : .red)
            }
        }
        .padding(24)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
```

---

## 5. Persona

**Concept**: A personality quiz app. Answer questions in a flow, see your results. Demonstrates passing data TO flows and receiving data FROM flows.

**What it showcases**:
- Sending context data to flows via `sendRuntimeMessage`
- Receiving results from flows via journey completion
- View model binding for dynamic flow content
- Personalized experience based on flow responses

### Screens

**Home → Start Quiz (Flow) → Results**

**Home**:
- "Discover Your Persona" hero
- Previous results if any
- "Take the Quiz" button
- Option to enter name for personalized experience

**Quiz Flow**:
- Multiple choice questions
- Progress indicator
- Personalized greeting using passed name

**Results**:
- Persona type card (e.g., "The Visionary")
- Traits breakdown
- Share result

### Design Direction

Modern, engaging. Bold colors for persona types. The quiz itself is presented via Nuxie flow.

```
┌─────────────────────────────┐
│         Persona             │
│                             │
│   ┌─────────────────────┐   │
│   │                     │   │
│   │   Discover Your     │   │
│   │      Persona        │   │
│   │                     │   │
│   │   Answer a few      │   │
│   │   questions to      │   │
│   │   find out who      │   │
│   │   you really are    │   │
│   │                     │   │
│   └─────────────────────┘   │
│                             │
│   Your name (optional):     │
│   ┌─────────────────────┐   │
│   │ Sarah               │   │
│   └─────────────────────┘   │
│                             │
│   [ Take the Quiz ]         │
│                             │
└─────────────────────────────┘
```

### SDK Integration

```swift
struct PersonaHomeView: View {
    @State private var userName: String = ""
    @State private var result: PersonaResult?
    @State private var showingQuiz = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    // Hero
                    PersonaHeroCard()

                    // Name input
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your name (optional)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("Enter your name", text: $userName)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Start button
                    Button("Take the Quiz") {
                        startQuiz()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    // Previous result
                    if let result {
                        PersonaResultCard(result: result)
                    }
                }
                .padding()
            }
            .navigationTitle("Persona")
        }
    }

    func startQuiz() {
        Task {
            // Get the flow view controller
            guard let flowVC = try? await NuxieSDK.shared.getFlowViewController(with: "persona_quiz") else {
                return
            }

            // Send user context to the flow
            flowVC.sendRuntimeMessage(
                type: "set_context",
                payload: [
                    "userName": userName.isEmpty ? "Friend" : userName,
                    "timestamp": ISO8601DateFormatter().string(from: Date())
                ]
            )

            // Handle completion
            flowVC.onClose = { reason in
                if case .completed(let data) = reason {
                    // Extract persona result from flow
                    if let personaType = data?["persona_type"] as? String,
                       let traits = data?["traits"] as? [String] {
                        result = PersonaResult(
                            type: personaType,
                            traits: traits,
                            userName: userName
                        )
                    }
                }
            }

            // Present the flow
            // (In real app, use UIKit bridge or sheet presentation)
        }
    }
}
```

---

## 6. Bridge

**Concept**: A native action playground. A flow with buttons that trigger native iOS capabilities: haptics, alerts, share sheets, URL opening, etc.

**What it showcases**:
- `call_delegate` action from flows
- `NotificationCenter` observation
- Handling different message types
- Native capability integration

### Screens

**Home → Interactive Flow → Log of Actions**

**Home**:
- "Launch Interactive Demo" button
- Live log showing all delegate calls received
- Clear log button

**Interactive Flow**:
- Grid of action buttons in the flow
- Each triggers a different native action

**Log**:
- Timestamped list of received delegate messages
- Payload details expandable

### Design Direction

Developer-focused, but still polished. Console-like log output with good typography.

```
┌─────────────────────────────┐
│          Bridge             │
│                             │
│   [ Launch Demo Flow ]      │
│                             │
│   ─── Action Log ─────────  │
│                             │
│   12:34:05 haptic_feedback  │
│   { style: "heavy" }        │
│                             │
│   12:34:07 show_alert       │
│   { title: "Hello!" }       │
│                             │
│   12:34:12 open_url         │
│   { url: "https://..." }    │
│                             │
│   12:34:15 share            │
│   { text: "Check this!" }   │
│                             │
│                             │
│   [ Clear Log ]             │
└─────────────────────────────┘
```

### SDK Integration

```swift
struct BridgeView: View {
    @State private var logEntries: [LogEntry] = []
    @State private var showingFlow = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Button("Launch Demo Flow") {
                    launchDemoFlow()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                // Log output
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Action Log")
                            .font(.headline)
                        Spacer()
                        Button("Clear") {
                            logEntries.removeAll()
                        }
                        .font(.subheadline)
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(logEntries) { entry in
                                LogEntryView(entry: entry)
                            }
                        }
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding()
            .navigationTitle("Bridge")
            .onAppear { setupDelegateObserver() }
        }
    }

    func setupDelegateObserver() {
        NotificationCenter.default.addObserver(
            forName: .nuxieCallDelegate,
            object: nil,
            queue: .main
        ) { notification in
            handleCallDelegate(notification)
        }
    }

    func handleCallDelegate(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let message = userInfo["message"] as? String else { return }

        let payload = userInfo["payload"] as? [String: Any]

        // Log the action
        let entry = LogEntry(
            timestamp: Date(),
            message: message,
            payload: payload
        )
        logEntries.insert(entry, at: 0)

        // Execute the native action
        switch message {
        case "haptic_feedback":
            let style = payload?["style"] as? String ?? "medium"
            executeHaptic(style: style)

        case "show_alert":
            let title = payload?["title"] as? String ?? "Alert"
            let body = payload?["body"] as? String ?? ""
            showNativeAlert(title: title, body: body)

        case "open_url":
            if let urlString = payload?["url"] as? String,
               let url = URL(string: urlString) {
                UIApplication.shared.open(url)
            }

        case "share":
            if let text = payload?["text"] as? String {
                shareText(text)
            }

        case "copy_to_clipboard":
            if let text = payload?["text"] as? String {
                UIPasteboard.general.string = text
            }

        default:
            break
        }
    }

    func executeHaptic(style: String) {
        let generator: UIImpactFeedbackGenerator
        switch style {
        case "light": generator = UIImpactFeedbackGenerator(style: .light)
        case "heavy": generator = UIImpactFeedbackGenerator(style: .heavy)
        default: generator = UIImpactFeedbackGenerator(style: .medium)
        }
        generator.impactOccurred()
    }
}
```

---

## Project Structure

```
Examples/
├── Starter/
│   ├── StarterApp.swift
│   ├── Views/
│   │   ├── OnboardingTriggerView.swift
│   │   └── HomeView.swift
│   ├── Models/
│   │   └── OnboardingData.swift
│   └── Resources/
│       └── Assets.xcassets
│
├── Lockbox/
│   ├── LockboxApp.swift
│   ├── Views/
│   │   ├── NotesListView.swift
│   │   ├── NoteDetailView.swift
│   │   ├── FoldersView.swift
│   │   ├── TagsView.swift
│   │   ├── LockedFeatureView.swift
│   │   └── SettingsView.swift
│   ├── Models/
│   │   └── Note.swift
│   └── Resources/
│       └── Assets.xcassets
│
├── Coinverse/
│   ├── CoinverseApp.swift
│   ├── Views/
│   │   ├── ShopView.swift
│   │   ├── ShopItemCard.swift
│   │   ├── CoinBalanceCard.swift
│   │   └── OwnedItemsView.swift
│   ├── Models/
│   │   └── ShopItem.swift
│   └── Resources/
│       └── Assets.xcassets
│
├── Quota/
│   ├── QuotaApp.swift
│   ├── Views/
│   │   ├── QuotaHomeView.swift
│   │   ├── GeneratorCard.swift
│   │   ├── QuoteCard.swift
│   │   └── QuoteFeed.swift
│   ├── Models/
│   │   └── Quote.swift
│   ├── Services/
│   │   └── QuoteGenerator.swift
│   └── Resources/
│       └── Assets.xcassets
│
├── Persona/
│   ├── PersonaApp.swift
│   ├── Views/
│   │   ├── PersonaHomeView.swift
│   │   ├── PersonaHeroCard.swift
│   │   └── PersonaResultCard.swift
│   ├── Models/
│   │   └── PersonaResult.swift
│   └── Resources/
│       └── Assets.xcassets
│
├── Bridge/
│   ├── BridgeApp.swift
│   ├── Views/
│   │   ├── BridgeView.swift
│   │   └── LogEntryView.swift
│   ├── Models/
│   │   └── LogEntry.swift
│   └── Resources/
│       └── Assets.xcassets
│
└── Shared/
    └── NuxieService.swift          # Shared SDK setup helper
```

---

## Shared SDK Setup

Each app uses a common pattern for SDK initialization:

```swift
// Shared/NuxieService.swift
import Nuxie

@MainActor
class NuxieService {
    static let shared = NuxieService()

    private(set) var isConfigured = false

    func configure(apiKey: String = "demo-api-key") {
        guard !isConfigured else { return }

        let config = NuxieConfiguration(apiKey: apiKey)
        config.environment = .development
        config.logLevel = .debug

        do {
            try NuxieSDK.shared.setup(with: config)
            isConfigured = true
        } catch {
            print("[Nuxie] Setup failed: \(error)")
        }
    }
}

// Usage in each app
@main
struct LockboxApp: App {
    init() {
        NuxieService.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

---

## Design System

All apps share a consistent design language:

### Colors
- Use semantic colors: `.primary`, `.secondary`, `.accentColor`
- Backgrounds: `Color(.systemBackground)`, `Color(.secondarySystemBackground)`
- No hardcoded hex values

### Typography
- Headlines: `.title`, `.title2`, `.headline`
- Body: `.body`, `.subheadline`
- Captions: `.caption`, `.footnote`

### Spacing
- Standard padding: 16pt
- Card padding: 20-24pt
- Section spacing: 24-32pt

### Components
- Rounded rectangles: `cornerRadius: 12` for cards, `16` for large cards
- Buttons: `.borderedProminent` for primary actions
- Subtle shadows where appropriate

### Animations
- Use `.spring()` for interactive elements
- Subtle transitions for state changes

---

## Implementation Order

1. **Starter** - Simplest, establishes patterns
2. **Lockbox** - Core feature gating pattern
3. **Coinverse** - Credit system and reactive updates
4. **Quota** - Metered usage with limits
5. **Persona** - Data binding complexity
6. **Bridge** - Native integration patterns

---

## Success Criteria

1. **Standalone**: Each app builds and runs independently
2. **Beautiful**: UI feels polished and intentional
3. **Educational**: Code is clear and well-commented
4. **Realistic**: Apps feel like something you'd actually build
5. **Feature-complete**: Each app fully demonstrates its SDK features
6. **Consistent**: All apps share design patterns and code style
