import Foundation
import FactoryKit
import UserNotifications
#if canImport(RiveRuntime) && canImport(UIKit)
import RiveRuntime
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(CoreLocation) && !os(macOS)
import CoreLocation
#endif
#if canImport(Photos)
import Photos
#endif
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(SafariServices)
import SafariServices
#endif

protocol NotificationAuthorizationHandling {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
}

enum TrackingAuthorizationStatus {
    case authorized
    case denied
    case restricted
    case notDetermined
    case unsupported
}

protocol TrackingAuthorizationHandling {
    func authorizationStatus() -> TrackingAuthorizationStatus
    func requestAuthorization() async -> TrackingAuthorizationStatus
}

enum PermissionAuthorizationStatus {
    case granted
    case denied
    case restricted
    case limited
    case notDetermined
    case unsupported
}

protocol PermissionAuthorizationHandling {
    func authorizationStatus() -> PermissionAuthorizationStatus
    func requestAuthorization() async -> PermissionAuthorizationStatus
}

struct UserNotificationAuthorizationHandler: NotificationAuthorizationHandling {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: options)
    }
}

struct CameraPermissionAuthorizationHandler: PermissionAuthorizationHandling {
    func authorizationStatus() -> PermissionAuthorizationStatus {
        #if canImport(AVFoundation)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .granted
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unsupported
        }
        #else
        return .unsupported
        #endif
    }

    func requestAuthorization() async -> PermissionAuthorizationStatus {
        #if canImport(AVFoundation)
        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }
        return granted ? .granted : .denied
        #else
        return .unsupported
        #endif
    }
}

struct MicrophonePermissionAuthorizationHandler: PermissionAuthorizationHandling {
    func authorizationStatus() -> PermissionAuthorizationStatus {
        #if canImport(AVFoundation) && !os(macOS)
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .undetermined:
            return .notDetermined
        @unknown default:
            return .unsupported
        }
        #else
        return .unsupported
        #endif
    }

    func requestAuthorization() async -> PermissionAuthorizationStatus {
        #if canImport(AVFoundation) && !os(macOS)
        let granted = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        return granted ? .granted : .denied
        #else
        return .unsupported
        #endif
    }
}

struct PhotoLibraryPermissionAuthorizationHandler: PermissionAuthorizationHandling {
    func authorizationStatus() -> PermissionAuthorizationStatus {
        #if canImport(Photos)
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized:
            return .granted
        case .limited:
            return .limited
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unsupported
        }
        #else
        return .unsupported
        #endif
    }

    func requestAuthorization() async -> PermissionAuthorizationStatus {
        #if canImport(Photos)
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        switch status {
        case .authorized:
            return .granted
        case .limited:
            return .limited
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unsupported
        }
        #else
        return .unsupported
        #endif
    }
}

final class LocationPermissionAuthorizationHandler: NSObject, PermissionAuthorizationHandling {
    #if canImport(CoreLocation) && !os(macOS)
    private var manager: CLLocationManager?
    private var continuations: [CheckedContinuation<PermissionAuthorizationStatus, Never>] = []

    private static func map(_ status: CLAuthorizationStatus) -> PermissionAuthorizationStatus {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            return .granted
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unsupported
        }
    }

    private func resolveContinuationIfNeeded(_ status: CLAuthorizationStatus) {
        let resolvedStatus = Self.map(status)
        guard resolvedStatus != .notDetermined,
              !continuations.isEmpty
        else { return }

        let pendingContinuations = continuations
        continuations.removeAll()
        pendingContinuations.forEach { continuation in
            continuation.resume(returning: resolvedStatus)
        }
    }
    #endif

    func authorizationStatus() -> PermissionAuthorizationStatus {
        #if canImport(CoreLocation) && !os(macOS)
        return Self.map(CLLocationManager.authorizationStatus())
        #else
        return .unsupported
        #endif
    }

    func requestAuthorization() async -> PermissionAuthorizationStatus {
        #if canImport(CoreLocation) && !os(macOS)
        let currentStatus = authorizationStatus()
        guard currentStatus == .notDetermined else {
            return currentStatus
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                self.continuations.append(continuation)
                let shouldRequestAuthorization = self.continuations.count == 1

                let manager: CLLocationManager
                if let existingManager = self.manager {
                    manager = existingManager
                } else {
                    let createdManager = CLLocationManager()
                    self.manager = createdManager
                    manager = createdManager
                }

                manager.delegate = self

                if shouldRequestAuthorization {
                    manager.requestWhenInUseAuthorization()
                }
            }
        }
        #else
        return .unsupported
        #endif
    }
}

#if canImport(CoreLocation) && !os(macOS)
extension LocationPermissionAuthorizationHandler: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        resolveContinuationIfNeeded(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        resolveContinuationIfNeeded(status)
    }
}
#endif

struct AppTrackingAuthorizationHandler: TrackingAuthorizationHandling {
    func authorizationStatus() -> TrackingAuthorizationStatus {
        #if canImport(AppTrackingTransparency)
        if #available(iOS 14, *) {
            return TrackingAuthorizationStatus(ATTrackingManager.trackingAuthorizationStatus)
        }
        #endif
        return .unsupported
    }

    func requestAuthorization() async -> TrackingAuthorizationStatus {
        #if canImport(AppTrackingTransparency)
        if #available(iOS 14, *) {
            return await withCheckedContinuation { continuation in
                ATTrackingManager.requestTrackingAuthorization { status in
                    continuation.resume(returning: TrackingAuthorizationStatus(status))
                }
            }
        }
        #endif
        return .unsupported
    }
}

#if canImport(AppTrackingTransparency)
@available(iOS 14, *)
private extension TrackingAuthorizationStatus {
    init(_ status: ATTrackingManager.AuthorizationStatus) {
        switch status {
        case .authorized:
            self = .authorized
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        case .notDetermined:
            self = .notDetermined
        @unknown default:
            self = .restricted
        }
    }
}
#endif

struct FlowRendererInteraction {
    let trigger: InteractionTrigger
    let screenId: String?
    let componentId: String?
    let instanceId: String?
    let properties: [String: Any]
}

struct FlowRendererEvent {
    let name: String
    let properties: [String: Any]
    let screenId: String?
    let componentId: String?
    let instanceId: String?
}

struct FlowRendererViewModelChange {
    let path: VmPathRef
    let value: Any
    let source: String?
    let screenId: String?
    let instanceId: String?
}

struct FlowRendererOpenLinkRequest {
    let urlString: String
    let target: String?
    let screenId: String?
    let instanceId: String?
}

protocol FlowRuntimeDelegate: AnyObject {
    func flowViewControllerDidBecomeReady(_ controller: FlowViewController)

    func flowViewController(
        _ controller: FlowViewController,
        didChangeScreen screenId: String
    )

    func flowViewController(
        _ controller: FlowViewController,
        didEmitInteraction interaction: FlowRendererInteraction
    )

    func flowViewController(
        _ controller: FlowViewController,
        didEmitEvent event: FlowRendererEvent
    )

    func flowViewController(
        _ controller: FlowViewController,
        didEmitViewModelChange change: FlowRendererViewModelChange
    )

    func flowViewController(
        _ controller: FlowViewController,
        didRequestOpenLink request: FlowRendererOpenLinkRequest
    )

    func flowViewControllerDidRequestDismiss(_ controller: FlowViewController, reason: CloseReason)
}

protocol NotificationPermissionEventReceiver: AnyObject {
    func flowViewController(
        _ controller: FlowViewController,
        didResolveNotificationPermissionEvent eventName: String,
        properties: [String: Any],
        journeyId: String
    )
}

protocol TrackingPermissionEventReceiver: AnyObject {
    func flowViewController(
        _ controller: FlowViewController,
        didResolveTrackingPermissionEvent eventName: String,
        properties: [String: Any],
        journeyId: String
    )
}

protocol RequestPermissionEventReceiver: AnyObject {
    func flowViewController(
        _ controller: FlowViewController,
        didResolveRequestPermissionEvent eventName: String,
        properties: [String: Any],
        journeyId: String
    )

    func flowViewController(
        _ controller: FlowViewController,
        didIgnoreUnsupportedRequestPermissionType permissionType: String,
        journeyId: String
    )
}

extension FlowRuntimeDelegate {
    func flowViewControllerDidBecomeReady(_ controller: FlowViewController) {}

    func flowViewController(
        _ controller: FlowViewController,
        didChangeScreen screenId: String
    ) {}

    func flowViewController(
        _ controller: FlowViewController,
        didEmitInteraction interaction: FlowRendererInteraction
    ) {}

    func flowViewController(
        _ controller: FlowViewController,
        didEmitEvent event: FlowRendererEvent
    ) {}

    func flowViewController(
        _ controller: FlowViewController,
        didEmitViewModelChange change: FlowRendererViewModelChange
    ) {}

    func flowViewController(
        _ controller: FlowViewController,
        didRequestOpenLink request: FlowRendererOpenLinkRequest
    ) {}
}

/// FlowViewController - displays native flow content with loading and error states.
public class FlowViewController: NuxiePlatformViewController {
    private enum NativeRuntimeCommand {
        case viewModelSnapshot(FlowViewModelSnapshot, screenId: String?)
        case viewModelValue(path: VmPathRef, value: Any, screenId: String?, instanceId: String?)
        case viewModelList(operation: FlowViewModelListOperation, path: VmPathRef, payload: [String: Any], screenId: String?, instanceId: String?)
        case viewModelTrigger(path: VmPathRef, screenId: String?, instanceId: String?)
        case navigate(screenId: String, transition: Any?)
    }

    // MARK: - Properties

    private let viewModel: FlowViewModel
    var notificationAuthorizationHandler: NotificationAuthorizationHandling = UserNotificationAuthorizationHandler()
    var cameraPermissionAuthorizationHandler: PermissionAuthorizationHandling = CameraPermissionAuthorizationHandler()
    var locationPermissionAuthorizationHandler: PermissionAuthorizationHandling = LocationPermissionAuthorizationHandler()
    var microphonePermissionAuthorizationHandler: PermissionAuthorizationHandling = MicrophonePermissionAuthorizationHandler()
    var photoLibraryPermissionAuthorizationHandler: PermissionAuthorizationHandling = PhotoLibraryPermissionAuthorizationHandler()
    var trackingAuthorizationHandler: TrackingAuthorizationHandling = AppTrackingAuthorizationHandler()
    var cameraUsageDescriptionProvider: () -> String? = {
        Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String
    }
    var locationUsageDescriptionProvider: () -> String? = {
        Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") as? String
    }
    var microphoneUsageDescriptionProvider: () -> String? = {
        Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
    }
    var photoLibraryUsageDescriptionProvider: () -> String? = {
        Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") as? String
    }
    var trackingUsageDescriptionProvider: () -> String? = {
        Bundle.main.object(forInfoDictionaryKey: "NSUserTrackingUsageDescription") as? String
    }

    /// Delegate for runtime bridge messages
    weak var runtimeDelegate: FlowRuntimeDelegate? {
        didSet {
            if let receiver = runtimeDelegate as? NotificationPermissionEventReceiver {
                notificationPermissionEventReceiver = receiver
            }
            if let receiver = runtimeDelegate as? TrackingPermissionEventReceiver {
                trackingPermissionEventReceiver = receiver
            }
            if let receiver = runtimeDelegate as? RequestPermissionEventReceiver {
                requestPermissionEventReceiver = receiver
            }
        }
    }

    /// Dedicated receiver for native notification permission results.
    ///
    /// This is retained separately from `runtimeDelegate` because permission
    /// responses can arrive after the journey delegate has been removed from the
    /// active journey maps during identity changes or cancellation.
    var notificationPermissionEventReceiver: NotificationPermissionEventReceiver?
    var requestPermissionEventReceiver: RequestPermissionEventReceiver?
    var trackingPermissionEventReceiver: TrackingPermissionEventReceiver?

    /// Closure called when the flow is closed
    public var onClose: ((CloseReason) -> Void)?

    public var colorSchemeMode: FlowColorSchemeMode = .light {
        didSet {
            guard oldValue != colorSchemeMode else { return }
            guard isViewLoaded else { return }
            applyColorSchemeMode()
        }
    }

    // UI Components
    #if canImport(RiveRuntime) && canImport(UIKit)
    private var flowRiveViewModel: RiveViewModel?
    private var flowRiveView: RiveView?
    private var flowViewModelBridge: FlowViewModelBridge?
    private var textInputOverlayBridge: FlowTextInputOverlayBridge?
    private var flowArtifact: LoadedFlowArtifact?
    private var activeNativeScreenId: String?
    private var pendingNativeScreenBindingId: String?
    #endif
    #if canImport(UIKit)
    var loadingView: UIView!
    var errorView: UIView!
    var activityIndicator: UIActivityIndicatorView!
    var refreshButton: UIButton!
    var closeButton: UIButton!
    #elseif canImport(AppKit)
    var loadingView: NSView!
    var errorView: NSView!
    var activityIndicator: NSProgressIndicator!
    var refreshButton: NSButton!
    var closeButton: NSButton!
    #endif

    private var runtimeReady = false
    private var pendingNativeRuntimeCommands: [NativeRuntimeCommand] = []
    private var didInvokeClose = false

    // MARK: - Computed Properties

    var flow: Flow {
        return viewModel.flow
    }

    var products: [FlowProduct] {
        return viewModel.products
    }

    // MARK: - Initialization

    init(
        flow: Flow,
        artifactStore: FlowArtifactStore,
        artifactTelemetryContext: FlowArtifactTelemetryContext? = nil
    ) {
        self.viewModel = FlowViewModel(
            flow: flow,
            artifactStore: artifactStore,
            artifactTelemetryContext: artifactTelemetryContext
        )
        super.init(nibName: nil, bundle: nil)

        setupBindings()
        LogDebug("FlowViewController initialized for flow: \(flow.id)")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        applyColorSchemeMode()
        viewModel.loadFlow()
    }

    #if canImport(UIKit)
    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }

    public override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        #if canImport(RiveRuntime)
        textInputOverlayBridge?.layout()
        #endif
    }
    #endif

    // MARK: - Public Methods

    func preloadView() {
        // Force view to load
        _ = self.view
        LogDebug("Preloaded view for flow: \(flow.id)")
    }

    func updateProducts(_ newProducts: [FlowProduct]) {
        viewModel.updateProducts(newProducts)
    }

    func updateFlowIfNeeded(_ newFlow: Flow) {
        viewModel.updateFlowIfNeeded(newFlow)
    }

    func updateArtifactTelemetryContext(_ context: FlowArtifactTelemetryContext) {
        viewModel.updateArtifactTelemetryContext(context)
    }

    func performPurchase(productId: String, placementIndex: Any? = nil) {
        handleNativePurchase(productId: productId)
    }

    func performRestore() {
        handleNativeRestore()
    }

    func performRequestNotifications(journeyId: String? = nil) {
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.resolveNotificationAuthorizationOutcome()
            let properties = self.journeyScopedEventProperties(journeyId: journeyId)
            let eventName: String
            switch outcome {
            case .enabled:
                eventName = SystemEventNames.notificationsEnabled
            case .denied:
                eventName = SystemEventNames.notificationsDenied
            }
            self.dispatchNotificationPermissionEvent(
                eventName,
                properties: properties,
                journeyId: journeyId
            )
        }
    }

    func performRequestPermission(permissionType: String, journeyId: String? = nil) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let resolution = await self.resolveRequestPermissionOutcome(
                permissionType: permissionType
            )
            guard case let .status(outcome) = resolution else {
                self.handleUnsupportedRequestPermission(
                    permissionType: permissionType,
                    journeyId: journeyId
                )
                return
            }
            guard outcome != .unsupported else {
                self.handleUnsupportedRequestPermission(
                    permissionType: permissionType,
                    journeyId: journeyId
                )
                return
            }
            let properties = self.permissionEventProperties(
                journeyId: journeyId,
                permissionType: permissionType
            )
            let eventName: String
            switch outcome {
            case .granted:
                eventName = SystemEventNames.permissionGranted
            case .denied, .restricted, .notDetermined:
                eventName = SystemEventNames.permissionDenied
            case .limited:
                eventName = SystemEventNames.permissionGranted
            case .unsupported:
                return
            }
            self.dispatchRequestPermissionEvent(
                eventName,
                properties: properties,
                journeyId: journeyId
            )
        }
    }

    func performRequestTracking(journeyId: String? = nil) {
        let currentStatus = trackingAuthorizationHandler.authorizationStatus()
        if currentStatus == .unsupported {
            LogWarning("FlowViewController: tracking authorization is unsupported on this platform; skipping event")
            if let journeyId, !journeyId.isEmpty,
               let receiver = trackingPermissionEventReceiver {
                receiver.flowViewController(
                    self,
                    didResolveTrackingPermissionEvent: SystemEventNames.trackingDenied,
                    properties: journeyScopedEventProperties(journeyId: journeyId),
                    journeyId: journeyId
                )
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.resolveTrackingAuthorizationOutcome(
                currentStatus: currentStatus
            )
            let properties = self.journeyScopedEventProperties(journeyId: journeyId)
            let eventName: String
            switch outcome {
            case .authorized:
                eventName = SystemEventNames.trackingAuthorized
            case .denied:
                eventName = SystemEventNames.trackingDenied
            case .unsupported:
                return
            }
            self.dispatchTrackingPermissionEvent(
                eventName,
                properties: properties,
                journeyId: journeyId
            )
        }
    }

    func emitSystemEvent(_ name: String, properties: [String: Any]) {
        NuxieSDK.shared.trigger(name, properties: properties.isEmpty ? nil : properties)
    }

    func performDismiss(reason: CloseReason = .userDismissed) {
        runtimeDelegate?.flowViewControllerDidRequestDismiss(self, reason: reason)

        #if canImport(UIKit)
        dismiss(animated: true) { [weak self] in
            self?.invokeOnCloseOnce(reason)
        }
        #elseif canImport(AppKit)
        view.window?.orderOut(nil)
        invokeOnCloseOnce(reason)
        #endif

        // Fallback: ensure onClose is invoked even if platform dismissal completion never fires.
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            self.invokeOnCloseOnce(reason)
        }
    }

    func performOpenLink(urlString: String, target: String? = nil) {
        guard let url = URL(string: urlString) else { return }
        let normalizedTarget = target?.lowercased()

        if normalizedTarget == "in_app" {
            let scheme = url.scheme?.lowercased()
            guard scheme == "http" || scheme == "https" else { return }
            #if canImport(UIKit)
            let safariViewController = SFSafariViewController(url: url)
            present(safariViewController, animated: true)
            #elseif canImport(AppKit)
            NSWorkspace.shared.open(url)
            #endif
            return
        }

        #if canImport(UIKit)
        guard UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    func applyViewModelSnapshot(_ snapshot: FlowViewModelSnapshot, screenId: String? = nil) {
        enqueueNativeRuntimeCommand(.viewModelSnapshot(snapshot, screenId: screenId))
    }

    func applyViewModelValue(
        path: VmPathRef,
        value: Any,
        screenId: String? = nil,
        instanceId: String? = nil
    ) {
        enqueueNativeRuntimeCommand(
            .viewModelValue(
                path: path,
                value: value,
                screenId: screenId,
                instanceId: instanceId
            )
        )
    }

    func applyViewModelListOperation(
        _ operation: FlowViewModelListOperation,
        path: VmPathRef,
        payload: [String: Any],
        screenId: String? = nil,
        instanceId: String? = nil
    ) {
        enqueueNativeRuntimeCommand(
            .viewModelList(
                operation: operation,
                path: path,
                payload: payload,
                screenId: screenId,
                instanceId: instanceId
            )
        )
    }

    func fireViewModelTrigger(
        path: VmPathRef,
        screenId: String? = nil,
        instanceId: String? = nil
    ) {
        enqueueNativeRuntimeCommand(
            .viewModelTrigger(
                path: path,
                screenId: screenId,
                instanceId: instanceId
            )
        )
    }

    func navigate(to screenId: String, transition: Any? = nil) {
        enqueueNativeRuntimeCommand(.navigate(screenId: screenId, transition: transition))
    }

    // MARK: - Setup

    private func setupBindings() {
        // Bind to view model state changes
        viewModel.onStateChanged = { [weak self] state in
            self?.updateUIState(state)
        }

        viewModel.onLoadArtifact = { [weak self] artifact in
            self?.mountFlowArtifact(artifact)
        }
    }

    private func setupViews() {
        platformApplyDefaultBackgroundColor()
        #if canImport(UIKit)
        view.clipsToBounds = true
        #endif

        platformSetupLoadingView()
        platformSetupErrorView()

        // Start in loading state
        updateUIState(.loading)
    }

    private func mountFlowArtifact(_ artifact: LoadedFlowArtifact) {
        #if canImport(RiveRuntime) && canImport(UIKit)
        do {
            runtimeReady = false
            flowRiveView?.removeFromSuperview()
            flowRiveView = nil
            flowRiveViewModel = nil
            flowViewModelBridge = nil
            textInputOverlayBridge?.clear()
            textInputOverlayBridge = nil
            flowArtifact = nil
            activeNativeScreenId = nil
            pendingNativeScreenBindingId = nil

            let data = try Data(contentsOf: artifact.rivURL)
            let riveFile = try RiveFile(
                data: data,
                loadCdn: false,
                customAssetLoader: { [weak self] asset, embeddedData, factory in
                    self?.loadRiveAsset(
                        asset,
                        embeddedData: embeddedData,
                        factory: factory,
                        artifact: artifact
                    ) ?? false
                }
            )
            let model = RiveModel(riveFile: riveFile)
            let riveViewModel = RiveViewModel(
                model,
                animationName: nil,
                fit: .contain,
                alignment: .center,
                autoPlay: true,
                artboardName: artifact.manifest.entry.artboardName
            )

            let viewModelBridge = FlowViewModelBridge(
                model: model,
                remoteFlow: flow.remoteFlow,
                imageResolver: { [weak self] imageKey in
                    self?.resolveRiveImage(imageKey, artifact: artifact)
                },
                onValueChange: { [weak self] path, value, source in
                    guard let self else { return }
                    self.runtimeDelegate?.flowViewController(
                        self,
                        didEmitViewModelChange: FlowRendererViewModelChange(
                            path: path,
                            value: value,
                            source: source,
                            screenId: self.activeNativeScreenId,
                            instanceId: nil
                        )
                    )
                }
            )
            let didBindViewModel = try viewModelBridge.bindDefaultInstanceForActiveArtboard()

            let riveView = riveViewModel.createRiveView()
            riveView.stateMachineDelegate = self
            riveView.translatesAutoresizingMaskIntoConstraints = false
            riveView.accessibilityIdentifier = "nuxie-flow-surface"
            riveView.isAccessibilityElement = true
            riveView.isHidden = true

            view.insertSubview(riveView, at: 0)
            NSLayoutConstraint.activate([
                riveView.topAnchor.constraint(equalTo: view.topAnchor),
                riveView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                riveView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                riveView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])

            flowViewModelBridge = viewModelBridge
            if didBindViewModel {
                LogDebug("Bound native flow ViewModel \(viewModelBridge.boundViewModelName ?? "<unknown>")")
            } else {
                LogDebug("Mounted native flow artifact without a default ViewModel")
            }

            flowRiveViewModel = riveViewModel
            flowRiveView = riveView
            flowArtifact = artifact
            activeNativeScreenId = artifact.manifest.entry.screenId
            let textInputBridge = FlowTextInputOverlayBridge()
            textInputBridge.bind(
                screenId: artifact.manifest.entry.screenId,
                artifact: artifact,
                riveView: riveView,
                riveViewModel: riveViewModel
            )
            textInputOverlayBridge = textInputBridge
            handleNativeRuntimeReady()
            LogDebug("Mounted native flow artifact for flow \(flow.id)")
        } catch {
            flowArtifact = nil
            activeNativeScreenId = nil
            pendingNativeScreenBindingId = nil
            textInputOverlayBridge?.clear()
            textInputOverlayBridge = nil
            viewModel.handleLoadingFailed(error)
        }
        #else
        viewModel.handleLoadingFailed(FlowError.configurationFailed(FlowArtifactStoreError.downloadFailed("Rive runtime unavailable")))
        #endif
    }

    func handleNativeRuntimeReady() {
        runtimeReady = true
        viewModel.handleLoadingFinished()
        runtimeDelegate?.flowViewControllerDidBecomeReady(self)
        flushPendingNativeRuntimeCommands()
    }

    #if canImport(RiveRuntime) && canImport(UIKit)
    private func loadRiveAsset(
        _ asset: RiveFileAsset,
        embeddedData: Data,
        factory: RiveFactory,
        artifact: LoadedFlowArtifact
    ) -> Bool {
        let assetName = asset.uniqueName()
        guard let assetURL = artifact.localAssetURL(forRiveUniqueName: assetName) else {
            LogError("Missing prepared runtime asset for Rive asset \(assetName)")
            return false
        }

        let data: Data
        do {
            data = try Data(contentsOf: assetURL)
        } catch {
            LogError("Failed to read prepared runtime asset \(assetName) at \(assetURL.path): \(error)")
            return false
        }

        if let imageAsset = asset as? RiveImageAsset {
            imageAsset.renderImage(factory.decodeImage(data))
            LogDebug("Loaded Rive image asset \(assetName) from \(assetURL.path)")
            return true
        }

        if let fontAsset = asset as? RiveFontAsset {
            _ = FlowRuntimeFontRegistry.registerFont(riveUniqueName: assetName, data: data)
            fontAsset.font(factory.decodeFont(data))
            LogDebug("Loaded Rive font asset \(assetName) from \(assetURL.path)")
            return true
        }

        LogDebug("Unsupported Rive asset type for prepared asset \(assetName)")
        return false
    }

    private func resolveRiveImage(_ imageKey: String, artifact: LoadedFlowArtifact) -> RiveRenderImage? {
        guard let asset = artifact.manifest.assets.images.first(where: {
            $0.sourceAssetKey == imageKey || $0.riveUniqueName == imageKey || $0.path == imageKey
        }) else {
            return nil
        }
        guard let assetURL = try? artifact.localImageURL(for: asset),
              let data = try? Data(contentsOf: assetURL) else {
            return nil
        }
        return RiveRenderImage(data: data)
    }
    #endif

    private func setFlowContentHidden(_ hidden: Bool) {
        #if canImport(RiveRuntime) && canImport(UIKit)
        flowRiveView?.isHidden = hidden
        textInputOverlayBridge?.setHidden(hidden)
        #endif
    }

    // MARK: - UI State Management

    private func updateUIState(_ state: FlowViewModel.State) {
        switch state {
        case .loading:
            setFlowContentHidden(true)
            loadingView.isHidden = false
            errorView.isHidden = true
            platformStartLoadingIndicator()

        case .loaded:
            setFlowContentHidden(false)
            loadingView.isHidden = true
            errorView.isHidden = true
            platformStopLoadingIndicator()

        case .error:
            setFlowContentHidden(true)
            loadingView.isHidden = true
            errorView.isHidden = false
            platformStopLoadingIndicator()
        }
    }

    func retryFromErrorView() {
        viewModel.retry()
    }
}

private extension FlowViewController {
    enum NotificationAuthorizationOutcome {
        case enabled
        case denied
    }

    enum RequestPermissionKind: String {
        case camera
        case location
        case microphone
        case photos
    }

    enum RequestPermissionResolution {
        case status(PermissionAuthorizationStatus)
        case unsupportedType
    }

    enum TrackingAuthorizationOutcome {
        case authorized
        case denied
        case unsupported
    }

    func invokeOnCloseOnce(_ reason: CloseReason) {
        guard !didInvokeClose else { return }
        didInvokeClose = true
        onClose?(reason)
    }

    func resolveNotificationAuthorizationOutcome() async -> NotificationAuthorizationOutcome {
        let status = await notificationAuthorizationHandler.authorizationStatus()
        if isNotificationAuthorizationGranted(status) {
            return .enabled
        }
        if status == .denied {
            return .denied
        }

        do {
            let granted = try await notificationAuthorizationHandler.requestAuthorization(
                options: [.alert, .badge, .sound]
            )
            return granted ? .enabled : .denied
        } catch {
            LogWarning("FlowViewController: notification request failed: \(error)")
            return .denied
        }
    }

    func resolveTrackingAuthorizationOutcome(
        currentStatus: TrackingAuthorizationStatus? = nil
    ) async -> TrackingAuthorizationOutcome {
        switch currentStatus ?? trackingAuthorizationHandler.authorizationStatus() {
        case .authorized:
            return .authorized
        case .denied, .restricted:
            return .denied
        case .unsupported:
            return .unsupported
        case .notDetermined:
            guard let usageDescription = trackingUsageDescriptionProvider()?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !usageDescription.isEmpty
            else {
                LogWarning("FlowViewController: NSUserTrackingUsageDescription is missing; emitting tracking_denied")
                return .denied
            }

            switch await trackingAuthorizationHandler.requestAuthorization() {
            case .authorized:
                return .authorized
            case .denied, .restricted, .notDetermined:
                return .denied
            case .unsupported:
                return .unsupported
            }
        }
    }

    func resolveRequestPermissionOutcome(
        permissionType: String
    ) async -> RequestPermissionResolution {
        guard let permission = RequestPermissionKind(rawValue: permissionType) else {
            LogWarning("FlowViewController: Unsupported request permission type \(permissionType); skipping event")
            return .unsupportedType
        }

        let handler: PermissionAuthorizationHandling
        let usageDescriptionProvider: () -> String?
        let usageDescriptionKey: String

        switch permission {
        case .camera:
            handler = cameraPermissionAuthorizationHandler
            usageDescriptionProvider = cameraUsageDescriptionProvider
            usageDescriptionKey = "NSCameraUsageDescription"
        case .location:
            handler = locationPermissionAuthorizationHandler
            usageDescriptionProvider = locationUsageDescriptionProvider
            usageDescriptionKey = "NSLocationWhenInUseUsageDescription"
        case .microphone:
            handler = microphonePermissionAuthorizationHandler
            usageDescriptionProvider = microphoneUsageDescriptionProvider
            usageDescriptionKey = "NSMicrophoneUsageDescription"
        case .photos:
            handler = photoLibraryPermissionAuthorizationHandler
            usageDescriptionProvider = photoLibraryUsageDescriptionProvider
            usageDescriptionKey = "NSPhotoLibraryUsageDescription"
        }

        let currentStatus = handler.authorizationStatus()
        switch currentStatus {
        case .granted, .limited, .denied, .restricted, .unsupported:
            return .status(currentStatus)
        case .notDetermined:
            guard let usageDescription = usageDescriptionProvider()?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !usageDescription.isEmpty
            else {
                LogWarning("FlowViewController: \(usageDescriptionKey) is missing; emitting permission_denied")
                return .status(.denied)
            }
            return .status(await handler.requestAuthorization())
        }
    }

    func isNotificationAuthorizationGranted(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized:
            return true
        case .ephemeral, .provisional, .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    func journeyScopedEventProperties(
        journeyId: String?,
        extraProperties: [String: Any] = [:]
    ) -> [String: Any] {
        var properties = extraProperties
        if let journeyId, !journeyId.isEmpty {
            properties["journey_id"] = journeyId
        }
        return properties
    }

    func permissionEventProperties(
        journeyId: String?,
        permissionType: String
    ) -> [String: Any] {
        journeyScopedEventProperties(
            journeyId: journeyId,
            extraProperties: ["type": permissionType]
        )
    }

    func handleUnsupportedRequestPermission(
        permissionType: String,
        journeyId: String?
    ) {
        guard let journeyId, !journeyId.isEmpty,
              let receiver = requestPermissionEventReceiver
        else {
            return
        }

        receiver.flowViewController(
            self,
            didIgnoreUnsupportedRequestPermissionType: permissionType,
            journeyId: journeyId
        )
    }

    func dispatchNotificationPermissionEvent(
        _ eventName: String,
        properties: [String: Any],
        journeyId: String?
    ) {
        if let journeyId, !journeyId.isEmpty,
           let receiver = notificationPermissionEventReceiver {
            receiver.flowViewController(
                self,
                didResolveNotificationPermissionEvent: eventName,
                properties: properties,
                journeyId: journeyId
            )
            return
        }

        emitSystemEvent(eventName, properties: properties)
    }

    func dispatchTrackingPermissionEvent(
        _ eventName: String,
        properties: [String: Any],
        journeyId: String?
    ) {
        if let journeyId, !journeyId.isEmpty,
           let receiver = trackingPermissionEventReceiver {
            receiver.flowViewController(
                self,
                didResolveTrackingPermissionEvent: eventName,
                properties: properties,
                journeyId: journeyId
            )
            return
        }

        emitSystemEvent(eventName, properties: properties)
    }

    func dispatchRequestPermissionEvent(
        _ eventName: String,
        properties: [String: Any],
        journeyId: String?
    ) {
        if let journeyId, !journeyId.isEmpty,
           let receiver = requestPermissionEventReceiver {
            receiver.flowViewController(
                self,
                didResolveRequestPermissionEvent: eventName,
                properties: properties,
                journeyId: journeyId
            )
            return
        }

        emitSystemEvent(eventName, properties: properties)
    }

    func applyColorSchemeMode() {
        platformApplyColorSchemeMode(colorSchemeMode)
    }

    private func enqueueNativeRuntimeCommand(_ command: NativeRuntimeCommand) {
        guard runtimeReady else {
            pendingNativeRuntimeCommands.append(command)
            return
        }
        performNativeRuntimeCommand(command)
    }

    private func flushPendingNativeRuntimeCommands() {
        guard runtimeReady, !pendingNativeRuntimeCommands.isEmpty else { return }
        let commands = pendingNativeRuntimeCommands
        pendingNativeRuntimeCommands.removeAll()
        commands.forEach(performNativeRuntimeCommand)
    }

    private func performNativeRuntimeCommand(_ command: NativeRuntimeCommand) {
        #if canImport(RiveRuntime) && canImport(UIKit)
        switch command {
        case .viewModelSnapshot(let snapshot, let screenId):
            _ = flowViewModelBridge?.applySnapshot(snapshot, screenId: screenId)
            let didSatisfyPendingScreenBinding = screenId != nil && pendingNativeScreenBindingId == screenId
            if let screenId,
               flowViewModelBridge?.bindDefaultInstance(forScreenId: screenId) == true {
                pendingNativeScreenBindingId = nil
                if didSatisfyPendingScreenBinding {
                    flowRiveView?.advance(delta: 0)
                }
            }
            bindPendingNativeScreenIfNeeded()
        case .viewModelValue(let path, let value, let screenId, let instanceId):
            _ = flowViewModelBridge?.applyValue(
                path: path,
                value: value,
                screenId: screenId,
                instanceId: instanceId
            )
        case .viewModelList(let operation, let path, let payload, let screenId, let instanceId):
            _ = flowViewModelBridge?.applyListOperation(
                operation,
                path: path,
                payload: payload,
                screenId: screenId,
                instanceId: instanceId
            )
        case .viewModelTrigger(let path, let screenId, let instanceId):
            _ = flowViewModelBridge?.fireTrigger(
                path: path,
                screenId: screenId,
                instanceId: instanceId
            )
        case .navigate(let screenId, let transition):
            _ = handleNativeRuntimeNavigate(to: screenId, transition: transition)
        }
        #endif
    }

    #if canImport(RiveRuntime) && canImport(UIKit)
    @discardableResult
    private func handleNativeRuntimeNavigate(to screenId: String, transition: Any?) -> Bool {
        guard let artifact = flowArtifact,
              let screen = artifact.manifest.screens.first(where: { $0.screenId == screenId }),
              let riveViewModel = flowRiveViewModel else {
            return false
        }

        let transitionSpec = FlowScreenTransitionSpec(raw: transition)
        let previousSnapshot = makeNativeScreenTransitionSnapshot(for: transitionSpec)

        do {
            try riveViewModel.configureModel(
                artboardName: screen.artboardName,
                stateMachineName: nil,
                animationName: nil
            )
            if flowViewModelBridge?.bindDefaultInstance(forScreenId: screenId) == true {
                pendingNativeScreenBindingId = nil
            } else {
                pendingNativeScreenBindingId = screenId
            }
            activeNativeScreenId = screenId
            if let riveView = flowRiveView,
               let artifact = flowArtifact {
                textInputOverlayBridge?.bind(
                    screenId: screenId,
                    artifact: artifact,
                    riveView: riveView,
                    riveViewModel: riveViewModel
                )
            }
            flowRiveView?.advance(delta: 0)
            animateNativeScreenTransition(transitionSpec, previousSnapshot: previousSnapshot)
            runtimeDelegate?.flowViewController(self, didChangeScreen: screenId)
            return true
        } catch {
            previousSnapshot?.removeFromSuperview()
            LogWarning("FlowViewController: failed to navigate native artifact to screen \(screenId): \(error)")
            return false
        }
    }

    private func makeNativeScreenTransitionSnapshot(for spec: FlowScreenTransitionSpec) -> UIView? {
        guard spec.isAnimated,
              !UIAccessibility.isReduceMotionEnabled,
              let riveView = flowRiveView,
              !riveView.isHidden,
              let snapshot = riveView.snapshotView(afterScreenUpdates: false) else {
            return nil
        }

        snapshot.frame = riveView.frame
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        switch spec.kind {
        case .moveIn, .slideIn:
            view.insertSubview(snapshot, belowSubview: riveView)
        default:
            view.insertSubview(snapshot, aboveSubview: riveView)
        }

        return snapshot
    }

    private func animateNativeScreenTransition(
        _ spec: FlowScreenTransitionSpec,
        previousSnapshot: UIView?
    ) {
        guard let riveView = flowRiveView else {
            previousSnapshot?.removeFromSuperview()
            return
        }

        guard spec.isAnimated, !UIAccessibility.isReduceMotionEnabled else {
            riveView.transform = .identity
            riveView.alpha = 1
            previousSnapshot?.removeFromSuperview()
            return
        }

        let offset = nativeScreenTransitionOffset(spec.direction)
        let reverseOffset = nativeScreenTransitionOffset(spec.direction.reversed)

        switch spec.kind {
        case .instant:
            riveView.transform = .identity
            riveView.alpha = 1
            previousSnapshot?.removeFromSuperview()
            return
        case .dissolve:
            riveView.transform = .identity
            riveView.alpha = 0
            previousSnapshot?.transform = .identity
            previousSnapshot?.alpha = 1
        case .moveIn:
            riveView.transform = offset
            riveView.alpha = 1
            previousSnapshot?.transform = .identity
            previousSnapshot?.alpha = 1
        case .moveOut:
            riveView.transform = .identity
            riveView.alpha = 1
            previousSnapshot?.transform = .identity
            previousSnapshot?.alpha = 1
        case .push:
            riveView.transform = offset
            riveView.alpha = 1
            previousSnapshot?.transform = .identity
            previousSnapshot?.alpha = 1
        case .slideIn:
            riveView.transform = offset
            riveView.alpha = 0
            previousSnapshot?.transform = .identity
            previousSnapshot?.alpha = 1
        case .slideOut:
            riveView.transform = .identity
            riveView.alpha = 1
            previousSnapshot?.transform = .identity
            previousSnapshot?.alpha = 1
        }

        UIView.animate(
            withDuration: spec.duration,
            delay: 0,
            options: nativeScreenTransitionAnimationOptions(spec.easing)
        ) {
            riveView.transform = .identity
            riveView.alpha = 1

            switch spec.kind {
            case .instant:
                break
            case .dissolve:
                previousSnapshot?.alpha = 0
            case .moveIn, .slideIn:
                previousSnapshot?.alpha = 1
            case .moveOut, .slideOut:
                previousSnapshot?.transform = offset
                previousSnapshot?.alpha = spec.kind == .slideOut ? 0 : 1
            case .push:
                previousSnapshot?.transform = reverseOffset
            }
        } completion: { _ in
            riveView.transform = .identity
            riveView.alpha = 1
            previousSnapshot?.removeFromSuperview()
        }
    }

    private func nativeScreenTransitionOffset(_ direction: FlowScreenTransitionSpec.Direction) -> CGAffineTransform {
        let width = max(view.bounds.width, 1)
        let height = max(view.bounds.height, 1)
        switch direction {
        case .left:
            return CGAffineTransform(translationX: -width, y: 0)
        case .right:
            return CGAffineTransform(translationX: width, y: 0)
        case .up:
            return CGAffineTransform(translationX: 0, y: -height)
        case .down:
            return CGAffineTransform(translationX: 0, y: height)
        }
    }

    private func nativeScreenTransitionAnimationOptions(
        _ easing: FlowScreenTransitionSpec.Easing
    ) -> UIView.AnimationOptions {
        let curve: UIView.AnimationOptions
        switch easing {
        case .linear:
            curve = .curveLinear
        case .easeIn:
            curve = .curveEaseIn
        case .easeOut:
            curve = .curveEaseOut
        case .easeInOut:
            curve = .curveEaseInOut
        }
        return [.beginFromCurrentState, .allowUserInteraction, curve]
    }

    private func bindPendingNativeScreenIfNeeded() {
        guard let screenId = pendingNativeScreenBindingId,
              flowViewModelBridge?.bindDefaultInstance(forScreenId: screenId) == true else {
            return
        }
        pendingNativeScreenBindingId = nil
        flowRiveView?.advance(delta: 0)
    }
    #endif

}

#if canImport(RiveRuntime) && canImport(UIKit)
extension FlowViewController: RiveStateMachineDelegate {
    public func onRiveEventReceived(onRiveEvent riveEvent: RiveEvent) {
        let properties = rendererEventProperties(from: riveEvent)
        let screenId = rendererStringProperty(
            ["screenId", "screen_id"],
            from: properties
        ) ?? activeNativeScreenId
        let componentId = rendererStringProperty(
            ["componentId", "component_id", "elementId", "element_id"],
            from: properties
        )
        let instanceId = rendererStringProperty(
            ["instanceId", "instance_id"],
            from: properties
        )

        if let openUrlEvent = riveEvent as? RiveOpenUrlEvent {
            runtimeDelegate?.flowViewController(
                self,
                didRequestOpenLink: FlowRendererOpenLinkRequest(
                    urlString: openUrlEvent.url(),
                    target: openUrlEvent.target(),
                    screenId: screenId,
                    instanceId: instanceId
                )
            )
            return
        }

        if let rawTrigger = rendererStringProperty(
            ["nuxieTrigger", "trigger", "triggerType", "trigger_type"],
            from: properties
        ), let trigger = rendererInteractionTrigger(
            from: rawTrigger,
            properties: properties,
            eventName: riveEvent.name()
        ) {
            runtimeDelegate?.flowViewController(
                self,
                didEmitInteraction: FlowRendererInteraction(
                    trigger: trigger,
                    screenId: screenId,
                    componentId: componentId,
                    instanceId: instanceId,
                    properties: properties
                )
            )
            return
        }

        runtimeDelegate?.flowViewController(
            self,
            didEmitEvent: FlowRendererEvent(
                name: riveEvent.name(),
                properties: properties,
                screenId: screenId,
                componentId: componentId,
                instanceId: instanceId
            )
        )
    }

    private func rendererEventProperties(from event: RiveEvent) -> [String: Any] {
        guard let rawProperties = event.properties() as? [String: Any] else {
            return [:]
        }
        return rawProperties
    }

    private func rendererStringProperty(
        _ keys: [String],
        from properties: [String: Any]
    ) -> String? {
        for key in keys {
            if let value = properties[key] as? String,
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func rendererInteractionTrigger(
        from rawValue: String,
        properties: [String: Any],
        eventName: String
    ) -> InteractionTrigger? {
        let normalized = rawValue
            .replacingOccurrences(of: "action/", with: "")
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()

        switch normalized {
        case "long_press", "longpress":
            return .longPress(
                minMs: rendererIntProperty(["minMs", "min_ms"], from: properties)
            )
        case "hover":
            return .hover
        case "press":
            return .press
        case "drag":
            let direction = rendererStringProperty(["direction"], from: properties)
                .flatMap { InteractionTrigger.DragDirection(rawValue: $0) }
            return .drag(
                direction: direction,
                threshold: rendererDoubleProperty(["threshold"], from: properties)
            )
        case "manual":
            return .manual(
                label: rendererStringProperty(["label"], from: properties)
            )
        case "event":
            return .event(
                eventName: rendererStringProperty(
                    ["eventName", "event_name"],
                    from: properties
                ) ?? eventName,
                filter: nil
            )
        default:
            return nil
        }
    }

    private func rendererIntProperty(
        _ keys: [String],
        from properties: [String: Any]
    ) -> Int? {
        for key in keys {
            if let value = properties[key] as? Int { return value }
            if let value = properties[key] as? Double { return Int(value) }
            if let value = properties[key] as? NSNumber { return value.intValue }
            if let value = properties[key] as? String { return Int(value) }
        }
        return nil
    }

    private func rendererDoubleProperty(
        _ keys: [String],
        from properties: [String: Any]
    ) -> Double? {
        for key in keys {
            if let value = properties[key] as? Double { return value }
            if let value = properties[key] as? Int { return Double(value) }
            if let value = properties[key] as? NSNumber { return value.doubleValue }
            if let value = properties[key] as? String { return Double(value) }
        }
        return nil
    }
}
#endif

// MARK: - Native Host Action Helpers

extension FlowViewController {
    fileprivate func handleNativePurchase(productId: String) {
        LogDebug("FlowViewController: Native purchase for product: \(productId)")
        let transactionService = Container.shared.transactionService()
        let productService = Container.shared.productService()

        Task { @MainActor in
            do {
                let products = try await productService.fetchProducts(for: [productId])
                guard let product = products.first else {
                    self.emitSystemEvent(
                        SystemEventNames.purchaseFailed,
                        properties: [
                            "product_id": productId,
                            "error": "Product not found"
                        ]
                    )
                    return
                }
                let syncResult = try await transactionService.purchase(product)
                if let syncTask = syncResult.syncTask {
                    _ = await syncTask.value
                }
            } catch StoreKitError.purchaseCancelled {
                self.emitSystemEvent(
                    SystemEventNames.purchaseCancelled,
                    properties: ["product_id": productId]
                )
            } catch StoreKitError.purchasePending {
                LogInfo("FlowViewController: purchase pending for product \(productId)")
            } catch StoreKitError.purchaseFailed(_) {
                LogWarning("FlowViewController: purchase failed for product \(productId)")
            } catch {
                self.emitSystemEvent(
                    SystemEventNames.purchaseFailed,
                    properties: [
                        "product_id": productId,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    fileprivate func handleNativeRestore() {
        LogDebug("FlowViewController: Native restore purchases")
        let transactionService = Container.shared.transactionService()
        Task { @MainActor in
            do {
                try await transactionService.restore()
            } catch StoreKitError.restoreFailed(_) {
                LogWarning("FlowViewController: restore purchases failed")
            } catch {
                self.emitSystemEvent(
                    SystemEventNames.restoreFailed,
                    properties: ["error": error.localizedDescription]
                )
            }
        }
    }
}
