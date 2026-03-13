# Quota

An AI quote generator demonstrating metered usage with Nuxie SDK.

## What This Demo Shows

- Metered feature with balance display
- `useFeatureAndWait()` for confirmed usage
- Limit enforcement with upgrade prompt
- Usage reset concept (daily quotas)

## SDK Features Used

- `NuxieSDK.shared.features.balance("daily_quotes")` - Get remaining quota
- `NuxieSDK.shared.features.feature("daily_quotes")?.unlimited` - Check unlimited status
- `NuxieSDK.shared.useFeatureAndWait("daily_quotes")` - Consume quota with confirmation
- `NuxieSDK.shared.trigger("quota_limit_reached")` - Trigger upgrade flow

## App Features

- Generate inspirational quotes
- Track daily usage (5 quotes/day for free users)
- View quote history
- Upgrade to unlimited quotes

## Screens

1. **Home** - Generate button with quota display
2. **Generating** - Loading animation while "AI" generates
3. **Quote Feed** - History of generated quotes

## Running the Demo

```bash
cd Examples/Quota
xcodegen generate
open Quota.xcodeproj
```

Build and run on iOS Simulator.
