import Foundation
import Quick
import Nimble
@testable import Nuxie

final class FlowArtifactStoreTests: AsyncSpec {
    override class func spec() {
        func writeFixtureArtifact(
            flowId: String = "flow-artifact-store",
            buildId: String = "build-1"
        ) throws -> (baseURL: URL, flow: Flow, cacheURL: URL, rivData: Data) {
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("nuxie-flow-artifact-store-tests")
                .appendingPathComponent(UUID().uuidString)
            let remoteURL = rootURL.appendingPathComponent("remote")
            let cacheURL = rootURL.appendingPathComponent("cache")
            try FileManager.default.createDirectory(at: remoteURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

            let rivData = Data("fake-riv-bytes".utf8)
            let rivSha = FlowArtifactStore.sha256Hex(rivData)
            try rivData.write(to: remoteURL.appendingPathComponent("flow.riv"))

            let manifestJSON = """
            {
              "version": 1,
              "flowId": "\(flowId)",
              "buildId": "\(buildId)",
              "renderer": "rive",
              "riv": {
                "path": "flow.riv",
                "sha256": "\(rivSha)",
                "sizeBytes": \(rivData.count)
              },
              "entry": {
                "screenId": "screen-1",
                "artboardId": "screen-1",
                "artboardName": "Screen 1",
                "width": 390,
                "height": 844
              },
              "screens": [
                {
                  "screenId": "screen-1",
                  "artboardId": "screen-1",
                  "artboardName": "Screen 1",
                  "width": 390,
                  "height": 844
                }
              ],
              "assets": { "images": [], "fonts": [] },
              "textInputs": []
            }
            """.data(using: .utf8)!
            try manifestJSON.write(to: remoteURL.appendingPathComponent("nuxie-manifest.json"))

            var contentHashData = Data()
            contentHashData.append(rivData)
            contentHashData.append(manifestJSON)

            let buildManifest = BuildManifest(
                totalFiles: 2,
                totalSize: rivData.count + manifestJSON.count,
                contentHash: FlowArtifactStore.sha256Hex(contentHashData),
                files: [
                    BuildFile(
                        path: "flow.riv",
                        size: rivData.count,
                        contentType: "application/octet-stream"
                    ),
                    BuildFile(
                        path: "nuxie-manifest.json",
                        size: manifestJSON.count,
                        contentType: "application/json"
                    ),
                ]
            )
            let remoteFlow = RemoteFlow(
                id: flowId,
                flowArtifact: FlowArtifact(
                    url: remoteURL.absoluteString,
                    buildId: buildId,
                    manifest: buildManifest
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
            return (
                baseURL: remoteURL,
                flow: Flow(remoteFlow: remoteFlow, products: []),
                cacheURL: cacheURL,
                rivData: rivData
            )
        }

        describe("FlowArtifactStore") {
            it("downloads and reuses a verified flow artifact") {
                let fixture = try writeFixtureArtifact()
                let store = FlowArtifactStore(cacheDirectory: fixture.cacheURL)

                let downloaded = try await store.getOrDownloadArtifact(for: fixture.flow)

                expect(downloaded.source).to(equal(.downloadedArtifact))
                expect(downloaded.manifest.flowId).to(equal(fixture.flow.id))
                expect(downloaded.manifest.entry.artboardName).to(equal("Screen 1"))
                expect(try Data(contentsOf: downloaded.rivURL)).to(equal(fixture.rivData))

                let cached = try await store.getOrDownloadArtifact(for: fixture.flow)
                expect(cached.source).to(equal(.cachedArtifact))
                expect(cached.rivURL.path).to(equal(downloaded.rivURL.path))
            }

            it("rejects unsafe manifest paths") {
                expect {
                    try FlowArtifactStore.validateRelativePath("../flow.riv")
                }.to(throwError())
            }
        }
    }
}
