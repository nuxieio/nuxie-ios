import Foundation
import WebKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Custom web view for displaying flow content with Nuxie-specific configuration
public class FlowWebView: WKWebView {
    
    // MARK: - Properties
    
    var onLoadingStarted: (() -> Void)?
    var onLoadingFinished: (() -> Void)?
    var onLoadingFailed: ((Error) -> Void)?
    
    /// Message handler for JavaScript communication
    private var messageHandler: FlowMessageHandler!
    private var fontSchemeHandler: NuxieFontSchemeHandler?
    
    // MARK: - Initialization
    
    init(messageHandlerDelegate: FlowMessageHandlerDelegate, fontStore: FontStore) {
        let configuration = WKWebViewConfiguration()
        
        // JavaScript Configuration
        configuration.preferences.javaScriptEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        
        // Data Store (isolated for security)
        configuration.websiteDataStore = .nonPersistent()
        
        // User Agent
        configuration.applicationNameForUserAgent = "NuxieSDK/\(SDKVersion.current)"
        
        // Media Playback Configuration
        #if canImport(UIKit)
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        #endif
        configuration.suppressesIncrementalRendering = false

        let schemeHandler = NuxieFontSchemeHandler(fontStore: fontStore)
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: "nuxie-font")
        self.fontSchemeHandler = schemeHandler
        
        let messageHandler = FlowMessageHandler(delegate: messageHandlerDelegate)
        configuration.userContentController.add(messageHandler, name: "bridge")
        self.messageHandler = messageHandler

        super.init(frame: .zero, configuration: configuration)

        self.messageHandler.webView = self
        
        setupWebView()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - Setup
    
    private func setupWebView() {
        // WebView Appearance
        #if canImport(UIKit)
        isOpaque = false
        backgroundColor = .clear
        scrollView.backgroundColor = .clear
        #elseif canImport(AppKit)
        setValue(false, forKey: "drawsBackground")
        #endif
        
        // Configure scroll view
        #if canImport(UIKit)
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.bounces = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInset = .zero
        scrollView.scrollIndicatorInsets = .zero
        
        // Disable zoom
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 1.0
        scrollView.zoomScale = 1.0
        
        // Disable link preview
        allowsLinkPreview = false
        #endif
        
        // Disable navigation gestures
        allowsBackForwardNavigationGestures = false
        
        // Allow auto layout
        translatesAutoresizingMaskIntoConstraints = false
        
        // Set self as navigation delegate
        navigationDelegate = self
        
        LogDebug("FlowWebView configured with Nuxie settings")
    }
    
    // MARK: - Public Methods
    
    /// Send a message to JavaScript using @nuxie/bridge contract
    public func sendBridgeMessage(type: String, payload: [String: Any] = [:], replyTo: String? = nil, completion: ((Any?, Error?) -> Void)? = nil) {
        var envelope: [String: Any] = [
            "type": type,
            "payload": payload
        ]
        if let replyTo = replyTo {
            envelope["replyTo"] = replyTo
        }
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              let json = String(data: data, encoding: .utf8) else {
            LogError("FlowWebView: Failed to encode bridge message")
            completion?(nil, NSError(domain: "Nuxie", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode bridge message"]))
            return
        }

        let script = """
        (function(){
          try {
            if (window.nuxie && typeof window.nuxie._handleHostMessage === 'function') {
              window.nuxie._handleHostMessage(\(json));
            }
          } catch (e) { /* ignore */ }
        })();
        """

        evaluateJavaScript(script) { result, error in
            if let error = error {
                LogError("FlowWebView: Failed to send bridge message - \(error)")
            }
            completion?(result, error)
        }
    }

    /// Helper: send a response envelope to a prior request
    public func sendBridgeResponse(replyTo: String, result: Any? = nil, error: String? = nil, completion: ((Any?, Error?) -> Void)? = nil) {
        var payload: [String: Any] = [:]
        if let error = error {
            payload["error"] = error
        } else if let result = result {
            payload["result"] = result
        } else {
            payload["result"] = NSNull()
        }
        sendBridgeMessage(type: "response", payload: payload, replyTo: replyTo, completion: completion)
    }
    
    /// Load content from a file URL (for cached archives)
    func loadFileURL(_ url: URL) {
        loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
    
    /// Inject JavaScript into the web view
    func injectJavaScript(_ script: String, completion: ((Any?, Error?) -> Void)? = nil) {
        evaluateJavaScript(script) { result, error in
            completion?(result, error)
        }
    }
}

// MARK: - WKNavigationDelegate

extension FlowWebView: WKNavigationDelegate {
    
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        LogDebug("FlowWebView: Started loading")
        onLoadingStarted?()
    }
    
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        LogDebug("FlowWebView: Finished loading")
        onLoadingFinished?()
    }
    
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        LogError("FlowWebView: Failed to load - \(error)")
        onLoadingFailed?(error)
    }
    
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        LogError("FlowWebView: Failed provisional navigation - \(error)")
        onLoadingFailed?(error)
    }
    
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Allow all navigation for now
        // In future, could add logic to handle external links differently
        decisionHandler(.allow)
    }
}
