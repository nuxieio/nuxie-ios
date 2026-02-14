import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie

final class FlowViewModelTelemetryTests: AsyncSpec {
    override class func spec() {
        var mockEventService: MockEventService!

        func makeFlow(id: String = "flow-telemetry", url: String = "https://cdn.example/flow/index.html") -> Flow {
            let remoteFlow = RemoteFlow(
                id: id,
                bundle: FlowBundleRef(
                    url: url,
                    manifest: BuildManifest(
                        totalFiles: 1,
                        totalSize: 100,
                        contentHash: "hash-\(id)",
                        files: [BuildFile(path: "index.html", size: 100, contentType: "text/html")]
                    )
                ),
                screens: [
                    RemoteFlowScreen(
                        id: "screen-1",
                        defaultViewModelId: nil,
                        defaultInstanceId: nil
                    ),
                ],
                interactions: [:],
                viewModels: [],
                viewModelInstances: nil,
                converters: nil
            )
            return Flow(remoteFlow: remoteFlow, products: [])
        }

        beforeEach { @MainActor in
            let testConfig = NuxieConfiguration(apiKey: "test-api-key")
            Container.shared.sdkConfiguration.register { testConfig }
            mockEventService = MockEventService()
            Container.shared.eventService.register { mockEventService }
        }

        describe("artifact load telemetry") {
            it("tracks success once per load attempt") { @MainActor in
                let viewModel = FlowViewModel(
                    flow: makeFlow(),
                    archiveService: FlowArchiver(),
                    artifactTelemetryContext: FlowArtifactTelemetryContext(
                        targetCompilerBackend: "rive",
                        targetBuildId: "build-rive",
                        targetSelectionReason: "selected_preferred_backend",
                        adapterCompilerBackend: "react",
                        adapterFallback: true
                    )
                )

                viewModel.handleLoadingFinished()
                viewModel.handleLoadingFinished()

                let successEvents = mockEventService.trackedEvents.filter {
                    $0.name == JourneyEvents.flowArtifactLoadSucceeded
                }
                expect(successEvents.count).to(equal(1))
                let properties = successEvents.first?.properties
                expect(properties?["target_backend"] as? String).to(equal("rive"))
                expect(properties?["adapter_backend"] as? String).to(equal("react"))
                expect(properties?["adapter_fallback"] as? Bool).to(beTrue())
            }

            it("tracks failure when no valid content URL exists") { @MainActor in
                let viewModel = FlowViewModel(
                    flow: makeFlow(id: "flow-invalid", url: ""),
                    archiveService: FlowArchiver()
                )

                viewModel.loadFlow()

                await expect {
                    mockEventService.trackedEvents.first {
                        $0.name == JourneyEvents.flowArtifactLoadFailed
                    }
                }.toEventuallyNot(beNil(), timeout: .seconds(2))

                let failureEvent = mockEventService.trackedEvents.first {
                    $0.name == JourneyEvents.flowArtifactLoadFailed
                }
                let properties = failureEvent?.properties
                expect(properties?["artifact_source"] as? String).to(equal("unavailable"))
                expect(properties?["error_message"] as? String).to(equal("no_content_available"))
            }
        }
    }
}
