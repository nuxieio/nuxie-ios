import Foundation
import Quick
import Nimble
@testable import Nuxie

final class FlowRendererAdapterTests: QuickSpec {
    override class func spec() {
        func makeTarget(
            backend: String,
            buildId: String,
            url: String,
            hash: String,
            requiredCapabilities: [String]? = nil
        ) -> RemoteFlowTarget {
            RemoteFlowTarget(
                compilerBackend: backend,
                buildId: buildId,
                bundle: FlowBundleRef(
                    url: url,
                    manifest: BuildManifest(
                        totalFiles: 1,
                        totalSize: 100,
                        contentHash: hash,
                        files: [
                            BuildFile(
                                path: "index.html",
                                size: 100,
                                contentType: "text/html"
                            ),
                        ]
                    )
                ),
                status: "succeeded",
                requiredCapabilities: requiredCapabilities
            )
        }

        func makeFlow(
            id: String,
            targets: [RemoteFlowTarget]? = nil
        ) -> Flow {
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
                targets: targets,
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
            let id: String
            var createdFlowIds: [String] = []

            init(id: String) {
                self.id = id
            }

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
            var originalSupportedCapabilities: Set<String>!
            var originalPreferredBackends: [String]!
            var originalRenderableBackends: Set<String>!

            beforeEach {
                originalSupportedCapabilities = RemoteFlow.supportedCapabilities
                originalPreferredBackends = RemoteFlow.preferredCompilerBackends
                originalRenderableBackends = RemoteFlow.renderableCompilerBackends
            }

            afterEach {
                RemoteFlow.supportedCapabilities = originalSupportedCapabilities
                RemoteFlow.preferredCompilerBackends = originalPreferredBackends
                RemoteFlow.renderableCompilerBackends = originalRenderableBackends
            }

            it("creates and caches view controllers via the renderer adapter") {
                let adapter = RecordingRendererAdapter(id: "react")
                var created: FlowViewController?
                var cached: FlowViewController?

                waitUntil { done in
                    Task { @MainActor in
                        let cache = FlowViewControllerCache(
                            flowArchiver: FlowArchiver(),
                            fontStore: FontStore(),
                            rendererAdapterRegistry: FlowRendererAdapterRegistry(
                                adapters: [adapter],
                                defaultCompilerBackend: "react"
                            )
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

            it("routes to the selected target backend adapter when available") {
                let reactAdapter = RecordingRendererAdapter(id: "react")
                let riveAdapter = RecordingRendererAdapter(id: "rive")

                RemoteFlow.supportedCapabilities = [
                    "renderer.react.webview.v1",
                    "renderer.rive.native.v1",
                ]
                RemoteFlow.preferredCompilerBackends = ["rive", "react"]
                RemoteFlow.renderableCompilerBackends = ["react", "rive"]

                waitUntil { done in
                    Task { @MainActor in
                        let cache = FlowViewControllerCache(
                            flowArchiver: FlowArchiver(),
                            fontStore: FontStore(),
                            rendererAdapterRegistry: FlowRendererAdapterRegistry(
                                adapters: [reactAdapter, riveAdapter],
                                defaultCompilerBackend: "react"
                            )
                        )

                        let flow = makeFlow(
                            id: "flow-2",
                            targets: [
                                makeTarget(
                                    backend: "react",
                                    buildId: "build-react",
                                    url: "https://cdn.example/react/index.html",
                                    hash: "hash-react",
                                    requiredCapabilities: ["renderer.react.webview.v1"]
                                ),
                                makeTarget(
                                    backend: "rive",
                                    buildId: "build-rive",
                                    url: "https://cdn.example/rive/index.json",
                                    hash: "hash-rive",
                                    requiredCapabilities: ["renderer.rive.native.v1"]
                                ),
                            ]
                        )

                        _ = cache.createViewController(for: flow)
                        done()
                    }
                }

                expect(riveAdapter.createdFlowIds).to(equal(["flow-2"]))
                expect(reactAdapter.createdFlowIds).to(beEmpty())
            }

            it("falls back to default adapter when selected backend has no adapter") {
                let reactAdapter = RecordingRendererAdapter(id: "react")

                RemoteFlow.supportedCapabilities = ["renderer.rive.native.v1"]
                RemoteFlow.preferredCompilerBackends = ["rive", "react"]
                RemoteFlow.renderableCompilerBackends = ["react", "rive"]

                waitUntil { done in
                    Task { @MainActor in
                        let cache = FlowViewControllerCache(
                            flowArchiver: FlowArchiver(),
                            fontStore: FontStore(),
                            rendererAdapterRegistry: FlowRendererAdapterRegistry(
                                adapters: [reactAdapter],
                                defaultCompilerBackend: "react"
                            )
                        )

                        let flow = makeFlow(
                            id: "flow-3",
                            targets: [
                                makeTarget(
                                    backend: "rive",
                                    buildId: "build-rive",
                                    url: "https://cdn.example/rive/index.json",
                                    hash: "hash-rive",
                                    requiredCapabilities: ["renderer.rive.native.v1"]
                                ),
                            ]
                        )

                        _ = cache.createViewController(for: flow)
                        done()
                    }
                }

                expect(reactAdapter.createdFlowIds).to(equal(["flow-3"]))
            }

            it("falls back to default adapter when no compatible target is selected") {
                let reactAdapter = RecordingRendererAdapter(id: "react")

                RemoteFlow.supportedCapabilities = ["renderer.react.webview.v1"]
                RemoteFlow.preferredCompilerBackends = ["rive", "react"]
                RemoteFlow.renderableCompilerBackends = ["react"]

                waitUntil { done in
                    Task { @MainActor in
                        let cache = FlowViewControllerCache(
                            flowArchiver: FlowArchiver(),
                            fontStore: FontStore(),
                            rendererAdapterRegistry: FlowRendererAdapterRegistry(
                                adapters: [reactAdapter],
                                defaultCompilerBackend: "react"
                            )
                        )

                        let flow = makeFlow(
                            id: "flow-4",
                            targets: [
                                makeTarget(
                                    backend: "skia",
                                    buildId: "build-skia",
                                    url: "https://cdn.example/skia/index.bin",
                                    hash: "hash-skia",
                                    requiredCapabilities: []
                                ),
                            ]
                        )

                        _ = cache.createViewController(for: flow)
                        done()
                    }
                }

                expect(reactAdapter.createdFlowIds).to(equal(["flow-4"]))
            }
        }
    }
}
