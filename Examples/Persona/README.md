# Persona

A personality quiz demonstrating data binding with Nuxie SDK.

## What This Demo Shows

- Sending context data to flows via `sendRuntimeMessage`
- Receiving results from flows via journey completion
- View model binding for dynamic flow content
- Personalized experience based on flow responses

## SDK Features Used

- `NuxieSDK.shared.getFlowViewController(with: "persona_quiz")` - Get flow view controller
- `flowVC.sendRuntimeMessage(type:payload:)` - Send data to flow
- `flowVC.onClose` - Handle flow completion and extract results

## App Features

- Take a personality quiz
- Personalized greeting with your name
- View your persona type and traits
- Retake quiz to get new results

## Screens

1. **Home** - Hero card and name input
2. **Quiz Flow** - Questions presented via Nuxie flow
3. **Results** - Persona type and traits breakdown

## Running the Demo

```bash
cd Examples/Persona
xcodegen generate
open Persona.xcodeproj
```

Build and run on iOS Simulator.
