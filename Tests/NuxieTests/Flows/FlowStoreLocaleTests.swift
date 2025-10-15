import Foundation
import Quick
import Nimble
import FactoryKit
@testable import Nuxie

final class FlowStoreLocaleTests: AsyncSpec {
    override class func spec() {
        describe("FlowStore locale handling") {
            var api: MockNuxieApi!
            var productService: MockProductService!
            var flowStore: FlowStore!
            var baseFlow: RemoteFlow!
            let productId = "com.example.monthly"

            beforeEach {
                Container.shared.reset()

                api = MockNuxieApi()
                productService = MockProductService()
                productService.mockProducts = [
                    MockStoreProduct(
                        id: productId,
                        displayName: "Monthly",
                        price: 9.99,
                        displayPrice: "$9.99"
                    )
                ]

                Container.shared.nuxieApi.register { api }
                Container.shared.productService.register { productService }

                flowStore = FlowStore()

                let manifestEN = BuildManifest(
                    totalFiles: 3,
                    totalSize: 1400,
                    contentHash: "hash-en",
                    files: []
                )
                let manifestFR = BuildManifest(
                    totalFiles: 3,
                    totalSize: 1410,
                    contentHash: "hash-fr",
                    files: []
                )

                let flowProduct = RemoteFlowProduct(id: "product-1", extId: productId, name: "Monthly")

                baseFlow = RemoteFlow(
                    id: "flow-locale",
                    name: "Base Flow",
                    url: "https://cdn.example.com/en/index.html",
                    products: [flowProduct],
                    manifest: manifestEN,
                    locale: "en-US",
                    defaultLocale: "en-US",
                    availableLocales: [
                        RemoteFlowLocaleVariant(
                            locale: "fr-FR",
                            url: "https://cdn.example.com/fr/index.html",
                            manifest: manifestFR,
                            products: nil,
                            name: "Flow FR"
                        )
                    ]
                )

                await api.setFlowResponse(baseFlow, locale: nil)
            }

            it("stores web archives with locale-specific filenames") {
                let archiver = FlowArchiver()
                let manifest = BuildManifest(
                    totalFiles: 1,
                    totalSize: 512,
                    contentHash: "hash-fr",
                    files: []
                )

                let flow = RemoteFlow(
                    id: "flow-archive",
                    name: "Locale Flow",
                    url: "https://cdn.example.com/fr/index.html",
                    products: [],
                    manifest: manifest,
                    locale: "fr-FR",
                    defaultLocale: "en-US",
                    availableLocales: []
                )

                let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                let directory = caches.appendingPathComponent("nuxie_flows")
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

                let sanitizedLocale = "fr-FR".replacingOccurrences(of: "[^A-Za-z0-9-]", with: "-", options: .regularExpression)
                let expectedURL = directory.appendingPathComponent("flow_\(flow.id)_\(sanitizedLocale)_\(manifest.contentHash).webarchive")
                try? "stub".data(using: .utf8)?.write(to: expectedURL)

                let cachedURL = await archiver.getArchiveURL(for: flow)
                expect(cachedURL).to(equal(expectedURL))

                try? FileManager.default.removeItem(at: expectedURL)
            }

            afterEach {
                await flowStore.clearCache()
                await api.reset()
                productService.reset()
                Container.shared.reset()
            }

            it("returns cached locale variant using catalog metadata without hitting the API") {
                await flowStore.preloadFlows([baseFlow])

                let localized = try await flowStore.flow(with: baseFlow.id, locale: "fr-FR")

                let apiCalls = await api.fetchFlowCallCount
                expect(apiCalls).to(equal(0))
                expect(localized.localeIdentifier).to(equal("fr-FR"))
                expect(localized.remoteFlow.url).to(equal("https://cdn.example.com/fr/index.html"))

                let cached = await flowStore.getCachedFlow(id: baseFlow.id, locale: "fr-FR")
                expect(cached).toNot(beNil())
                expect(cached?.localeIdentifier).to(equal("fr-FR"))
            }

            it("requests the API when a locale is not present in the catalog") {
                let manifestES = BuildManifest(
                    totalFiles: 3,
                    totalSize: 1420,
                    contentHash: "hash-es",
                    files: []
                )

                let flowProduct = baseFlow.products.first!
                let spanishFlow = RemoteFlow(
                    id: baseFlow.id,
                    name: "Flow ES",
                    url: "https://cdn.example.com/es/index.html",
                    products: [flowProduct],
                    manifest: manifestES,
                    locale: "es-ES",
                    defaultLocale: "en-US",
                    availableLocales: []
                )

                await api.setFlowResponse(spanishFlow, locale: "es-ES")

                await flowStore.preloadFlows([baseFlow])

                let localized = try await flowStore.flow(with: baseFlow.id, locale: "es-ES")

                let apiCalls = await api.fetchFlowCallCount
                expect(apiCalls).to(equal(1))
                expect(localized.localeIdentifier).to(equal("es-ES"))
                expect(localized.remoteFlow.url).to(equal("https://cdn.example.com/es/index.html"))
            }
        }
    }
}
