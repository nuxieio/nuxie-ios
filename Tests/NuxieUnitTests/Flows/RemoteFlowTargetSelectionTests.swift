import Foundation
import Quick
import Nimble
@testable import Nuxie

final class RemoteFlowTargetSelectionTests: QuickSpec {
    override class func spec() {
        func makeManifest(hash: String) -> BuildManifest {
            BuildManifest(
                totalFiles: 1,
                totalSize: 128,
                contentHash: hash,
                files: [BuildFile(path: "index.html", size: 128, contentType: "text/html")]
            )
        }

        func makeBundle(url: String, hash: String) -> FlowBundleRef {
            FlowBundleRef(
                url: url,
                manifest: makeManifest(hash: hash)
            )
        }

        func makeTarget(
            backend: String,
            buildId: String,
            status: String,
            url: String,
            hash: String,
            requiredCapabilities: [String]? = nil,
            recommendedSelectionOrder: Int? = nil
        ) -> RemoteFlowTarget {
            RemoteFlowTarget(
                compilerBackend: backend,
                buildId: buildId,
                bundle: makeBundle(url: url, hash: hash),
                status: status,
                requiredCapabilities: requiredCapabilities,
                recommendedSelectionOrder: recommendedSelectionOrder
            )
        }

        func makeFlow(targets: [RemoteFlowTarget]? = nil) -> RemoteFlow {
            RemoteFlow(
                id: "flow-1",
                bundle: makeBundle(url: "https://cdn.example/legacy/index.html", hash: "legacy-hash"),
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
                converters: nil,
            )
        }

        describe("RemoteFlow selected bundle") {
            it("falls back to legacy bundle when targets are absent") {
                let flow = makeFlow()

                expect(flow.selectedTarget).to(beNil())
                expect(flow.selectedTargetResult.reason).to(equal(.targetsMissing))
                expect(flow.selectedBundle.url).to(equal("https://cdn.example/legacy/index.html"))
                expect(flow.selectedBundle.manifest.contentHash).to(equal("legacy-hash"))
            }

            it("prefers a succeeded react target") {
                let flow = makeFlow(targets: [
                    makeTarget(
                        backend: "rive",
                        buildId: "build-rive",
                        status: "succeeded",
                        url: "https://cdn.example/rive/index.html",
                        hash: "rive-hash"
                    ),
                    makeTarget(
                        backend: "react",
                        buildId: "build-react",
                        status: "succeeded",
                        url: "https://cdn.example/react/index.html",
                        hash: "react-hash"
                    ),
                ])

                expect(flow.selectedTarget?.compilerBackend).to(equal("react"))
                expect(flow.selectedTargetResult.reason).to(equal(.selectedPreferredBackend))
                expect(flow.selectedBundle.url).to(equal("https://cdn.example/react/index.html"))
                expect(flow.selectedBundle.manifest.contentHash).to(equal("react-hash"))
            }

            it("falls back to legacy bundle when react targets are in-progress") {
                let flow = makeFlow(targets: [
                    makeTarget(
                        backend: "react",
                        buildId: "build-react-building",
                        status: "building",
                        url: "https://cdn.example/react-building/index.html",
                        hash: "react-building-hash"
                    ),
                    makeTarget(
                        backend: "react",
                        buildId: "build-react-failed",
                        status: "failed",
                        url: "https://cdn.example/react-failed/index.html",
                        hash: "react-failed-hash"
                    ),
                ])

                expect(flow.selectedTarget).to(beNil())
                expect(flow.selectedTargetResult.reason).to(equal(.noSucceededTargets))
                expect(flow.selectedBundle.url).to(equal("https://cdn.example/legacy/index.html"))
                expect(flow.selectedBundle.manifest.contentHash).to(equal("legacy-hash"))
            }

            it("falls back to legacy bundle when only non-react targets exist") {
                let flow = makeFlow(targets: [
                    makeTarget(
                        backend: "rive",
                        buildId: "build-rive",
                        status: "succeeded",
                        url: "https://cdn.example/rive/index.html",
                        hash: "rive-hash"
                    ),
                ])

                expect(flow.selectedTarget).to(beNil())
                expect(flow.selectedTargetResult.reason).to(equal(.noCapabilityCompatibleTargets))
                expect(flow.selectedBundle.url).to(equal("https://cdn.example/legacy/index.html"))
                expect(flow.selectedBundle.manifest.contentHash).to(equal("legacy-hash"))
            }

            it("falls back to legacy bundle when required capabilities are unsupported") {
                let flow = makeFlow(targets: [
                    makeTarget(
                        backend: "react",
                        buildId: "build-react",
                        status: "succeeded",
                        url: "https://cdn.example/react/index.html",
                        hash: "react-hash",
                        requiredCapabilities: ["renderer.react.webview.v1"]
                    ),
                ])

                expect(flow.selectedTarget(supportedCapabilities: [])).to(beNil())
                expect(flow.selectedTargetResult(
                    supportedCapabilities: []
                ).reason).to(equal(.noCapabilityCompatibleTargets))
                expect(flow.selectedBundle(supportedCapabilities: []).url).to(equal("https://cdn.example/legacy/index.html"))
                expect(flow.selectedBundle(supportedCapabilities: []).manifest.contentHash).to(equal("legacy-hash"))
            }

            it("treats explicit empty required capabilities as no requirements") {
                let flow = makeFlow(targets: [
                    makeTarget(
                        backend: "rive",
                        buildId: "build-rive",
                        status: "succeeded",
                        url: "https://cdn.example/rive/index.html",
                        hash: "rive-hash",
                        requiredCapabilities: []
                    ),
                ])

                let selected = flow.selectedTarget(
                    supportedCapabilities: [],
                    preferredCompilerBackends: ["rive", "react"],
                    renderableCompilerBackends: ["react", "rive"]
                )
                expect(selected?.buildId).to(equal("build-rive"))
                expect(selected?.bundle.url).to(equal("https://cdn.example/rive/index.html"))
            }

            it("selects a compatible succeeded react target when multiple succeeded targets exist") {
                let flow = makeFlow(targets: [
                    makeTarget(
                        backend: "react",
                        buildId: "build-react-v2",
                        status: "succeeded",
                        url: "https://cdn.example/react-v2/index.html",
                        hash: "react-v2-hash",
                        requiredCapabilities: ["renderer.react.webview.v2"]
                    ),
                    makeTarget(
                        backend: "react",
                        buildId: "build-react-v1",
                        status: "succeeded",
                        url: "https://cdn.example/react-v1/index.html",
                        hash: "react-v1-hash",
                        requiredCapabilities: ["renderer.react.webview.v1"]
                    ),
                ])

                let selected = flow.selectedTarget(
                    supportedCapabilities: ["renderer.react.webview.v1"]
                )
                expect(selected?.buildId).to(equal("build-react-v1"))
                expect(flow.selectedBundle(
                    supportedCapabilities: ["renderer.react.webview.v1"]
                ).url).to(equal("https://cdn.example/react-v1/index.html"))
            }

            it("selects rive target when preference and capabilities allow it") {
                let flow = makeFlow(targets: [
                    makeTarget(
                        backend: "react",
                        buildId: "build-react",
                        status: "succeeded",
                        url: "https://cdn.example/react/index.html",
                        hash: "react-hash",
                        requiredCapabilities: ["renderer.react.webview.v1"]
                    ),
                    makeTarget(
                        backend: "rive",
                        buildId: "build-rive",
                        status: "succeeded",
                        url: "https://cdn.example/rive/index.html",
                        hash: "rive-hash",
                        requiredCapabilities: ["renderer.rive.native.v1"]
                    ),
                ])

                let selected = flow.selectedTarget(
                    supportedCapabilities: ["renderer.rive.native.v1"],
                    preferredCompilerBackends: ["rive", "react"],
                    renderableCompilerBackends: ["react", "rive"]
                )
                expect(selected?.compilerBackend).to(equal("rive"))
                expect(selected?.buildId).to(equal("build-rive"))
            }

            it("honors manifest recommended selection order when multiple backends are renderable") {
                let flow = makeFlow(targets: [
                    makeTarget(
                        backend: "react",
                        buildId: "build-react",
                        status: "succeeded",
                        url: "https://cdn.example/react/index.html",
                        hash: "react-hash",
                        requiredCapabilities: [],
                        recommendedSelectionOrder: 1
                    ),
                    makeTarget(
                        backend: "rive",
                        buildId: "build-rive",
                        status: "succeeded",
                        url: "https://cdn.example/rive/index.html",
                        hash: "rive-hash",
                        requiredCapabilities: [],
                        recommendedSelectionOrder: 0
                    ),
                ])

                let selected = flow.selectedTarget(
                    supportedCapabilities: [],
                    preferredCompilerBackends: ["react", "rive"],
                    renderableCompilerBackends: ["react", "rive"]
                )
                expect(selected?.compilerBackend).to(equal("rive"))
                expect(selected?.buildId).to(equal("build-rive"))
            }

            it("falls back to preferred backend order when recommendation is absent") {
                let flow = makeFlow(targets: [
                    makeTarget(
                        backend: "react",
                        buildId: "build-react",
                        status: "succeeded",
                        url: "https://cdn.example/react/index.html",
                        hash: "react-hash",
                        requiredCapabilities: []
                    ),
                    makeTarget(
                        backend: "rive",
                        buildId: "build-rive",
                        status: "succeeded",
                        url: "https://cdn.example/rive/index.html",
                        hash: "rive-hash",
                        requiredCapabilities: []
                    ),
                ])

                let selected = flow.selectedTarget(
                    supportedCapabilities: [],
                    preferredCompilerBackends: ["react", "rive"],
                    renderableCompilerBackends: ["react", "rive"]
                )
                expect(selected?.compilerBackend).to(equal("react"))
                expect(selected?.buildId).to(equal("build-react"))
            }

            it("falls back to legacy bundle when target backend is not renderable") {
                let flow = makeFlow(targets: [
                    makeTarget(
                        backend: "rive",
                        buildId: "build-rive",
                        status: "succeeded",
                        url: "https://cdn.example/rive/index.html",
                        hash: "rive-hash",
                        requiredCapabilities: []
                    ),
                ])

                let selected = flow.selectedTarget(
                    supportedCapabilities: [],
                    preferredCompilerBackends: ["rive", "react"],
                    renderableCompilerBackends: ["react"]
                )
                let selection = flow.selectedTargetResult(
                    supportedCapabilities: [],
                    preferredCompilerBackends: ["rive", "react"],
                    renderableCompilerBackends: ["react"]
                )
                expect(selected).to(beNil())
                expect(selection.reason).to(equal(.noRenderableTargets))
                expect(flow.selectedBundle(
                    supportedCapabilities: []
                ).url).to(equal("https://cdn.example/legacy/index.html"))
            }

            it("falls back to legacy bundle when only unknown backends are available") {
                let flow = makeFlow(targets: [
                    makeTarget(
                        backend: "custom_backend",
                        buildId: "build-custom-1",
                        status: "succeeded",
                        url: "https://cdn.example/custom-1/index.html",
                        hash: "custom-1-hash"
                    ),
                    makeTarget(
                        backend: "custom_backend",
                        buildId: "build-custom-2",
                        status: "succeeded",
                        url: "https://cdn.example/custom-2/index.html",
                        hash: "custom-2-hash"
                    ),
                ])

                let selected = flow.selectedTarget(
                    supportedCapabilities: [],
                    preferredCompilerBackends: ["react", "rive"]
                )
                expect(selected).to(beNil())
                expect(flow.selectedTargetResult(
                    supportedCapabilities: [],
                    preferredCompilerBackends: ["react", "rive"]
                ).reason).to(equal(.noRenderableTargets))
                expect(flow.selectedBundle(
                    supportedCapabilities: []
                ).url).to(equal("https://cdn.example/legacy/index.html"))
            }

            it("returns no preferred backend match when compatible targets exclude preference order") {
                let flow = makeFlow(targets: [
                    makeTarget(
                        backend: "rive",
                        buildId: "build-rive",
                        status: "succeeded",
                        url: "https://cdn.example/rive/index.html",
                        hash: "rive-hash",
                        requiredCapabilities: []
                    ),
                ])

                let selection = flow.selectedTargetResult(
                    supportedCapabilities: [],
                    preferredCompilerBackends: ["react"],
                    renderableCompilerBackends: ["react", "rive"]
                )
                expect(selection.target).to(beNil())
                expect(selection.reason).to(equal(.noPreferredBackendMatch))
            }
        }

        describe("Flow selected bundle projection") {
            it("uses the selected bundle for Flow url and manifest") {
                let remoteFlow = makeFlow(targets: [
                    makeTarget(
                        backend: "react",
                        buildId: "build-react",
                        status: "succeeded",
                        url: "https://cdn.example/react/index.html",
                        hash: "react-hash"
                    ),
                ])
                let flow = Flow(remoteFlow: remoteFlow)

                expect(flow.url).to(equal("https://cdn.example/react/index.html"))
                expect(flow.manifest.contentHash).to(equal("react-hash"))
            }
        }
    }
}
