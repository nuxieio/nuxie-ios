import SwiftUI

@main
struct NuxieE2EApp: App {
  private let configuration = E2EConfiguration.fromProcessInfo()

  var body: some Scene {
    WindowGroup {
      ContentView(configuration: configuration)
    }
  }
}
