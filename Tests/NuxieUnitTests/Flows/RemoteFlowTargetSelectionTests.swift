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
            hash: String
        ) -> RemoteFlowTarget {
            RemoteFlowTarget(
                compilerBackend: backend,
                buildId: buildId,
                bundle: makeBundle(url: url, hash: hash),
                status: status,
                requiredCapabilities: nil
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
                expect(flow.selectedBundle.url).to(equal("https://cdn.example/legacy/index.html"))
                expect(flow.selectedBundle.manifest.contentHash).to(equal("legacy-hash"))
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
