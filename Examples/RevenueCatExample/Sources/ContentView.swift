import SwiftUI

struct ContentView: View {
    @ObservedObject var model: RevenueCatExampleModel

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Text(model.statusText)
                    .multilineTextAlignment(.center)
                    .padding()

                Button("Simulate Purchase") {
                    model.simulatePurchase()
                }
                .buttonStyle(.borderedProminent)

                Button("Simulate Restore") {
                    model.simulateRestore()
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .navigationTitle("RevenueCat Bridge")
        }
    }
}
