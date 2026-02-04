# Coinverse

A virtual shop demonstrating credit systems with Nuxie SDK.

## What This Demo Shows

- Credit system balance display
- `useFeature()` for spending credits
- Reactive balance updates via `@ObservedObject`
- Triggering flows when balance is insufficient

## SDK Features Used

- `NuxieSDK.shared.features.balance("coins")` - Get credit balance
- `NuxieSDK.shared.useFeature("coins", amount: Double)` - Spend credits
- `NuxieSDK.shared.trigger("insufficient_coins", ...)` - Trigger top-up flow

## App Features

- View virtual coin balance
- Browse shop items with prices
- Purchase items using coins
- View owned items
- Get more coins when balance is low

## Screens

1. **Shop Grid** - Browse purchasable items
2. **Item Detail** - View item details and purchase
3. **Owned Items** - Gallery of purchased items

## Running the Demo

```bash
cd Examples/Coinverse
xcodegen generate
open Coinverse.xcodeproj
```

Build and run on iOS Simulator.
