# Lockbox

A simple notes app demonstrating feature gating with Nuxie SDK.

## What This Demo Shows

- Boolean feature gating with `features.isAllowed()`
- Trigger-based paywall presentation
- Handling `TriggerUpdate` stream for entitlement changes
- Real-time UI updates after purchase

## SDK Features Used

- `NuxieSDK.shared.features.isAllowed("pro")` - Check feature access
- `NuxieSDK.shared.trigger("folders_tapped")` - Trigger paywall
- `TriggerUpdate.entitlement` - Handle purchase completion

## App Features

- **Free**: Notes list, create/edit notes
- **Pro (locked)**: Folders, Tags, Export

## Screens

1. **Notes List** - Main view with all notes
2. **Note Detail** - View/edit individual note
3. **Folders** (Pro) - Organize notes in folders
4. **Tags** (Pro) - Tag notes for filtering
5. **Settings** - Plan status and restore purchases

## Running the Demo

```bash
cd Examples/Lockbox
xcodegen generate
open Lockbox.xcodeproj
```

Build and run on iOS Simulator.
