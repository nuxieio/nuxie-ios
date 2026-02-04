import Quick
import Nimble
@testable import Nuxie

final class FontStoreSpec: QuickSpec {
    override class func spec() {
        describe("FontStore MIME type mapping") {
            it("maps common font formats") {
                expect(FontStore.mimeType(for: "woff2")).to(equal("font/woff2"))
                expect(FontStore.mimeType(for: "woff")).to(equal("font/woff"))
                expect(FontStore.mimeType(for: "ttf")).to(equal("font/ttf"))
                expect(FontStore.mimeType(for: "truetype")).to(equal("font/ttf"))
                expect(FontStore.mimeType(for: "otf")).to(equal("font/otf"))
                expect(FontStore.mimeType(for: "opentype")).to(equal("font/otf"))
            }

            it("handles casing and whitespace") {
                expect(FontStore.mimeType(for: " WOFF2 ")).to(equal("font/woff2"))
                expect(FontStore.mimeType(for: "OtF")).to(equal("font/otf"))
            }

            it("falls back to octet-stream") {
                expect(FontStore.mimeType(for: "unknown")).to(equal("application/octet-stream"))
            }
        }
    }
}
