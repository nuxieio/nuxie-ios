# Starter

A minimal app demonstrating first-launch onboarding with Nuxie SDK.

## What This Demo Shows

- Automatic flow trigger on `$app_installed`
- Flow presentation and completion handling
- Conditional UI based on onboarding state
- Extracting data from completed journeys

## SDK Features Used

- `NuxieSDK.shared.trigger("$app_installed")` - Triggers onboarding flow
- `TriggerUpdate.journey` - Handles journey completion
- `journey.context` - Extracts user-provided data

## App Flow

1. **Launch** - App starts with transparent trigger view
2. **Onboarding Flow** - Nuxie presents onboarding questions
3. **Home** - Shows welcome message with collected preferences

## Running the Demo

```bash
cd Examples/Starter
xcodegen generate
open Starter.xcodeproj
```

Build and run on iOS Simulator.
