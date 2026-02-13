import Foundation
import Quick
import Nimble
@testable import Nuxie

final class ProfileServiceFlowInvalidationTests: QuickSpec {
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
            status: String = "succeeded",
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

        describe("ProfileService flow cache invalidation") {
            it("refreshes when selected bundle hash changes") {
                let previous = makeFlow(targets: [
                    makeTarget(
                        backend: "react",
                        buildId: "react-v1",
                        url: "https://cdn.example/react-v1/index.html",
                        hash: "hash-v1"
                    ),
                ])
                let next = makeFlow(targets: [
                    makeTarget(
                        backend: "react",
                        buildId: "react-v2",
                        url: "https://cdn.example/react-v2/index.html",
                        hash: "hash-v2"
                    ),
                ])

                expect(ProfileService.shouldRefreshCachedFlow(previous: previous, next: next)).to(beTrue())
            }

            it("refreshes when selected bundle URL changes but hash stays the same") {
                let previous = makeFlow(targets: [
                    makeTarget(
                        backend: "react",
                        buildId: "react-v1",
                        url: "https://cdn.example/react-v1/index.html",
                        hash: "same-hash"
                    ),
                ])
                let next = makeFlow(targets: [
                    makeTarget(
                        backend: "react",
                        buildId: "react-v2",
                        url: "https://cdn.example/react-v2/index.html",
                        hash: "same-hash"
                    ),
                ])

                expect(ProfileService.shouldRefreshCachedFlow(previous: previous, next: next)).to(beTrue())
            }

            it("refreshes when selected target changes but URL and hash are unchanged") {
                let previous = makeFlow(targets: [
                    makeTarget(
                        backend: "react",
                        buildId: "react-v1",
                        url: "https://cdn.example/react/index.html",
                        hash: "same-hash"
                    ),
                ])
                let next = makeFlow(targets: [
                    makeTarget(
                        backend: "react",
                        buildId: "react-v2",
                        url: "https://cdn.example/react/index.html",
                        hash: "same-hash"
                    ),
                ])

                expect(ProfileService.shouldRefreshCachedFlow(previous: previous, next: next)).to(beTrue())
            }

            it("does not refresh when selected target and bundle are unchanged") {
                let previous = makeFlow(targets: [
                    makeTarget(
                        backend: "react",
                        buildId: "react-v1",
                        url: "https://cdn.example/react/index.html",
                        hash: "same-hash"
                    ),
                ])
                let next = makeFlow(targets: [
                    makeTarget(
                        backend: "react",
                        buildId: "react-v1",
                        url: "https://cdn.example/react/index.html",
                        hash: "same-hash"
                    ),
                ])

                expect(ProfileService.shouldRefreshCachedFlow(previous: previous, next: next)).to(beFalse())
            }
        }
    }
}
