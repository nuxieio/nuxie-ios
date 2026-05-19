import Foundation
import FactoryKit

#if DEBUG
public enum FlowRuntimeFixtureHost {
    private static let fixtureBaseURLToken = "__NUXIE_FIXTURE_BASE_URL__"

    @MainActor
    public static func makeViewController(
        fixtureBaseURL: URL,
        cacheRootURL: URL,
        flowId: String = "flow-runtime-fixture"
    ) throws -> FlowViewController {
        registerFixtureConfiguration(cacheRootURL: cacheRootURL)

        let fixtureBaseURL = try prepareFixtureBaseURL(
            fixtureBaseURL,
            cacheRootURL: cacheRootURL
        )
        let manifestURL = fixtureBaseURL.appendingPathComponent(FlowArtifactStore.manifestPath)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(FlowArtifactManifest.self, from: manifestData)

        let buildFiles = try buildFiles(
            for: manifest,
            manifestData: manifestData,
            fixtureBaseURL: fixtureBaseURL
        )
        let buildManifest = BuildManifest(
            totalFiles: buildFiles.count,
            totalSize: buildFiles.reduce(0) { $0 + $1.size },
            contentHash: contentHash(for: manifest, manifestData: manifestData, fixtureBaseURL: fixtureBaseURL),
            files: buildFiles
        )
        let remoteFlow = RemoteFlow(
            id: flowId,
            flowArtifact: FlowArtifact(
                url: fixtureBaseURL.absoluteString,
                buildId: manifest.buildId,
                manifest: buildManifest
            ),
            screens: manifest.screens.map {
                RemoteFlowScreen(
                    id: $0.screenId,
                    defaultViewModelId: nil,
                    defaultInstanceId: nil
                )
            },
            interactions: [:],
            viewModels: [],
            viewModelInstances: nil,
            converters: nil
        )

        let runtimeAssetStore = RuntimeAssetStore(
            cacheDirectory: cacheRootURL.appendingPathComponent("runtime-assets")
        )
        let artifactStore = FlowArtifactStore(
            cacheDirectory: cacheRootURL.appendingPathComponent("artifacts"),
            runtimeAssetStore: runtimeAssetStore
        )

        return FlowViewController(
            flow: Flow(remoteFlow: remoteFlow, products: []),
            artifactStore: artifactStore
        )
    }

    private static func prepareFixtureBaseURL(
        _ fixtureBaseURL: URL,
        cacheRootURL: URL
    ) throws -> URL {
        let manifestURL = fixtureBaseURL.appendingPathComponent(FlowArtifactStore.manifestPath)
        let manifestText = try String(contentsOf: manifestURL, encoding: .utf8)
        guard manifestText.contains(fixtureBaseURLToken) else {
            return fixtureBaseURL
        }

        let preparedBaseURL = cacheRootURL.appendingPathComponent(
            "prepared-fixture",
            isDirectory: true
        )
        try? FileManager.default.removeItem(at: preparedBaseURL)
        try FileManager.default.createDirectory(
            at: preparedBaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: fixtureBaseURL, to: preparedBaseURL)

        let replacementBaseURL = preparedBaseURL.absoluteString.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        let preparedManifestText = manifestText.replacingOccurrences(
            of: fixtureBaseURLToken,
            with: replacementBaseURL
        )
        try preparedManifestText.write(
            to: preparedBaseURL.appendingPathComponent(FlowArtifactStore.manifestPath),
            atomically: true,
            encoding: .utf8
        )
        return preparedBaseURL
    }

    private static func registerFixtureConfiguration(cacheRootURL: URL) {
        Container.shared.manager.reset(scope: .sdk)

        let configuration = NuxieConfiguration(apiKey: "flow-runtime-fixture")
        configuration.environment = .development
        configuration.customStoragePath = cacheRootURL.appendingPathComponent("sdk-storage")
        configuration.logLevel = .debug
        configuration.enableConsoleLogging = true
        configuration.enableFileLogging = false
        configuration.enablePlugins = false

        Container.shared.sdkConfiguration.register { configuration }
    }

    private static func buildFiles(
        for manifest: FlowArtifactManifest,
        manifestData: Data,
        fixtureBaseURL: URL
    ) throws -> [BuildFile] {
        var files = [
            BuildFile(
                path: FlowArtifactStore.manifestPath,
                size: manifestData.count,
                contentType: "application/json"
            ),
            BuildFile(
                path: manifest.riv.path,
                size: try fileSize(forRelativePath: manifest.riv.path, fixtureBaseURL: fixtureBaseURL),
                contentType: "application/octet-stream"
            ),
        ]

        for image in manifest.assets.images {
            files.append(
                BuildFile(
                    path: image.path,
                    size: try fileSize(forRelativePath: image.path, fixtureBaseURL: fixtureBaseURL),
                    contentType: image.contentType
                )
            )
        }

        return files
    }

    private static func contentHash(
        for manifest: FlowArtifactManifest,
        manifestData: Data,
        fixtureBaseURL: URL
    ) -> String {
        var data = Data()
        data.append(manifestData)
        if let rivData = try? Data(contentsOf: fixtureBaseURL.appendingPathComponent(manifest.riv.path)) {
            data.append(rivData)
        }
        for image in manifest.assets.images {
            if let imageData = try? Data(contentsOf: fixtureBaseURL.appendingPathComponent(image.path)) {
                data.append(imageData)
            }
        }
        return FlowArtifactStore.sha256Hex(data)
    }

    private static func fileSize(forRelativePath path: String, fixtureBaseURL: URL) throws -> Int {
        let safePath = try FlowArtifactStore.validateRelativePath(path)
        return try Data(contentsOf: fixtureBaseURL.appendingPathComponent(safePath)).count
    }
}
#endif
