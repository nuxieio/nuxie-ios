import Foundation
import UIKit
import WebKit

/// Protocol for receiving bridge messages from JavaScript
protocol FlowMessageHandlerDelegate: AnyObject {
    func messageHandler(_ handler: FlowMessageHandler, didReceiveBridgeMessage type: String, payload: [String: Any], id: String?, from webView: FlowWebView)
}

/// Lightweight message handler that parses JavaScript messages and forwards to delegate
final class FlowMessageHandler: NSObject, WKScriptMessageHandler {
    
    weak var delegate: FlowMessageHandlerDelegate?
    weak var webView: FlowWebView?
    
    init(delegate: FlowMessageHandlerDelegate, webView: FlowWebView? = nil) {
        self.delegate = delegate
        self.webView = webView
        super.init()
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "bridge" else { return }
        guard let webView = (message.webView as? FlowWebView) ?? webView else { return }
        guard let dict = message.body as? [String: Any] else { return }
        guard let type = dict["type"] as? String else { return }

        let id = dict["id"] as? String

        // Reply to ping immediately
        if type == "ping", let reqId = id {
            webView.sendBridgeResponse(replyTo: reqId, result: "pong")
            return
        }

        let payload = dict["payload"] as? [String: Any] ?? [:]
        // Ensure UI-affecting bridge messages are handled on the main thread.
        // WebKit *usually* delivers these on main, but XCTest/WKWebView can surface
        // non-main delivery which breaks UIKit calls like `dismiss(...)`.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.messageHandler(self, didReceiveBridgeMessage: type, payload: payload, id: id, from: webView)
        }
    }
}
