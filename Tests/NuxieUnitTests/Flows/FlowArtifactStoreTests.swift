import Foundation
import Quick
import Nimble
@testable import Nuxie

final class FlowArtifactStoreTests: AsyncSpec {
    override class func spec() {
        func writeFixtureArtifact(
            flowId: String = "flow-artifact-store",
            buildId: String = "build-1",
            includeImageAsset: Bool = false
        ) throws -> (baseURL: URL, flow: Flow, cacheURL: URL, rivData: Data, imagePath: String?, imageData: Data?) {
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

            let imagePath = includeImageAsset ? "assets/images/test-image.bin" : nil
            let imageData = includeImageAsset ? Data("fake-image-bytes".utf8) : nil
            let imageSha = imageData.map(FlowArtifactStore.sha256Hex)
            if let imagePath, let imageData {
                let imageURL = remoteURL.appendingPathComponent(imagePath)
                try FileManager.default.createDirectory(
                    at: imageURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try imageData.write(to: imageURL)
            }

            let assetsJSON: String
            if let imagePath, let imageData, let imageSha {
                assetsJSON = """
                {
                  "images": [
                    {
                      "riveAssetId": 1,
                      "riveUniqueName": "test-image",
                      "sourceAssetKey": "test-image-source",
                      "path": "\(imagePath)",
                      "sha256": "\(imageSha)",
                      "contentType": "image/png",
                      "width": 1,
                      "height": 1,
                      "required": true
                    }
                  ],
                  "fonts": []
                }
                """
            } else {
                assetsJSON = "{ \"images\": [], \"fonts\": [] }"
            }

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
              "assets": \(assetsJSON),
              "textInputs": []
            }
            """.data(using: .utf8)!
            try manifestJSON.write(to: remoteURL.appendingPathComponent("nuxie-manifest.json"))

            var contentHashData = Data()
            contentHashData.append(rivData)
            contentHashData.append(manifestJSON)
            if let imageData {
                contentHashData.append(imageData)
            }

            var buildFiles = [
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
            if let imagePath, let imageData {
                buildFiles.append(
                    BuildFile(
                        path: imagePath,
                        size: imageData.count,
                        contentType: "image/png"
                    )
                )
            }

            let buildManifest = BuildManifest(
                totalFiles: buildFiles.count,
                totalSize: buildFiles.reduce(0) { $0 + $1.size },
                contentHash: FlowArtifactStore.sha256Hex(contentHashData),
                files: buildFiles
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
                rivData: rivData,
                imagePath: imagePath,
                imageData: imageData
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

            it("redownloads when a cached external image is missing") {
                let fixture = try writeFixtureArtifact(includeImageAsset: true)
                let store = FlowArtifactStore(cacheDirectory: fixture.cacheURL)

                let downloaded = try await store.getOrDownloadArtifact(for: fixture.flow)
                guard let imagePath = fixture.imagePath,
                      let imageData = fixture.imageData else {
                    fail("Expected image fixture")
                    return
                }

                let cachedImageURL = downloaded.directoryURL.appendingPathComponent(imagePath)
                expect(FileManager.default.fileExists(atPath: cachedImageURL.path)).to(beTrue())
                try FileManager.default.removeItem(at: cachedImageURL)

                let reloaded = try await store.getOrDownloadArtifact(for: fixture.flow)
                expect(reloaded.source).to(equal(.downloadedArtifact))
                expect(try Data(contentsOf: cachedImageURL)).to(equal(imageData))
            }

            it("rejects unsafe manifest paths") {
                expect {
                    try FlowArtifactStore.validateRelativePath("../flow.riv")
                }.to(throwError())
            }
        }
    }
}
