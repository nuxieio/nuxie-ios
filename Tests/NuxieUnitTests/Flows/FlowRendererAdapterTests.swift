import Foundation
import Quick
import Nimble
@testable import Nuxie

final class FlowRendererAdapterTests: QuickSpec {
    override class func spec() {
        func makeFlow(id: String) -> Flow {
            let remoteFlow = RemoteFlow(
                id: id,
                bundle: FlowBundleRef(
                    url: "https://cdn.example/\(id)/index.html",
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

        final class RecordingRendererAdapter: FlowRendererAdapter {
            let id: String = "recording"
            var createdFlowIds: [String] = []

            @MainActor
            func makeViewController(
                flow: Flow,
                archiveService: FlowArchiver,
                fontStore: FontStore
            ) -> FlowViewController {
                createdFlowIds.append(flow.id)
                return MockFlowViewController(mockFlowId: flow.id)
            }
        }

        describe("FlowViewControllerCache renderer adapter seam") {
            it("creates and caches view controllers via the renderer adapter") {
                let adapter = RecordingRendererAdapter()
                var created: FlowViewController?
                var cached: FlowViewController?

                waitUntil { done in
                    Task { @MainActor in
                        let cache = FlowViewControllerCache(
                            flowArchiver: FlowArchiver(),
                            fontStore: FontStore(),
                            rendererAdapter: adapter
                        )
                        let flow = makeFlow(id: "flow-1")
                        created = cache.createViewController(for: flow)
                        cached = cache.getCachedViewController(for: flow.id)
                        done()
                    }
                }

                expect(adapter.createdFlowIds).to(equal(["flow-1"]))
                expect(created).toNot(beNil())
                expect(cached).toNot(beNil())
                expect(created).to(beIdenticalTo(cached))
            }
        }
    }
}
