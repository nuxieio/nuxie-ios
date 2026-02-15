# Bridge

A native action playground demonstrating `call_delegate` with Nuxie SDK.

## What This Demo Shows

- `call_delegate` action from flows
- `NotificationCenter` observation for delegate calls
- Handling different message types
- Native iOS capability integration

## SDK Features Used

- `NotificationCenter.default.addObserver(forName: .nuxieCallDelegate, ...)` - Listen for delegate calls
- Various native actions: haptics, alerts, share sheets, URL opening

## Supported Actions

The Bridge app handles these delegate messages:

- `haptic_feedback` - Trigger haptic feedback (light, medium, heavy)
- `show_alert` - Present native UIAlertController
- `open_url` - Open URL in Safari
- `share` - Present share sheet
- `copy_to_clipboard` - Copy text to clipboard

## Screens

1. **Home** - Launch demo flow button and action log
2. **Demo Flow** - Interactive buttons that trigger native actions
3. **Log** - Real-time display of all received delegate calls

## Running the Demo

```bash
cd Examples/Bridge
xcodegen generate
open Bridge.xcodeproj
```

Build and run on iOS Simulator.
