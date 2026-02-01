import Foundation
import WebKit

final class NuxieFontSchemeHandler: NSObject, WKURLSchemeHandler {

    private let fontStore: FontStore

    init(fontStore: FontStore) {
        self.fontStore = fontStore
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(NSError(domain: "NuxieFont", code: 400))
            return
        }

        let fontId = parseFontId(from: url)
        if fontId.isEmpty {
            urlSchemeTask.didFailWithError(NSError(domain: "NuxieFont", code: 404))
            return
        }

        Task {
            if let payload = await fontStore.fontPayload(for: fontId) {
                let response = URLResponse(
                    url: url,
                    mimeType: payload.mimeType,
                    expectedContentLength: payload.data.count,
                    textEncodingName: nil
                )
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(payload.data)
                urlSchemeTask.didFinish()
            } else {
                LogWarning("Missing font for id: \(fontId)")
                urlSchemeTask.didFailWithError(NSError(domain: "NuxieFont", code: 404))
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // No-op
    }

    private func parseFontId(from url: URL) -> String {
        if let host = url.host, !host.isEmpty {
            return host
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path
    }
}
