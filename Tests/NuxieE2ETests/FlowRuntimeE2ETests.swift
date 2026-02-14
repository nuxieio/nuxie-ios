import Foundation
import Quick
import Nimble
import UIKit
import WebKit
import FactoryKit
@testable import Nuxie

final class FlowRuntimeE2ESpec: QuickSpec {
    override class func spec() {
        describe("Flow Runtime E2E") {
            var server: LocalHTTPServer?

            var apiKey: String = "pk_test_e2e_local"
            var baseURL: URL = URL(string: "http://127.0.0.1:8084")!
            var flowId: String = "flow_e2e_ready"

            var flowViewController: FlowViewController?
            var runtimeDelegate: FlowRuntimeDelegate?
	            var window: UIWindow?
	            var requestLog: LockedArray<String>?
	            var batchBodies: LockedArray<Data>?
	            var eventBodies: LockedArray<Data>?
	            var experimentAbCompiledBundleFixture: ExperimentAbCompiledBundleFixture?

            func makeCampaign(flowId: String) -> Campaign {
                let publishedAt = ISO8601DateFormatter().string(from: Date())
                return Campaign(
                    id: "camp-e2e-1",
                    name: "E2E Campaign",
                    flowId: flowId,
                    flowNumber: 1,
                    flowName: nil,
                    reentry: .oneTime,
                    publishedAt: publishedAt,
                    trigger: .event(EventTriggerConfig(eventName: "test_event", condition: nil)),
                    goal: nil,
                    exitPolicy: nil,
                    conversionAnchor: nil,
                    campaignType: nil
                )
            }

            final class TraceRecordingMockEventService: MockEventService {
                private let traceRecorder: FlowRuntimeTraceRecorder

                init(traceRecorder: FlowRuntimeTraceRecorder) {
                    self.traceRecorder = traceRecorder
                    super.init()
                }

                override func track(
                    _ event: String,
                    properties: [String: Any]? = nil,
                    userProperties: [String: Any]? = nil,
                    userPropertiesSetOnce: [String: Any]? = nil
                ) {
                    traceRecorder.recordEvent(name: event, properties: properties)
                    super.track(
                        event,
                        properties: properties,
                        userProperties: userProperties,
                        userPropertiesSetOnce: userPropertiesSetOnce
                    )
                }
            }

            beforeEach {
                flowViewController = nil
                runtimeDelegate = nil
	                window = nil
	                requestLog = LockedArray<String>()
	                batchBodies = LockedArray<Data>()
	                eventBodies = LockedArray<Data>()
	                if experimentAbCompiledBundleFixture == nil {
	                    experimentAbCompiledBundleFixture = loadExperimentAbCompiledBundleFixture()
	                }

                let env = ProcessInfo.processInfo.environment
                let envApiKey = env["NUXIE_E2E_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let envIngestUrl = env["NUXIE_E2E_INGEST_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let envFlowId = env["NUXIE_E2E_FLOW_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)

                let hasEnvConfig = (envApiKey?.isEmpty == false)
                    && (envIngestUrl?.isEmpty == false)
                    && (envFlowId?.isEmpty == false)

                if hasEnvConfig, let ingestUrl = URL(string: envIngestUrl!) {
                    apiKey = envApiKey!
                    baseURL = ingestUrl
                    flowId = envFlowId!
                    server = nil
                    return
                }

                if server == nil {
                    server = try? LocalHTTPServer { request in
                        requestLog?.append("\(request.method) \(request.path)")
	                        if request.method == "POST", request.path.hasSuffix("/batch") {
	                            batchBodies?.append(request.body)

	                            // Best-effort count for nicer logs/debugging.
	                            let decoded = decodeMaybeGzippedJSON(request.body)
                            let batchCount = ((decoded as? [String: Any])?["batch"] as? [Any])?.count ?? 0
                            let response = BatchResponse(
                                status: "ok",
                                processed: batchCount,
                                failed: 0,
                                total: batchCount,
                                errors: nil
                            )
	                            let json = (try? JSONEncoder().encode(response))
	                                ?? Data("{\"status\":\"ok\",\"processed\":0,\"failed\":0,\"total\":0}".utf8)
	                            return LocalHTTPServer.Response.json(json)
	                        }
	                        if request.method == "POST", request.path == "/event" {
	                            eventBodies?.append(request.body)

	                            var execution: EventResponse.ExecutionResult?
	                            if
	                                let root = decodeMaybeGzippedJSON(request.body) as? [String: Any],
	                                let eventName = root["event"] as? String,
	                                eventName == "$journey_node_executed"
	                            {
	                                var updates: [String: AnyCodable]?
	                                if
	                                    let props = root["properties"] as? [String: Any],
	                                    let nodeData = props["node_data"] as? [String: Any],
	                                    let nodePayload = nodeData["data"] as? [String: Any],
	                                    let action = nodePayload["action"] as? String,
	                                    action == "set_context"
	                                {
	                                    updates = ["remote_key": AnyCodable("remote_value")]
	                                }
	                                execution = EventResponse.ExecutionResult(
	                                    success: true,
	                                    statusCode: 200,
	                                    error: nil,
	                                    contextUpdates: updates
	                                )
	                            }

	                            let response = EventResponse(
	                                status: "ok",
	                                payload: nil,
	                                customer: nil,
	                                event: EventResponse.EventInfo(id: "evt-1", processed: true),
	                                message: nil,
	                                featuresMatched: nil,
	                                usage: nil,
	                                journey: nil,
	                                execution: execution
	                            )
	                            let json = (try? JSONEncoder().encode(response)) ?? Data("{\"status\":\"ok\"}".utf8)
	                            return LocalHTTPServer.Response.json(json)
	                        }
	                        if request.method == "POST", request.path == "/purchase" {
	                            let response = PurchaseResponse(
	                                success: true,
	                                customerId: "cust-1",
	                                features: nil,
	                                error: nil
	                            )
	                            let json = (try? JSONEncoder().encode(response)) ?? Data("{\"success\":true}".utf8)
	                            return LocalHTTPServer.Response.json(json)
	                        }
	                        if (request.method == "POST" || request.method == "GET"), request.path == "/profile" {
	                            var requestedDistinctId: String? = request.query["distinct_id"]
	                            if requestedDistinctId == nil, !request.body.isEmpty {
	                                if let profileRequest = try? JSONDecoder().decode(ProfileRequest.self, from: request.body) {
	                                    requestedDistinctId = profileRequest.distinctId
                                }
                            }

                            let distinctId = requestedDistinctId ?? "unknown"
                            let variantKey = distinctId.hasSuffix("-b") ? "b" : "a"
                            let assignment = ExperimentAssignment(
                                experimentKey: "exp-1",
                                variantKey: variantKey,
                                status: "running",
                                isHoldout: false
                            )
                            let response = ProfileResponse(
                                campaigns: [],
                                segments: [],
                                flows: [],
                                userProperties: nil,
                                experiments: ["exp-1": assignment],
                                features: nil,
                                journeys: nil
                            )
                            let json = (try? JSONEncoder().encode(response)) ?? Data("{}".utf8)
                            return LocalHTTPServer.Response.json(json)
                        }
				                        if request.method == "GET", request.path.hasPrefix("/flows/") {
				                            let reqFlowId = request.path.replacingOccurrences(of: "/flows/", with: "")
				                            let isExperimentAbFlow = reqFlowId.hasPrefix("flow_e2e_experiment_ab_")
				                            let isCompiledViewModelFlow = reqFlowId.hasPrefix("flow_e2e_compiled_view_model_")
				                            let isDidSetFlow = reqFlowId.hasPrefix("flow_e2e_did_set_")
				                            let isParityTraceFlow = reqFlowId.hasPrefix("flow_e2e_parity_trace_")
				                            let isRemoteActionFlow = reqFlowId.hasPrefix("flow_e2e_remote_action_")
				                            let isCallDelegateFlow = reqFlowId.hasPrefix("flow_e2e_call_delegate_")
				                            let isOpenLinkFlow = reqFlowId.hasPrefix("flow_e2e_open_link_")
				                            let isPurchaseFlow = reqFlowId.hasPrefix("flow_e2e_purchase_")
				                            let isRestoreFlow = reqFlowId.hasPrefix("flow_e2e_restore_")
				                            let isNavStackFlow = reqFlowId.hasPrefix("flow_e2e_nav_stack_")
				                            let isLongPressFlow = reqFlowId.hasPrefix("flow_e2e_long_press_")
				                            let isDragFlow = reqFlowId.hasPrefix("flow_e2e_drag_")
				                            let isCustomerUpdateEventFlow = reqFlowId.hasPrefix("flow_e2e_customer_update_event_")
				                            let isListOpsFlow = reqFlowId.hasPrefix("flow_e2e_list_ops_")
				                            let isMissingAssetFlow = reqFlowId.hasPrefix("flow_e2e_missing_asset_")
				                            let isCompiledBundleFlow = isExperimentAbFlow
				                                || isCompiledViewModelFlow
				                                || isDidSetFlow
				                                || isParityTraceFlow
				                                || isRemoteActionFlow
				                                || isCallDelegateFlow
				                                || isOpenLinkFlow
				                                || isPurchaseFlow
				                                || isRestoreFlow
				                                || isNavStackFlow
				                                || isLongPressFlow
				                                || isDragFlow
				                                || isCustomerUpdateEventFlow
				                                || isListOpsFlow
				                            let host = request.headers["host"] ?? "127.0.0.1"
				                        // Serve a per-flow bundle root to avoid cache collisions and to more closely
				                        // match real bundle shapes (base URL + manifest-relative paths).
				                        let bundleBaseUrl = "http://\(host)/bundles/\(reqFlowId)/"

	                        let manifest: BuildManifest
		                        if isCompiledBundleFlow {
		                            guard let fixture = experimentAbCompiledBundleFixture else {
		                                return LocalHTTPServer.Response.text(
		                                    "Missing compiled bundle fixture",
		                                    statusCode: 500
		                                )
		                            }
			                            let contentHashPrefix: String
				                            if isExperimentAbFlow {
				                                contentHashPrefix = "e2e-experiment-ab-compiled"
				                            } else if isCompiledViewModelFlow {
				                                contentHashPrefix = "e2e-compiled-view-model-compiled"
				                            } else if isDidSetFlow {
				                                contentHashPrefix = "e2e-did-set-compiled"
					                            } else if isParityTraceFlow {
					                                contentHashPrefix = "e2e-parity-trace-compiled"
					                            } else if isRemoteActionFlow {
					                                contentHashPrefix = "e2e-remote-action-compiled"
					                            } else if isCallDelegateFlow {
					                                contentHashPrefix = "e2e-call-delegate-compiled"
					                            } else if isOpenLinkFlow {
					                                contentHashPrefix = "e2e-open-link-compiled"
					                            } else if isPurchaseFlow {
					                                contentHashPrefix = "e2e-purchase-compiled"
					                            } else if isRestoreFlow {
					                                contentHashPrefix = "e2e-restore-compiled"
					                            } else if isNavStackFlow {
			                                contentHashPrefix = "e2e-nav-stack-compiled"
			                            } else if isLongPressFlow {
			                                contentHashPrefix = "e2e-long-press-compiled"
			                            } else if isDragFlow {
			                                contentHashPrefix = "e2e-drag-compiled"
			                            } else if isCustomerUpdateEventFlow {
			                                contentHashPrefix = "e2e-customer-update-event-compiled"
			                            } else if isListOpsFlow {
			                                contentHashPrefix = "e2e-list-ops-compiled"
			                            } else {
			                                contentHashPrefix = "e2e-compiled"
			                            }
			                            manifest = BuildManifest(
			                                totalFiles: fixture.buildFiles.count,
			                                totalSize: fixture.totalSize,
			                                contentHash: "\(contentHashPrefix)-\(reqFlowId)",
	                                files: fixture.buildFiles
	                            )
	                        } else {
	                            if isMissingAssetFlow {
	                                manifest = BuildManifest(
                                    totalFiles: 2,
                                    totalSize: 0,
                                    contentHash: "e2e-missing-asset-\(reqFlowId)",
                                    files: [
                                        BuildFile(path: "index.html", size: 0, contentType: "text/html"),
                                        BuildFile(path: "missing.js", size: 0, contentType: "text/javascript")
                                    ]
                                )
                            } else {
                            manifest = BuildManifest(
                                totalFiles: 1,
                                totalSize: 0,
                                contentHash: "e2e-ready-\(reqFlowId)",
                                files: [
                                    BuildFile(path: "index.html", size: 0, contentType: "text/html")
                                ]
                            )
                            }
                        }

                        let remoteFlow: RemoteFlow
                        if isExperimentAbFlow {
                            let variantA = ExperimentVariant(
                                id: "a",
                                name: "A",
                                percentage: 50,
                                actions: [
                                    .navigate(NavigateAction(screenId: "screen-a"))
                                ]
                            )
                            let variantB = ExperimentVariant(
                                id: "b",
                                name: "B",
                                percentage: 50,
                                actions: [
                                    .navigate(NavigateAction(screenId: "screen-b"))
                                ]
                            )
                            let experiment = ExperimentAction(
                                experimentId: "exp-1",
                                variants: [variantA, variantB]
                            )

                            remoteFlow = RemoteFlow(
                                id: reqFlowId,
                                bundle: FlowBundleRef(url: bundleBaseUrl, manifest: manifest),
                                screens: [
                                    RemoteFlowScreen(
                                        id: "screen-entry",
                                        defaultViewModelId: nil,
                                        defaultInstanceId: nil
                                    ),
                                    RemoteFlowScreen(
                                        id: "screen-a",
                                        defaultViewModelId: nil,
                                        defaultInstanceId: nil
                                    ),
                                    RemoteFlowScreen(
                                        id: "screen-b",
                                        defaultViewModelId: nil,
                                        defaultInstanceId: nil
                                    )
	                                ],
	                                interactions: [
	                                    "tap": [
	                                        Interaction(
	                                            id: "int-press",
	                                            trigger: .press,
	                                            actions: [
	                                                .experiment(experiment)
	                                            ],
	                                            enabled: true
	                                        )
                                    ]
                                ],
		                                viewModels: [],
		                                viewModelInstances: nil,
		                                converters: nil
		                            )
		                        } else if isCompiledViewModelFlow {
		                            remoteFlow = RemoteFlow(
		                                id: reqFlowId,
		                                bundle: FlowBundleRef(url: bundleBaseUrl, manifest: manifest),
		                                screens: [
		                                    RemoteFlowScreen(
		                                        id: "screen-entry",
		                                        defaultViewModelId: "vm-1",
		                                        defaultInstanceId: nil
		                                    )
		                                ],
		                                interactions: [
		                                    "tap": [
		                                        Interaction(
		                                            id: "int-tap",
		                                            trigger: .press,
		                                            actions: [
		                                                .setViewModel(
		                                                    SetViewModelAction(
		                                                        path: .ids(VmPathIds(pathIds: [0, 1])),
		                                                        value: AnyCodable(["literal": "world"] as [String: Any])
		                                                    )
		                                                )
		                                            ],
		                                            enabled: true
		                                        )
		                                    ]
		                                ],
		                                viewModels: [
		                                    ViewModel(
		                                        id: "vm-1",
		                                        name: "VM",
		                                        viewModelPathId: 0,
		                                        properties: [
		                                            "title": ViewModelProperty(
		                                                type: .string,
		                                                propertyId: 1,
		                                                defaultValue: AnyCodable("hello"),
		                                                required: nil,
		                                                enumValues: nil,
		                                                itemType: nil,
		                                                schema: nil,
		                                                viewModelId: nil,
		                                                validation: nil
		                                            )
		                                        ]
		                                    )
		                                ],
			                                viewModelInstances: nil,
			                                converters: nil
			                            )
			                        } else if isDidSetFlow {
			                            remoteFlow = RemoteFlow(
			                                id: reqFlowId,
			                                bundle: FlowBundleRef(url: bundleBaseUrl, manifest: manifest),
			                                screens: [
			                                    RemoteFlowScreen(
			                                        id: "screen-entry",
			                                        defaultViewModelId: "vm-1",
			                                        defaultInstanceId: nil
			                                    )
			                                ],
			                                interactions: [
			                                    "tap": [
			                                        Interaction(
			                                            id: "int-press",
			                                            trigger: .press,
			                                            actions: [
			                                                .setViewModel(
			                                                    SetViewModelAction(
			                                                        path: .ids(VmPathIds(pathIds: [0, 1])),
			                                                        value: AnyCodable(["literal": "world"] as [String: Any])
			                                                    )
			                                                )
			                                            ],
			                                            enabled: true
			                                        )
			                                    ],
			                                    "screen-entry": [
			                                        Interaction(
			                                            id: "int-title-did-set",
			                                            trigger: .didSet(path: .ids(VmPathIds(pathIds: [0, 1])), debounceMs: nil),
			                                            actions: [
			                                                .setViewModel(
			                                                    SetViewModelAction(
			                                                        path: .ids(VmPathIds(pathIds: [0, 2])),
			                                                        value: AnyCodable(["literal": "ack"] as [String: Any])
			                                                    )
			                                                )
			                                            ],
			                                            enabled: true
			                                        )
			                                    ]
			                                ],
			                                viewModels: [
			                                    ViewModel(
			                                        id: "vm-1",
			                                        name: "VM",
			                                        viewModelPathId: 0,
			                                        properties: [
			                                            "title": ViewModelProperty(
			                                                type: .string,
			                                                propertyId: 1,
			                                                defaultValue: AnyCodable("hello"),
			                                                required: nil,
			                                                enumValues: nil,
			                                                itemType: nil,
			                                                schema: nil,
			                                                viewModelId: nil,
			                                                validation: nil
			                                            ),
			                                            "didSetAck": ViewModelProperty(
			                                                type: .string,
			                                                propertyId: 2,
			                                                defaultValue: AnyCodable(""),
			                                                required: nil,
			                                                enumValues: nil,
			                                                itemType: nil,
			                                                schema: nil,
			                                                viewModelId: nil,
			                                                validation: nil
			                                            )
			                                        ]
			                                    )
			                                ],
			                                viewModelInstances: nil,
			                                converters: nil
			                            )
		                        } else if isParityTraceFlow {
		                            remoteFlow = RemoteFlow(
		                                id: reqFlowId,
		                                bundle: FlowBundleRef(url: bundleBaseUrl, manifest: manifest),
		                                targets: [
		                                    RemoteFlowTarget(
		                                        compilerBackend: "react",
		                                        buildId: "build-react-\(reqFlowId)",
		                                        bundle: FlowBundleRef(
		                                            url: bundleBaseUrl,
		                                            manifest: manifest
		                                        ),
		                                        status: "succeeded",
		                                        requiredCapabilities: ["renderer.react.webview.v1"],
		                                        recommendedSelectionOrder: nil
		                                    ),
		                                    RemoteFlowTarget(
		                                        compilerBackend: "rive",
		                                        buildId: "build-rive-\(reqFlowId)",
		                                        bundle: FlowBundleRef(
		                                            url: bundleBaseUrl,
		                                            manifest: manifest
		                                        ),
		                                        status: "succeeded",
		                                        requiredCapabilities: ["renderer.rive.native.v1"],
		                                        recommendedSelectionOrder: nil
		                                    ),
		                                ],
		                                screens: [
		                                    RemoteFlowScreen(
		                                        id: "screen-entry",
			                                        defaultViewModelId: "vm-1",
			                                        defaultInstanceId: nil
			                                    ),
			                                    RemoteFlowScreen(
			                                        id: "screen-2",
			                                        defaultViewModelId: nil,
			                                        defaultInstanceId: nil
			                                    )
			                                ],
			                                interactions: [
			                                    "to-2": [
			                                        Interaction(
			                                            id: "int-to-2",
			                                            trigger: .press,
			                                            actions: [
			                                                .navigate(NavigateAction(screenId: "screen-2"))
			                                            ],
			                                            enabled: true
			                                        )
			                                    ],
			                                    "screen-entry": [
			                                        Interaction(
			                                            id: "int-title-did-set",
			                                            trigger: .didSet(path: .ids(VmPathIds(pathIds: [0, 1])), debounceMs: nil),
			                                            actions: [
			                                                .setViewModel(
			                                                    SetViewModelAction(
			                                                        path: .ids(VmPathIds(pathIds: [0, 2])),
			                                                        value: AnyCodable(["literal": "ack"] as [String: Any])
			                                                    )
			                                                )
			                                            ],
			                                            enabled: true
			                                        )
			                                    ]
			                                ],
			                                viewModels: [
			                                    ViewModel(
			                                        id: "vm-1",
			                                        name: "VM",
			                                        viewModelPathId: 0,
			                                        properties: [
			                                            "title": ViewModelProperty(
			                                                type: .string,
			                                                propertyId: 1,
			                                                defaultValue: AnyCodable("hello"),
			                                                required: nil,
			                                                enumValues: nil,
			                                                itemType: nil,
			                                                schema: nil,
			                                                viewModelId: nil,
			                                                validation: nil
			                                            ),
			                                            "didSetAck": ViewModelProperty(
			                                                type: .string,
			                                                propertyId: 2,
			                                                defaultValue: AnyCodable(""),
			                                                required: nil,
			                                                enumValues: nil,
			                                                itemType: nil,
			                                                schema: nil,
			                                                viewModelId: nil,
			                                                validation: nil
			                                            )
			                                        ]
			                                    )
			                                ],
			                                viewModelInstances: nil,
			                                converters: nil
			                            )
			                        } else if isRemoteActionFlow {
				                            remoteFlow = RemoteFlow(
				                                id: reqFlowId,
				                                bundle: FlowBundleRef(url: bundleBaseUrl, manifest: manifest),
				                                screens: [
				                                    RemoteFlowScreen(
			                                        id: "screen-entry",
			                                        defaultViewModelId: nil,
			                                        defaultInstanceId: nil
			                                    )
				                                ],
				                                interactions: [
				                                    "tap": [
				                                        Interaction(
				                                            id: "int-press",
				                                            trigger: .press,
				                                            actions: [
				                                                .remote(
				                                                    RemoteAction(
				                                                        action: "set_context",
			                                                        payload: AnyCodable(["value": "hello"] as [String: Any])
			                                                    )
			                                                ),
			                                                .remote(
			                                                    RemoteAction(
			                                                        action: "read_context",
			                                                        payload: AnyCodable(["value": "world"] as [String: Any])
			                                                    )
			                                                )
			                                            ],
			                                            enabled: true
			                                        )
			                                    ]
			                                ],
				                                viewModels: [],
				                                viewModelInstances: nil,
				                                converters: nil
				                            )
				                        } else if isCallDelegateFlow {
				                            remoteFlow = RemoteFlow(
				                                id: reqFlowId,
				                                bundle: FlowBundleRef(url: bundleBaseUrl, manifest: manifest),
				                                screens: [
				                                    RemoteFlowScreen(
				                                        id: "screen-entry",
				                                        defaultViewModelId: nil,
				                                        defaultInstanceId: nil
				                                    )
				                                ],
				                                interactions: [
				                                    "tap": [
				                                        Interaction(
				                                            id: "int-press",
				                                            trigger: .press,
				                                            actions: [
				                                                .callDelegate(
				                                                    CallDelegateAction(
				                                                        message: "e2e_delegate",
				                                                        payload: AnyCodable(["k": "v"] as [String: Any])
				                                                    )
				                                                )
				                                            ],
				                                            enabled: true
				                                        )
				                                    ]
				                                ],
				                                viewModels: [],
				                                viewModelInstances: nil,
				                                converters: nil
				                            )
				                        } else if isOpenLinkFlow {
				                            remoteFlow = RemoteFlow(
				                                id: reqFlowId,
				                                bundle: FlowBundleRef(url: bundleBaseUrl, manifest: manifest),
				                                screens: [
				                                    RemoteFlowScreen(
				                                        id: "screen-entry",
				                                        defaultViewModelId: nil,
				                                        defaultInstanceId: nil
				                                    )
				                                ],
				                                interactions: [
				                                    "tap": [
				                                        Interaction(
				                                            id: "int-tap",
				                                            trigger: .press,
				                                            actions: [
				                                                .openLink(
				                                                    OpenLinkAction(
				                                                        url: AnyCodable("https://example.com"),
				                                                        target: "external"
				                                                    )
				                                                )
				                                            ],
				                                            enabled: true
				                                        )
				                                    ]
				                                ],
				                                viewModels: [],
				                                viewModelInstances: nil,
				                                converters: nil
				                            )
				                        } else if isPurchaseFlow {
			                            remoteFlow = RemoteFlow(
			                                id: reqFlowId,
			                                bundle: FlowBundleRef(url: bundleBaseUrl, manifest: manifest),
			                                screens: [
	                                    RemoteFlowScreen(
	                                        id: "screen-entry",
	                                        defaultViewModelId: nil,
	                                        defaultInstanceId: nil
	                                    )
	                                ],
	                                interactions: [
	                                    "tap": [
	                                        Interaction(
	                                            id: "int-tap",
	                                            trigger: .press,
	                                            actions: [
	                                                .purchase(
	                                                    PurchaseAction(
	                                                        placementIndex: AnyCodable(0),
	                                                        productId: AnyCodable("pro")
	                                                    )
	                                                )
	                                            ],
	                                            enabled: true
	                                        )
	                                    ]
	                                ],
		                                viewModels: [],
		                                viewModelInstances: nil,
			                                converters: nil
			                            )
			                        } else if isRestoreFlow {
			                            remoteFlow = RemoteFlow(
			                                id: reqFlowId,
			                                bundle: FlowBundleRef(url: bundleBaseUrl, manifest: manifest),
		                                screens: [
		                                    RemoteFlowScreen(
		                                        id: "screen-entry",
		                                        defaultViewModelId: nil,
		                                        defaultInstanceId: nil
		                                    )
		                                ],
		                                interactions: [
		                                    "tap": [
		                                        Interaction(
		                                            id: "int-tap",
		                                            trigger: .press,
		                                            actions: [
		                                                .restore(RestoreAction())
		                                            ],
		                                            enabled: true
		                                        )
		                                    ]
		                                ],
		                                viewModels: [],
		                                viewModelInstances: nil,
			                                converters: nil
			                            )
			                        } else if isNavStackFlow {
			                            remoteFlow = RemoteFlow(
			                                id: reqFlowId,
			                                bundle: FlowBundleRef(url: bundleBaseUrl, manifest: manifest),
			                                screens: [
			                                    RemoteFlowScreen(
			                                        id: "screen-entry",
			                                        defaultViewModelId: nil,
			                                        defaultInstanceId: nil
			                                    ),
			                                    RemoteFlowScreen(
			                                        id: "screen-2",
			                                        defaultViewModelId: nil,
			                                        defaultInstanceId: nil
			                                    )
			                                ],
			                                interactions: [
			                                    "to-2": [
			                                        Interaction(
			                                            id: "int-to-2",
			                                            trigger: .press,
			                                            actions: [
			                                                .navigate(NavigateAction(screenId: "screen-2"))
			                                            ],
			                                            enabled: true
			                                        )
			                                    ],
			                                    "back": [
			                                        Interaction(
			                                            id: "int-back",
			                                            trigger: .press,
			                                            actions: [
			                                                .back(BackAction(steps: 1))
			                                            ],
			                                            enabled: true
			                                        )
			                                    ]
			                                ],
			                                viewModels: [],
			                                viewModelInstances: nil,
			                                converters: nil
			                            )
			                        } else if isLongPressFlow {
			                            remoteFlow = RemoteFlow(
			                                id: reqFlowId,
			                                bundle: FlowBundleRef(url: bundleBaseUrl, manifest: manifest),
			                                screens: [
			                                    RemoteFlowScreen(
			                                        id: "screen-entry",
			                                        defaultViewModelId: nil,
			                                        defaultInstanceId: nil
			                                    ),
			                                    RemoteFlowScreen(
			                                        id: "screen-a",
			                                        defaultViewModelId: nil,
			                                        defaultInstanceId: nil
			                                    )
			                                ],
			                                interactions: [
			                                    "tap": [
			                                        Interaction(
			                                            id: "int-long-press",
			                                            trigger: .longPress(minMs: nil),
			                                            actions: [
			                                                .navigate(NavigateAction(screenId: "screen-a"))
			                                            ],
			                                            enabled: true
			                                        )
			                                    ]
			                                ],
			                                viewModels: [],
			                                viewModelInstances: nil,
			                                converters: nil
			                            )
			                        } else if isDragFlow {
			                            remoteFlow = RemoteFlow(
			                                id: reqFlowId,
			                                bundle: FlowBundleRef(url: bundleBaseUrl, manifest: manifest),
			                                screens: [
			                                    RemoteFlowScreen(
			                                        id: "screen-entry",
			                                        defaultViewModelId: nil,
			                                        defaultInstanceId: nil
			                                    ),
			                                    RemoteFlowScreen(
			                                        id: "screen-b",
			                                        defaultViewModelId: nil,
			                                        defaultInstanceId: nil
			                                    )
			                                ],
			                                interactions: [
			                                    "tap": [
			                                        Interaction(
			                                            id: "int-drag",
			                                            trigger: .drag(direction: nil, threshold: nil),
			                                            actions: [
			                                                .navigate(NavigateAction(screenId: "screen-b"))
			                                            ],
			                                            enabled: true
			                                        )
			                                    ]
			                                ],
			                                viewModels: [],
			                                viewModelInstances: nil,
			                                converters: nil
			                            )
			                        } else if isCustomerUpdateEventFlow {
			                            remoteFlow = RemoteFlow(
			                                id: reqFlowId,
			                                bundle: FlowBundleRef(url: bundleBaseUrl, manifest: manifest),
			                                screens: [
			                                    RemoteFlowScreen(
			                                        id: "screen-entry",
			                                        defaultViewModelId: nil,
			                                        defaultInstanceId: nil
			                                    )
			                                ],
			                                interactions: [
			                                    "tap": [
			                                        Interaction(
			                                            id: "int-tap",
			                                            trigger: .press,
			                                            actions: [
			                                                .updateCustomer(
			                                                    UpdateCustomerAction(
			                                                        attributes: ["plan": AnyCodable("pro")]
			                                                    )
			                                                ),
			                                                .sendEvent(
			                                                    SendEventAction(
			                                                        eventName: "custom_event",
			                                                        properties: ["k": AnyCodable("v")]
			                                                    )
			                                                )
			                                            ],
			                                            enabled: true
			                                        )
			                                    ]
			                                ],
			                                viewModels: [],
			                                viewModelInstances: nil,
			                                converters: nil
			                            )
			                        } else if isListOpsFlow {
			                            let itemOne: [String: Any] = [
			                                "viewModelId": "vm-item",
			                                "instanceId": "item-1",
			                                "values": ["label": "one"]
			                            ]
			                            let itemTwo: [String: Any] = [
			                                "viewModelId": "vm-item",
			                                "instanceId": "item-2",
			                                "values": ["label": "two"]
			                            ]
			                            let itemThree: [String: Any] = [
			                                "viewModelId": "vm-item",
			                                "instanceId": "item-3",
			                                "values": ["label": "three"]
			                            ]

			                            let listPath = VmPathRef.ids(VmPathIds(pathIds: [0, 3]))
			                            remoteFlow = RemoteFlow(
			                                id: reqFlowId,
			                                bundle: FlowBundleRef(url: bundleBaseUrl, manifest: manifest),
			                                screens: [
			                                    RemoteFlowScreen(
			                                        id: "screen-entry",
			                                        defaultViewModelId: "vm-1",
			                                        defaultInstanceId: nil
			                                    )
			                                ],
			                                interactions: [
			                                    "list-insert": [
			                                        Interaction(
			                                            id: "int-list-insert",
			                                            trigger: .press,
			                                            actions: [
			                                                .listInsert(
			                                                    ListInsertAction(
			                                                        path: listPath,
			                                                        index: 1,
			                                                        value: AnyCodable(
			                                                            ["literal": itemThree] as [String: Any]
			                                                        )
			                                                    )
			                                                )
			                                            ],
			                                            enabled: true
			                                        )
			                                    ],
			                                    "list-move": [
			                                        Interaction(
			                                            id: "int-list-move",
			                                            trigger: .press,
			                                            actions: [
			                                                .listMove(
			                                                    ListMoveAction(
			                                                        path: listPath,
			                                                        from: 2,
			                                                        to: 0
			                                                    )
			                                                )
			                                            ],
			                                            enabled: true
			                                        )
			                                    ],
			                                    "list-remove": [
			                                        Interaction(
			                                            id: "int-list-remove",
			                                            trigger: .press,
			                                            actions: [
			                                                .listRemove(
			                                                    ListRemoveAction(
			                                                        path: listPath,
			                                                        index: 1
			                                                    )
			                                                )
			                                            ],
			                                            enabled: true
			                                        )
			                                    ]
			                                ],
			                                viewModels: [
			                                    ViewModel(
			                                        id: "vm-1",
			                                        name: "VM",
			                                        viewModelPathId: 0,
			                                        properties: [
			                                            "title": ViewModelProperty(
			                                                type: .string,
			                                                propertyId: 1,
			                                                defaultValue: AnyCodable("hello"),
			                                                required: nil,
			                                                enumValues: nil,
			                                                itemType: nil,
			                                                schema: nil,
			                                                viewModelId: nil,
			                                                validation: nil
			                                            ),
			                                            "didSetAck": ViewModelProperty(
			                                                type: .string,
			                                                propertyId: 2,
			                                                defaultValue: AnyCodable(""),
			                                                required: nil,
			                                                enumValues: nil,
			                                                itemType: nil,
			                                                schema: nil,
			                                                viewModelId: nil,
			                                                validation: nil
			                                            ),
			                                            "items": ViewModelProperty(
			                                                type: .list,
			                                                propertyId: 3,
			                                                defaultValue: AnyCodable([itemOne, itemTwo] as [Any]),
			                                                required: nil,
			                                                enumValues: nil,
			                                                itemType: ViewModelProperty(
			                                                    type: .viewModel,
			                                                    propertyId: nil,
			                                                    defaultValue: nil,
			                                                    required: nil,
			                                                    enumValues: nil,
			                                                    itemType: nil,
			                                                    schema: nil,
			                                                    viewModelId: "vm-item",
			                                                    validation: nil
			                                                ),
			                                                schema: nil,
			                                                viewModelId: nil,
			                                                validation: nil
			                                            )
			                                        ]
			                                    ),
			                                    ViewModel(
			                                        id: "vm-item",
			                                        name: "Item",
			                                        viewModelPathId: 1,
			                                        properties: [
			                                            "label": ViewModelProperty(
			                                                type: .string,
			                                                propertyId: 1,
			                                                defaultValue: AnyCodable(""),
			                                                required: nil,
			                                                enumValues: nil,
			                                                itemType: nil,
			                                                schema: nil,
			                                                viewModelId: nil,
			                                                validation: nil
			                                            )
			                                        ]
			                                    )
			                                ],
			                                viewModelInstances: nil,
			                                converters: nil
			                            )
			                        } else {
			                            remoteFlow = RemoteFlow(
			                                id: reqFlowId,
			                                bundle: FlowBundleRef(url: bundleBaseUrl, manifest: manifest),
	                                screens: [
                                    RemoteFlowScreen(
                                        id: "screen-1",
                                        defaultViewModelId: "vm-1",
                                        defaultInstanceId: nil
                                    )
                                ],
                                interactions: [
                                    "tap": [
                                        Interaction(
                                            id: "int-tap",
                                            trigger: .press,
                                            actions: [
                                                .setViewModel(
                                                    SetViewModelAction(
                                                        path: .ids(VmPathIds(pathIds: [0, 1])),
                                                        value: AnyCodable(["literal": "world"] as [String: Any])
                                                    )
                                                )
                                            ],
                                            enabled: true
                                        )
                                    ]
                                ],
                                viewModels: [
                                    ViewModel(
                                        id: "vm-1",
                                        name: "VM",
                                        viewModelPathId: 0,
                                        properties: [
                                            "title": ViewModelProperty(
                                                type: .string,
                                                propertyId: 1,
                                                defaultValue: AnyCodable("hello"),
                                                required: nil,
                                                enumValues: nil,
                                                itemType: nil,
                                                schema: nil,
                                                viewModelId: nil,
                                                validation: nil
                                            )
                                        ]
                                    )
                                ],
                                viewModelInstances: nil,
                                converters: nil
                            )
                        }

                        let encoder = JSONEncoder()
                        let json = (try? encoder.encode(remoteFlow)) ?? Data("{}".utf8)
                        return LocalHTTPServer.Response.json(json)
                    }

				                        if request.method == "GET", request.path.hasPrefix("/bundles/") {
				                            let suffix = request.path.replacingOccurrences(of: "/bundles/", with: "")
				                            let parts = suffix.split(separator: "/", omittingEmptySubsequences: true)
					                            let reqFlowId = parts.first.map(String.init) ?? ""
					                            let isExperimentAbFlow = reqFlowId.hasPrefix("flow_e2e_experiment_ab_")
					                            let isCompiledViewModelFlow = reqFlowId.hasPrefix("flow_e2e_compiled_view_model_")
					                            let isDidSetFlow = reqFlowId.hasPrefix("flow_e2e_did_set_")
					                            let isParityTraceFlow = reqFlowId.hasPrefix("flow_e2e_parity_trace_")
					                            let isRemoteActionFlow = reqFlowId.hasPrefix("flow_e2e_remote_action_")
					                            let isCallDelegateFlow = reqFlowId.hasPrefix("flow_e2e_call_delegate_")
					                            let isOpenLinkFlow = reqFlowId.hasPrefix("flow_e2e_open_link_")
					                            let isPurchaseFlow = reqFlowId.hasPrefix("flow_e2e_purchase_")
					                            let isRestoreFlow = reqFlowId.hasPrefix("flow_e2e_restore_")
					                            let isNavStackFlow = reqFlowId.hasPrefix("flow_e2e_nav_stack_")
					                            let isLongPressFlow = reqFlowId.hasPrefix("flow_e2e_long_press_")
					                            let isDragFlow = reqFlowId.hasPrefix("flow_e2e_drag_")
					                            let isCustomerUpdateEventFlow = reqFlowId.hasPrefix("flow_e2e_customer_update_event_")
					                            let isListOpsFlow = reqFlowId.hasPrefix("flow_e2e_list_ops_")
					                            let isMissingAssetFlow = reqFlowId.hasPrefix("flow_e2e_missing_asset_")
					                            let isCompiledBundleFlow = isExperimentAbFlow
					                                || isCompiledViewModelFlow
					                                || isDidSetFlow
					                                || isParityTraceFlow
					                                || isRemoteActionFlow
					                                || isCallDelegateFlow
					                                || isOpenLinkFlow
					                                || isPurchaseFlow
					                                || isRestoreFlow
					                                || isNavStackFlow
					                                || isLongPressFlow
					                                || isDragFlow
					                                || isCustomerUpdateEventFlow
					                                || isListOpsFlow
				                        let requestedFile = parts.dropFirst().joined(separator: "/")
				                        let fileName = requestedFile.isEmpty ? "index.html" : requestedFile

		                        if isCompiledBundleFlow {
	                            guard let fixture = experimentAbCompiledBundleFixture else {
	                                return LocalHTTPServer.Response.text(
	                                    "Missing compiled bundle fixture",
	                                    statusCode: 500
	                                )
	                            }
                            guard let file = fixture.filesByPath[fileName] else {
                                return LocalHTTPServer.Response.text("Not Found", statusCode: 404)
                            }
                            return LocalHTTPServer.Response(
                                statusCode: 200,
                                headers: ["Content-Type": "\(file.contentType); charset=utf-8"],
                                body: file.data
                            )
                        }

                        if isMissingAssetFlow, fileName != "index.html" {
                            return LocalHTTPServer.Response.text("Not Found", statusCode: 404)
                        }

                        let html = """
                        <!doctype html>
                        <html>
                          <head>
                            <meta charset="utf-8" />
                            <meta name="viewport" content="width=device-width, initial-scale=1" />
                            <title>Nuxie Flow Runtime E2E</title>
                          </head>
                          <body>
                            <div id="status">loading</div>
                            <div id="screen-id">(unset)</div>
                            <div id="vm-text">(unset)</div>
                            <button id="tap" type="button">Tap</button>
                              <script>
                              (function(){
                                // Minimal runtime surface for Flow Runtime E2E fixtures:
                                // - Provide window.nuxie._handleHostMessage (host -> web)
                                // - Emit runtime/ready and runtime/screen_changed (web -> host)
                                // - Reflect runtime/navigate into the DOM
                                // - Apply runtime/view_model_init + runtime/view_model_patch into the DOM
                                // - Emit a deterministic action/press from a button click

                                function post(type, payload) {
                                  try {
                                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge) {
                                      window.webkit.messageHandlers.bridge.postMessage({ type: type, payload: payload || {} });
                                      return true;
                                    }
                                  } catch (e) {}
                                  return false;
                                }

                                function setScreenId(value) {
                                  try {
                                    var el = document.getElementById("screen-id");
                                    if (!el) return;
                                    if (value === null || value === undefined) {
                                      el.textContent = "(null)";
                                    } else {
                                      el.textContent = String(value);
                                    }
                                  } catch (e) {}
                                }

                                function setVmText(value) {
                                  try {
                                    var el = document.getElementById("vm-text");
                                    if (!el) return;
                                    if (value === null || value === undefined) {
                                      el.textContent = "(null)";
                                    } else {
                                      el.textContent = String(value);
                                    }
                                  } catch (e) {}
                                }

                                window.nuxie = {
                                  _handleHostMessage: function(envelope) {
                                    try {
                                      if (!envelope || !envelope.type) return;
                                      if (envelope.type === "runtime/navigate") {
                                        var screenId = (envelope.payload && envelope.payload.screenId) || null;
                                        window.__nuxieScreenId = screenId;
                                        setScreenId(screenId);
                                        post("runtime/screen_changed", { screenId: screenId });
                                        return;
                                      }
                                      if (envelope.type === "runtime/view_model_init") {
                                        var instances = envelope.payload && envelope.payload.instances;
                                        var first = instances && instances[0];
                                        var title = first && first.values && first.values.title;
                                        if (title !== undefined) setVmText(title);
                                        return;
                                      }
                                      if (envelope.type === "runtime/view_model_patch") {
                                        if (envelope.payload && Object.prototype.hasOwnProperty.call(envelope.payload, "value")) {
                                          setVmText(envelope.payload.value);
                                        }
                                        return;
                                      }
                                    } catch (e) {}
                                  }
                                };

                                try {
                                  document.getElementById("tap").addEventListener("click", function() {
                                    post("action/press", { componentId: "tap", screenId: window.__nuxieScreenId || null });
                                  });
                                } catch (e) {}

                                function sendReadyOnce() {
                                  if (post("runtime/ready", { version: "e2e" })) {
                                    document.getElementById("status").textContent = "ready-sent";
                                    return true;
                                  }
                                  return false;
                                }
                                var readyTimer = setInterval(function() {
                                  if (sendReadyOnce()) clearInterval(readyTimer);
                                }, 50);
                              })();
                            </script>
                          </body>
                        </html>
                        """
                        return LocalHTTPServer.Response.html(html)
                    }

                        if request.method == "GET", request.path == "/favicon.ico" {
                            return LocalHTTPServer.Response(statusCode: 204, headers: [:], body: Data())
                        }

                        return LocalHTTPServer.Response.text("Not Found", statusCode: 404)
                    }
                }

                guard let server else {
                    fail("Failed to start LocalHTTPServer for E2E test")
                    return
                }

                apiKey = "pk_test_e2e_local"
                baseURL = server.baseURL
                flowId = "flow_e2e_ready_\(UUID().uuidString)"
            }

            afterEach {
                flowViewController = nil
                runtimeDelegate = nil
                window?.isHidden = true
                window?.rootViewController = nil
	                window = nil
	                requestLog = nil
	                batchBodies = nil
	                eventBodies = nil
	            }

            afterSuite {
                server?.stop()
                server = nil
            }

            it("fetches /flows/:id, receives runtime/ready, and completes a navigate→screen_changed handshake") {
                let messages = LockedArray<String>()
                let expectedScreenId = LockedValue<String?>(nil)
                let screenChangedId = LockedValue<String?>(nil)

                waitUntil(timeout: .seconds(45)) { done in
                    var finished = false
                    var didReceiveReady = false
                    runtimeDelegate = CapturingRuntimeDelegate(onMessage: { type, payload, _ in
                        let payloadKeys = payload.keys.sorted().joined(separator: ",")
                        messages.append("\(type) keys=[\(payloadKeys)]")

                        if type == "runtime/ready" {
                            didReceiveReady = true
                            // Drive the smallest "real runtime" contract: host -> web navigate, web -> host ack.
                            Task { @MainActor in
                                guard let vc = flowViewController else {
                                    fail("E2E: FlowViewController was not created")
                                    guard !finished else { return }
                                    finished = true
                                    done()
                                    return
                                }
                                guard let screenId = vc.flow.remoteFlow.screens.first?.id else {
                                    fail("E2E: RemoteFlow has no screens; cannot test runtime/navigate")
                                    guard !finished else { return }
                                    finished = true
                                    done()
                                    return
                                }

                                expectedScreenId.set(screenId)
                                flowViewController?.sendRuntimeMessage(
                                    type: "runtime/navigate",
                                    payload: ["screenId": screenId]
                                )
                            }
                            return
                        }

                        if type == "runtime/screen_changed" {
                            guard didReceiveReady else { return }
                            guard let expected = expectedScreenId.get() else { return }
                            let got = payload["screenId"] as? String
                            guard got == expected else { return }

                            screenChangedId.set(got)
                            guard !finished else { return }
                            finished = true
                            done()
                        }
                    })

                    Task {
                        do {
                            let api = NuxieApi(apiKey: apiKey, baseURL: baseURL)
                            let remoteFlow = try await api.fetchFlow(flowId: flowId)
                            let flow = Flow(remoteFlow: remoteFlow, products: [])

                            let archiveService = FlowArchiver()
                            // This conformance check should reflect the current backend response, not a cached
                            // WebArchive from a previous run.
                            await archiveService.removeArchive(for: flow.id)

                            await MainActor.run {
                                let vc = FlowViewController(flow: flow, archiveService: archiveService)
                                vc.runtimeDelegate = runtimeDelegate
                                flowViewController = vc
                                let testWindow = UIWindow(frame: UIScreen.main.bounds)
                                testWindow.rootViewController = vc
                                testWindow.makeKeyAndVisible()
                                window = testWindow
                                _ = vc.view
                            }
                        } catch {
                            fail("E2E setup failed: \(error)")
                            guard !finished else { return }
                            finished = true
                            done()
                        }
                    }
                }

                // If the waitUntil timed out, include last observed messages for debugging.
                let messagesSnapshot = messages.snapshot()
                expect(messagesSnapshot.contains(where: { $0.hasPrefix("runtime/ready") })).to(beTrue())
                guard let expected = expectedScreenId.get() else {
                    fail("E2E: did not resolve expected screen id; messages=\(messagesSnapshot)")
                    return
                }
                expect(screenChangedId.get()).to(equal(expected))
            }

            it("applies view model init/patch and emits action/press (fixture mode)") {
                guard server != nil else { return }
                guard isEnabled("NUXIE_E2E_ENABLE_VIEWMODELS", legacyKeys: ["NUXIE_E2E_PHASE1"]) else { return }

                let messages = LockedArray<String>()
                let didApplyInit = LockedValue(false)
                let didApplyPatch = LockedValue(false)
                let didReceiveTap = LockedValue(false)

                waitUntil(timeout: .seconds(60)) { done in
                    var finished = false

                    func finishOnce() {
                        guard !finished else { return }
                        finished = true
                        done()
                    }

                    Task {
                        do {
                            // Ensure FlowJourneyRunner can resolve injected dependencies without requiring full SDK setup.
                            Container.shared.reset()
                            let config = NuxieConfiguration(apiKey: apiKey)
                            config.apiEndpoint = baseURL
                            config.enablePlugins = false
                            config.customStoragePath = FileManager.default.temporaryDirectory
                                .appendingPathComponent("nuxie-e2e-\(UUID().uuidString)", isDirectory: true)
                            Container.shared.sdkConfiguration.register { config }
                            Container.shared.eventService.register { MockEventService() }

                            let api = NuxieApi(apiKey: apiKey, baseURL: baseURL)
                            let remoteFlow = try await api.fetchFlow(flowId: flowId)
                            let flow = Flow(remoteFlow: remoteFlow, products: [])

                            let archiveService = FlowArchiver()
                            await archiveService.removeArchive(for: flow.id)

                            await MainActor.run {
                                let vc = FlowViewController(flow: flow, archiveService: archiveService)
                                let campaign = makeCampaign(flowId: flowId)
                                let journey = Journey(campaign: campaign, distinctId: "e2e-user")
                                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
                                runner.attach(viewController: vc)

                                let bridge = FlowJourneyRunnerRuntimeBridge(runner: runner)
                                let delegate = FlowJourneyRunnerRuntimeDelegate(bridge: bridge) { type, payload, id in
                                    let payloadKeys = payload.keys.sorted().joined(separator: ",")
                                    messages.append("\(type) keys=[\(payloadKeys)]")
                                    if type == "action/press" {
                                        if payload["componentId"] as? String == "tap" || payload["elementId"] as? String == "tap" {
                                            didReceiveTap.set(true)
                                        }
                                    }
                                }
                                runtimeDelegate = delegate
                                vc.runtimeDelegate = delegate
                                flowViewController = vc
                                let testWindow = UIWindow(frame: UIScreen.main.bounds)
                                testWindow.rootViewController = vc
                                testWindow.makeKeyAndVisible()
                                window = testWindow
                                _ = vc.view
                            }

                            guard let vc = flowViewController else {
                                fail("E2E: FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }
                            let webView = await MainActor.run { vc.flowWebView }
                            guard let webView else {
                                fail("E2E: FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }

                            guard (try? await waitForElementExists(webView, elementId: "tap", timeoutSeconds: 20.0)) == true else {
                                fail("E2E: bundle HTML did not render (tap not found)")
                                finishOnce()
                                return
                            }

                            if (try? await waitForVmText(webView, equals: "hello", timeoutSeconds: 30.0)) == true {
                                didApplyInit.set(true)
                            } else {
                                fail("E2E: view model init did not update DOM")
                                finishOnce()
                                return
                            }

                            _ = try? await evaluateJavaScript(webView, script: "document.getElementById('tap').click()")

                            if (try? await waitForVmText(webView, equals: "world", timeoutSeconds: 30.0)) == true {
                                didApplyPatch.set(true)
                            } else {
                                fail("E2E: view model patch did not update DOM")
                                finishOnce()
                                return
                            }

                            if didReceiveTap.get(), didApplyInit.get(), didApplyPatch.get() {
                                finishOnce()
                            }
                        } catch {
                            fail("E2E setup failed: \(error)")
                            finishOnce()
                        }
                    }
                }

                let messagesSnapshot = messages.snapshot()
                expect(messagesSnapshot.contains(where: { $0.hasPrefix("runtime/ready") })).to(beTrue())
                expect(messagesSnapshot.contains(where: { $0.hasPrefix("runtime/screen_changed") })).to(beTrue())
                expect(messagesSnapshot.contains(where: { $0.hasPrefix("action/press") })).to(beTrue())
                expect(didApplyInit.get()).to(beTrue())
                expect(didApplyPatch.get()).to(beTrue())
                expect(didReceiveTap.get()).to(beTrue())
            }

            it("renders view model init/patch in the compiled web runtime (fixture mode)") {
                guard server != nil else { return }
                guard isEnabled("NUXIE_E2E_ENABLE_VIEWMODELS", legacyKeys: ["NUXIE_E2E_PHASE1"]) else { return }
                guard experimentAbCompiledBundleFixture != nil else {
                    fail("E2E: missing compiled bundle fixture")
                    return
                }

                let compiledVmFlowId = "flow_e2e_compiled_view_model_\(UUID().uuidString)"
                let distinctId = "e2e-user-compiled-vm-1"

                let messages = LockedArray<String>()
                let didApplyInit = LockedValue(false)
                let didApplyPatch = LockedValue(false)
                let didReceiveTap = LockedValue(false)

                waitUntil(timeout: .seconds(60)) { done in
                    var finished = false

                    func finishOnce() {
                        guard !finished else { return }
                        finished = true
                        done()
                    }

                    Task {
                        do {
                            Container.shared.reset()
                            let config = NuxieConfiguration(apiKey: apiKey)
                            config.apiEndpoint = baseURL
                            config.enablePlugins = false
                            config.customStoragePath = FileManager.default.temporaryDirectory
                                .appendingPathComponent("nuxie-e2e-\(UUID().uuidString)", isDirectory: true)
                            Container.shared.sdkConfiguration.register { config }
                            Container.shared.eventService.register { MockEventService() }

                            let api = NuxieApi(apiKey: apiKey, baseURL: baseURL)
                            let remoteFlow = try await api.fetchFlow(flowId: compiledVmFlowId)
                            let flow = Flow(remoteFlow: remoteFlow, products: [])

                            let archiveService = FlowArchiver()
                            await archiveService.removeArchive(for: flow.id)

                            await MainActor.run {
                                let vc = FlowViewController(flow: flow, archiveService: archiveService)
                                let campaign = makeCampaign(flowId: compiledVmFlowId)
                                let journey = Journey(campaign: campaign, distinctId: distinctId)
                                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
                                runner.attach(viewController: vc)

                                let bridge = FlowJourneyRunnerRuntimeBridge(runner: runner)
                                let delegate = FlowJourneyRunnerRuntimeDelegate(bridge: bridge) { type, payload, _ in
                                    let payloadKeys = payload.keys.sorted().joined(separator: ",")
                                    messages.append("\(type) keys=[\(payloadKeys)]")
                                    if type == "action/press" {
                                        if payload["componentId"] as? String == "tap" || payload["elementId"] as? String == "tap" {
                                            didReceiveTap.set(true)
                                        }
                                    }
                                }
                                runtimeDelegate = delegate
                                vc.runtimeDelegate = delegate
                                flowViewController = vc

                                let testWindow = UIWindow(frame: UIScreen.main.bounds)
                                testWindow.rootViewController = vc
                                testWindow.makeKeyAndVisible()
                                window = testWindow
                                _ = vc.view
                            }

                            guard let vc = flowViewController else {
                                fail("E2E: FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }
                            let webView = await MainActor.run { vc.flowWebView }
                            guard let webView else {
                                fail("E2E: FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }

                            let entryMarkerId = "screen-screen-entry-marker"
                            guard (try? await waitForElementExists(webView, elementId: entryMarkerId, timeoutSeconds: 20.0)) == true else {
                                fail("E2E: compiled web runtime did not render entry marker '\(entryMarkerId)'")
                                finishOnce()
                                return
                            }

                            if (try? await waitForVmText(webView, equals: "hello", timeoutSeconds: 30.0)) == true {
                                didApplyInit.set(true)
                            } else {
                                fail("E2E: compiled runtime view model init did not update DOM")
                                finishOnce()
                                return
                            }

                            _ = try? await evaluateJavaScript(webView, script: "document.getElementById('tap').click()")

                            if (try? await waitForVmText(webView, equals: "world", timeoutSeconds: 30.0)) == true {
                                didApplyPatch.set(true)
                            } else {
                                fail("E2E: compiled runtime view model patch did not update DOM")
                                finishOnce()
                                return
                            }

                            if didReceiveTap.get(), didApplyInit.get(), didApplyPatch.get() {
                                finishOnce()
                            }
                        } catch {
                            fail("E2E setup failed: \(error)")
                            finishOnce()
                        }
                    }
                }

                let messagesSnapshot = messages.snapshot()
                expect(messagesSnapshot.contains(where: { $0.hasPrefix("runtime/ready") })).to(beTrue())
                expect(messagesSnapshot.contains(where: { $0.hasPrefix("action/press") })).to(beTrue())
                expect(didApplyInit.get()).to(beTrue())
	                expect(didApplyPatch.get()).to(beTrue())
	                expect(didReceiveTap.get()).to(beTrue())
	            }

	            it("dispatches action/did_set from the compiled web runtime and runs did_set triggers (fixture mode)") {
	                guard server != nil else { return }
	                guard isEnabled("NUXIE_E2E_ENABLE_VIEWMODELS", legacyKeys: ["NUXIE_E2E_PHASE1"]) else { return }
	                guard experimentAbCompiledBundleFixture != nil else {
	                    fail("E2E: missing compiled bundle fixture")
	                    return
	                }

	                let didSetFlowId = "flow_e2e_did_set_\(UUID().uuidString)"
	                let distinctId = "e2e-user-did-set-1"

	                let messages = LockedArray<String>()
	                let didReceiveDidSet = LockedValue(false)
	                let didApplyDidSetAck = LockedValue(false)

	                waitUntil(timeout: .seconds(60)) { done in
	                    var finished = false

	                    func finishOnce() {
	                        guard !finished else { return }
	                        finished = true
	                        done()
	                    }

	                    Task {
	                        do {
	                            Container.shared.reset()
	                            let config = NuxieConfiguration(apiKey: apiKey)
	                            config.apiEndpoint = baseURL
	                            config.enablePlugins = false
	                            config.customStoragePath = FileManager.default.temporaryDirectory
	                                .appendingPathComponent("nuxie-e2e-\(UUID().uuidString)", isDirectory: true)
	                            Container.shared.sdkConfiguration.register { config }
	                            Container.shared.eventService.register { MockEventService() }

	                            let api = NuxieApi(apiKey: apiKey, baseURL: baseURL)
	                            let remoteFlow = try await api.fetchFlow(flowId: didSetFlowId)
	                            let flow = Flow(remoteFlow: remoteFlow, products: [])

	                            let archiveService = FlowArchiver()
	                            await archiveService.removeArchive(for: flow.id)

	                            await MainActor.run {
	                                let vc = FlowViewController(flow: flow, archiveService: archiveService)
	                                let campaign = makeCampaign(flowId: didSetFlowId)
	                                let journey = Journey(campaign: campaign, distinctId: distinctId)
	                                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
	                                runner.attach(viewController: vc)

	                                let bridge = FlowJourneyRunnerRuntimeBridge(runner: runner)
	                                let delegate = FlowJourneyRunnerRuntimeDelegate(bridge: bridge) { type, payload, _ in
	                                    let payloadKeys = payload.keys.sorted().joined(separator: ",")
	                                    messages.append("\(type) keys=[\(payloadKeys)]")
	                                    if type == "action/did_set" {
	                                        let ids = payload["pathIds"] as? [Int]
	                                        let nums = payload["pathIds"] as? [NSNumber]
	                                        let normalized = ids ?? nums?.map { $0.intValue }
	                                        if normalized == [0, 1] {
	                                            didReceiveDidSet.set(true)
	                                        }
	                                    }
	                                }
	                                runtimeDelegate = delegate
	                                vc.runtimeDelegate = delegate
	                                flowViewController = vc

	                                let testWindow = UIWindow(frame: UIScreen.main.bounds)
	                                testWindow.rootViewController = vc
	                                testWindow.makeKeyAndVisible()
	                                window = testWindow
	                                _ = vc.view
	                            }

	                            guard let vc = flowViewController else {
	                                fail("E2E: FlowViewController/webView was not created")
	                                finishOnce()
	                                return
	                            }
	                            let webView = await MainActor.run { vc.flowWebView }
	                            guard let webView else {
	                                fail("E2E: FlowViewController/webView was not created")
	                                finishOnce()
	                                return
	                            }

	                            let entryMarkerId = "screen-screen-entry-marker"
	                            guard (try? await waitForElementExists(webView, elementId: entryMarkerId, timeoutSeconds: 20.0)) == true else {
	                                fail("E2E: compiled web runtime did not render entry marker '\(entryMarkerId)'")
	                                finishOnce()
	                                return
	                            }

	                            guard (try? await waitForElementExists(webView, elementId: "title-input", timeoutSeconds: 20.0)) == true else {
	                                fail("E2E: compiled web runtime did not render title-input")
	                                finishOnce()
	                                return
	                            }

	                            guard (try? await waitForVmText(webView, equals: "hello", timeoutSeconds: 30.0)) == true else {
	                                fail("E2E: compiled runtime view model init did not update DOM")
	                                finishOnce()
	                                return
	                            }

	                            let nextValue = "Next"
	                            let didDispatch = try? await evaluateJavaScript(webView, script: """
	                            (function(){
	                              var el = document.getElementById('title-input');
	                              if (!el) return false;
	                              el.value = \(jsStringLiteral(nextValue));
	                              el.dispatchEvent(new Event('input', { bubbles: true }));
	                              return true;
	                            })();
	                            """) as? Bool
	                            if didDispatch != true {
	                                fail("E2E: failed to dispatch input event on title-input")
	                                finishOnce()
	                                return
	                            }

	                            if (try? await waitForElementText(webView, elementId: "did-set-ack", equals: "ack", timeoutSeconds: 30.0)) == true {
	                                didApplyDidSetAck.set(true)
	                            } else {
	                                fail("E2E: did_set trigger did not produce host patch (did-set-ack)")
	                                finishOnce()
	                                return
	                            }

	                            if didReceiveDidSet.get(), didApplyDidSetAck.get() {
	                                finishOnce()
	                            }
	                        } catch {
	                            fail("E2E setup failed: \(error)")
	                            finishOnce()
	                        }
	                    }
	                }

	                let messagesSnapshot = messages.snapshot()
	                expect(messagesSnapshot.contains(where: { $0.hasPrefix("runtime/ready") })).to(beTrue())
	                expect(messagesSnapshot.contains(where: { $0.hasPrefix("runtime/screen_changed") })).to(beTrue())
	                expect(messagesSnapshot.contains(where: { $0.hasPrefix("action/did_set") })).to(beTrue())
	                expect(didReceiveDidSet.get()).to(beTrue())
	                expect(didApplyDidSetAck.get()).to(beTrue())
	            }

	            it("records canonical runtime parity trace for navigation + did_set input (fixture mode)") {
	                guard server != nil else { return }
	                guard isEnabled("NUXIE_E2E_ENABLE_VIEWMODELS", legacyKeys: ["NUXIE_E2E_PHASE1"]) else { return }
	                guard isEnabled("NUXIE_E2E_ENABLE_NAVIGATION") else { return }
	                guard experimentAbCompiledBundleFixture != nil else {
	                    fail("E2E: missing compiled bundle fixture")
	                    return
	                }
	                let parityRenderer = parityRendererSelectionFromEnvironment()

	                let parityFlowId = "flow_e2e_parity_trace_\(UUID().uuidString)"
	                let distinctId = "e2e-user-parity-trace-1"

	                let didApplyDidSetAck = LockedValue(false)
	                let didNavigateToScreen2 = LockedValue(false)
	                let recordedTrace = LockedValue<FlowRuntimeTrace?>(nil)
	                let selectedRendererBackend = LockedValue<String?>(nil)

	                waitUntil(timeout: .seconds(60)) { done in
	                    var finished = false

	                    func finishOnce() {
	                        guard !finished else { return }
	                        finished = true
	                        done()
	                    }

	                    Task {
	                        let traceRecorder = FlowRuntimeTraceRecorder()
	                        let mockEventService = TraceRecordingMockEventService(
	                            traceRecorder: traceRecorder
	                        )
	                        let originalSupportedCapabilities = RemoteFlow.supportedCapabilities
	                        let originalPreferredCompilerBackends = RemoteFlow.preferredCompilerBackends
	                        let originalRenderableCompilerBackends = RemoteFlow.renderableCompilerBackends

	                        do {
	                            RemoteFlow.supportedCapabilities = parityRenderer.supportedCapabilities
	                            RemoteFlow.preferredCompilerBackends = parityRenderer.preferredCompilerBackends
	                            RemoteFlow.renderableCompilerBackends = parityRenderer.renderableCompilerBackends
	                            defer {
	                                RemoteFlow.supportedCapabilities = originalSupportedCapabilities
	                                RemoteFlow.preferredCompilerBackends = originalPreferredCompilerBackends
	                                RemoteFlow.renderableCompilerBackends = originalRenderableCompilerBackends
	                            }

	                            Container.shared.reset()
	                            let config = NuxieConfiguration(apiKey: apiKey)
	                            config.apiEndpoint = baseURL
	                            config.enablePlugins = false
	                            config.customStoragePath = FileManager.default.temporaryDirectory
	                                .appendingPathComponent("nuxie-e2e-\(UUID().uuidString)", isDirectory: true)
	                            Container.shared.sdkConfiguration.register { config }
	                            Container.shared.eventService.register { mockEventService }

	                            let api = NuxieApi(apiKey: apiKey, baseURL: baseURL)
	                            let remoteFlow = try await api.fetchFlow(flowId: parityFlowId)
	                            let flow = Flow(remoteFlow: remoteFlow, products: [])
	                            let targetSelection = flow.remoteFlow.selectedTargetResult
	                            let rendererBackend = targetSelection.selectedCompilerBackend ?? "legacy"
	                            selectedRendererBackend.set(rendererBackend)
	                            if rendererBackend != parityRenderer.expectedRendererBackend {
	                                fail("E2E: expected parity renderer '\(parityRenderer.expectedRendererBackend)' but selected '\(rendererBackend)'")
	                                finishOnce()
	                                return
	                            }

	                            let archiveService = FlowArchiver()
	                            await archiveService.removeArchive(for: flow.id)

	                            await MainActor.run {
	                                let vc = FlowViewController(flow: flow, archiveService: archiveService)
	                                let campaign = makeCampaign(flowId: parityFlowId)
	                                let journey = Journey(campaign: campaign, distinctId: distinctId)
	                                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
	                                runner.attach(viewController: vc)

	                                let bridge = FlowJourneyRunnerRuntimeBridge(runner: runner)
	                                let delegate = FlowJourneyRunnerRuntimeDelegate(
	                                    bridge: bridge,
	                                    onMessage: nil,
	                                    traceRecorder: traceRecorder
	                                )
	                                runtimeDelegate = delegate
	                                vc.runtimeDelegate = delegate
	                                flowViewController = vc

	                                let testWindow = UIWindow(frame: UIScreen.main.bounds)
	                                testWindow.rootViewController = vc
	                                testWindow.makeKeyAndVisible()
	                                window = testWindow
	                                _ = vc.view
	                            }

	                            guard let vc = flowViewController else {
	                                fail("E2E: FlowViewController/webView was not created")
	                                finishOnce()
	                                return
	                            }
	                            let webView = await MainActor.run { vc.flowWebView }
	                            guard let webView else {
	                                fail("E2E: FlowViewController/webView was not created")
	                                finishOnce()
	                                return
	                            }

	                            let entryMarkerId = "screen-screen-entry-marker"
	                            guard (try? await waitForElementExists(webView, elementId: entryMarkerId, timeoutSeconds: 20.0)) == true else {
	                                fail("E2E: compiled web runtime did not render entry marker '\(entryMarkerId)'")
	                                finishOnce()
	                                return
	                            }

	                            guard (try? await waitForElementExists(webView, elementId: "title-input", timeoutSeconds: 20.0)) == true else {
	                                fail("E2E: compiled web runtime did not render title-input")
	                                finishOnce()
	                                return
	                            }

	                            let nextValue = "parity-next"
	                            let didDispatchInput = try? await evaluateJavaScript(webView, script: """
	                            (function(){
	                              var el = document.getElementById('title-input');
	                              if (!el) return false;
	                              el.value = \(jsStringLiteral(nextValue));
	                              el.dispatchEvent(new Event('input', { bubbles: true }));
	                              return true;
	                            })();
	                            """) as? Bool
	                            if didDispatchInput != true {
	                                fail("E2E: failed to dispatch input event on title-input")
	                                finishOnce()
	                                return
	                            }

	                            if (try? await waitForElementText(webView, elementId: "did-set-ack", equals: "ack", timeoutSeconds: 30.0)) == true {
	                                didApplyDidSetAck.set(true)
	                            } else {
	                                fail("E2E: did_set trigger did not produce host patch (did-set-ack)")
	                                finishOnce()
	                                return
	                            }

	                            guard (try? await waitForElementExists(webView, elementId: "to-2", timeoutSeconds: 10.0)) == true else {
	                                fail("E2E: compiled web runtime is missing button 'to-2'")
	                                finishOnce()
	                                return
	                            }
	                            _ = try? await evaluateJavaScript(webView, script: "document.getElementById('to-2').click()")

	                            let screen2MarkerId = "screen-screen-2-marker"
	                            if (try? await waitForElementExists(webView, elementId: screen2MarkerId, timeoutSeconds: 20.0)) == true {
	                                didNavigateToScreen2.set(true)
	                            } else {
	                                fail("E2E: expected navigation to render marker '\(screen2MarkerId)'")
	                                finishOnce()
	                                return
	                            }

	                            recordedTrace.set(
	                                traceRecorder.trace(
	                                    fixtureId: "fixture-nav-binding",
	                                    rendererBackend: rendererBackend
	                                )
	                            )
	                            finishOnce()
	                        } catch {
	                            fail("E2E setup failed: \(error)")
	                            finishOnce()
	                        }
	                    }
	                }

	                expect(didApplyDidSetAck.get()).to(beTrue())
	                expect(didNavigateToScreen2.get()).to(beTrue())
	                expect(selectedRendererBackend.get()).to(equal(parityRenderer.expectedRendererBackend))
	                guard let trace = recordedTrace.get() else {
	                    fail("E2E: expected parity trace to be recorded")
	                    return
	                }

	                expect(trace.schemaVersion).to(equal(FlowRuntimeTrace.currentSchemaVersion))
	                expect(trace.fixtureId).to(equal("fixture-nav-binding"))
	                expect(trace.rendererBackend).to(equal(parityRenderer.expectedRendererBackend))
	                expect(trace.entries).toNot(beEmpty())
	                expect(trace.entries.contains(where: {
	                    $0.kind == .navigation
	                        && $0.name == "navigate"
	                        && $0.screenId == "screen-2"
	                })).to(beTrue())
	                expect(trace.entries.contains(where: {
	                    $0.kind == .binding
	                        && $0.name == "did_set"
	                })).to(beTrue())
	                let artifactLoadEvent = trace.entries.first(where: {
	                    $0.kind == .event
	                        && $0.name == JourneyEvents.flowArtifactLoadSucceeded
	                })
	                expect(artifactLoadEvent).toNot(beNil())
	                expect(artifactLoadEvent?.output).to(contain("\"adapter_backend\":\"\(parityRenderer.expectedRendererBackend)\""))
	            }

	            it("applies list operations (insert/move/remove) in the compiled web runtime (fixture mode)") {
	                guard server != nil else { return }
	                guard isEnabled("NUXIE_E2E_ENABLE_VIEWMODELS", legacyKeys: ["NUXIE_E2E_PHASE1"]) else { return }
	                guard experimentAbCompiledBundleFixture != nil else {
	                    fail("E2E: missing compiled bundle fixture")
	                    return
	                }

	                let flowId = "flow_e2e_list_ops_\(UUID().uuidString)"
	                let distinctId = "e2e-user-list-ops-1"

	                let messages = LockedArray<String>()
	                let didReceiveInsertTap = LockedValue(false)
	                let didReceiveMoveTap = LockedValue(false)
	                let didReceiveRemoveTap = LockedValue(false)

	                waitUntil(timeout: .seconds(60)) { done in
	                    var finished = false

	                    func finishOnce() {
	                        guard !finished else { return }
	                        finished = true
	                        done()
	                    }

	                    Task {
	                        do {
	                            Container.shared.reset()
	                            let config = NuxieConfiguration(apiKey: apiKey)
	                            config.apiEndpoint = baseURL
	                            config.enablePlugins = false
	                            config.customStoragePath = FileManager.default.temporaryDirectory
	                                .appendingPathComponent("nuxie-e2e-\(UUID().uuidString)", isDirectory: true)
	                            Container.shared.sdkConfiguration.register { config }
	                            Container.shared.eventService.register { MockEventService() }

	                            let api = NuxieApi(apiKey: apiKey, baseURL: baseURL)
	                            let remoteFlow = try await api.fetchFlow(flowId: flowId)
	                            let flow = Flow(remoteFlow: remoteFlow, products: [])

	                            let archiveService = FlowArchiver()
	                            await archiveService.removeArchive(for: flow.id)

	                            await MainActor.run {
	                                let vc = FlowViewController(flow: flow, archiveService: archiveService)
	                                let campaign = makeCampaign(flowId: flowId)
	                                let journey = Journey(campaign: campaign, distinctId: distinctId)
	                                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
	                                runner.attach(viewController: vc)

	                                let bridge = FlowJourneyRunnerRuntimeBridge(runner: runner)
	                                let delegate = FlowJourneyRunnerRuntimeDelegate(bridge: bridge) { type, payload, _ in
	                                    let payloadKeys = payload.keys.sorted().joined(separator: ",")
	                                    messages.append("\(type) keys=[\(payloadKeys)]")
	                                    if type == "action/press" {
	                                        let componentId = (payload["componentId"] as? String) ?? (payload["elementId"] as? String)
	                                        switch componentId {
	                                        case "list-insert":
	                                            didReceiveInsertTap.set(true)
	                                        case "list-move":
	                                            didReceiveMoveTap.set(true)
	                                        case "list-remove":
	                                            didReceiveRemoveTap.set(true)
	                                        default:
	                                            break
	                                        }
	                                    }
	                                }
	                                runtimeDelegate = delegate
	                                vc.runtimeDelegate = delegate
	                                flowViewController = vc

	                                let testWindow = UIWindow(frame: UIScreen.main.bounds)
	                                testWindow.rootViewController = vc
	                                testWindow.makeKeyAndVisible()
	                                window = testWindow
	                                _ = vc.view
	                            }

	                            guard let vc = flowViewController else {
	                                fail("E2E: FlowViewController/webView was not created")
	                                finishOnce()
	                                return
	                            }
	                            let webView = await MainActor.run { vc.flowWebView }
	                            guard let webView else {
	                                fail("E2E: FlowViewController/webView was not created")
	                                finishOnce()
	                                return
	                            }

	                            let entryMarkerId = "screen-screen-entry-marker"
	                            guard (try? await waitForElementExists(webView, elementId: entryMarkerId, timeoutSeconds: 20.0)) == true else {
	                                fail("E2E: compiled web runtime did not render entry marker '\(entryMarkerId)'")
	                                finishOnce()
	                                return
	                            }

	                            guard (try? await waitForElementExists(webView, elementId: "list-items", timeoutSeconds: 20.0)) == true else {
	                                fail("E2E: compiled web runtime did not render list-items")
	                                finishOnce()
	                                return
	                            }

	                            guard (try? await waitForListItems(webView, containerId: "list-items", equals: ["one", "two"], timeoutSeconds: 30.0)) == true else {
	                                fail("E2E: initial list items did not render")
	                                finishOnce()
	                                return
	                            }

	                            _ = try? await evaluateJavaScript(webView, script: "document.getElementById('list-insert') && document.getElementById('list-insert').click()")
	                            guard (try? await waitForListItems(webView, containerId: "list-items", equals: ["one", "three", "two"], timeoutSeconds: 30.0)) == true else {
	                                fail("E2E: list insert did not update DOM")
	                                finishOnce()
	                                return
	                            }

	                            _ = try? await evaluateJavaScript(webView, script: "document.getElementById('list-move') && document.getElementById('list-move').click()")
	                            guard (try? await waitForListItems(webView, containerId: "list-items", equals: ["two", "one", "three"], timeoutSeconds: 30.0)) == true else {
	                                fail("E2E: list move did not update DOM")
	                                finishOnce()
	                                return
	                            }

	                            _ = try? await evaluateJavaScript(webView, script: "document.getElementById('list-remove') && document.getElementById('list-remove').click()")
	                            guard (try? await waitForListItems(webView, containerId: "list-items", equals: ["two", "three"], timeoutSeconds: 30.0)) == true else {
	                                fail("E2E: list remove did not update DOM")
	                                finishOnce()
	                                return
	                            }

	                            if didReceiveInsertTap.get(), didReceiveMoveTap.get(), didReceiveRemoveTap.get() {
	                                finishOnce()
	                            } else {
	                                fail("E2E: did not observe expected action/press messages for list ops")
	                                finishOnce()
	                            }
	                        } catch {
	                            fail("E2E setup failed: \(error)")
	                            finishOnce()
	                        }
	                    }
	                }

	                let messagesSnapshot = messages.snapshot()
	                expect(messagesSnapshot.contains(where: { $0.hasPrefix("runtime/ready") })).to(beTrue())
	                expect(messagesSnapshot.contains(where: { $0.hasPrefix("action/press") })).to(beTrue())
	                expect(didReceiveInsertTap.get()).to(beTrue())
	                expect(didReceiveMoveTap.get()).to(beTrue())
	                expect(didReceiveRemoveTap.get()).to(beTrue())
	            }

	            it("caches and loads a WebArchive on the next load (fixture mode)") {
	                guard let requestLog else { return }
	                guard server != nil else { return }

	                let testTimeoutSeconds = 120
                let vmTimeoutSeconds = 30.0
                let archiveTimeoutSeconds = 45.0

                let didLoadFirst = LockedValue(false)
                let didLoadSecond = LockedValue(false)

                waitUntil(timeout: .seconds(testTimeoutSeconds)) { done in
                    var finished = false

                    func finishOnce() {
                        guard !finished else { return }
                        finished = true
                        done()
                    }

                    Task {
                        do {
                            Container.shared.reset()
                            let config = NuxieConfiguration(apiKey: apiKey)
                            config.apiEndpoint = baseURL
                            config.enablePlugins = false
                            config.customStoragePath = FileManager.default.temporaryDirectory
                                .appendingPathComponent("nuxie-e2e-\(UUID().uuidString)", isDirectory: true)
                            Container.shared.sdkConfiguration.register { config }
                            Container.shared.eventService.register { MockEventService() }

                            let api = NuxieApi(apiKey: apiKey, baseURL: baseURL)
                            let remoteFlow = try await api.fetchFlow(flowId: flowId)
                            let flow = Flow(remoteFlow: remoteFlow, products: [])

                            let archiveService = FlowArchiver()
                            await archiveService.removeArchive(for: flow.id)

                            // First presentation (remote URL; kicks off background WebArchive preload).
                            await MainActor.run {
                                let vc = FlowViewController(flow: flow, archiveService: archiveService)
                                let campaign = makeCampaign(flowId: flowId)
                                let journey = Journey(campaign: campaign, distinctId: "e2e-user")
                                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
                                runner.attach(viewController: vc)

                                let bridge = FlowJourneyRunnerRuntimeBridge(runner: runner)
                                let delegate = FlowJourneyRunnerRuntimeDelegate(bridge: bridge, onMessage: nil)
                                runtimeDelegate = delegate
                                vc.runtimeDelegate = delegate
                                flowViewController = vc

                                let testWindow = UIWindow(frame: UIScreen.main.bounds)
                                testWindow.rootViewController = vc
                                testWindow.makeKeyAndVisible()
                                window = testWindow
                                _ = vc.view
                            }

                            guard let vc = flowViewController else {
                                fail("E2E: FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }
                            let webView = await MainActor.run { vc.flowWebView }
                            guard let webView else {
                                fail("E2E: FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }

                            if (try? await waitForElementExists(webView, elementId: "tap", timeoutSeconds: vmTimeoutSeconds)) == true {
                                didLoadFirst.set(true)
                            } else {
                                fail("E2E: first load did not render bundle HTML (tap not found)")
                                finishOnce()
                                return
                            }

                            guard let archiveURL = try await waitForArchiveURL(
                                archiveService,
                                for: flow,
                                timeoutSeconds: archiveTimeoutSeconds
                            ) else {
                                fail("E2E: expected WebArchive to be cached after first load")
                                finishOnce()
                                return
                            }
                            if !archiveURL.isFileURL {
                                fail("E2E: expected cached WebArchive URL to be a file URL")
                                finishOnce()
                                return
                            }

                            let logAfterFirst = requestLog.snapshot()
                            let firstLogCount = logAfterFirst.count

                            // Second presentation should load from cached WebArchive (no /bundles/* network).
                            await MainActor.run {
                                window?.rootViewController = nil
                                flowViewController = nil
                                runtimeDelegate = nil

                                let vc = FlowViewController(flow: flow, archiveService: archiveService)
                                let campaign = makeCampaign(flowId: flowId)
                                let journey = Journey(campaign: campaign, distinctId: "e2e-user-2")
                                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
                                runner.attach(viewController: vc)

                                let bridge = FlowJourneyRunnerRuntimeBridge(runner: runner)
                                let delegate = FlowJourneyRunnerRuntimeDelegate(bridge: bridge, onMessage: nil)
                                runtimeDelegate = delegate
                                vc.runtimeDelegate = delegate
                                flowViewController = vc

                                window?.rootViewController = vc
                                window?.makeKeyAndVisible()
                                _ = vc.view
                            }

                            guard let vc2 = flowViewController else {
                                fail("E2E: second FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }
                            let webView2 = await MainActor.run { vc2.flowWebView }
                            guard let webView2 else {
                                fail("E2E: second FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }

                            if (try? await waitForVmText(webView2, equals: "hello", timeoutSeconds: vmTimeoutSeconds)) == true {
                                didLoadSecond.set(true)
                            } else {
                                fail("E2E: second load did not reach runtime/view_model_init (cached WebArchive)")
                                finishOnce()
                                return
                            }

                            let logAfterSecond = requestLog.snapshot()
                            if logAfterSecond.count > firstLogCount {
                                let delta = logAfterSecond[firstLogCount..<logAfterSecond.count]
                                let didFetchBundleAgain = delta.contains(where: { $0.contains("/bundles/") })
                                if didFetchBundleAgain {
                                    fail("E2E: expected cached WebArchive load to avoid /bundles/* fetches; delta=\(Array(delta))")
                                    finishOnce()
                                    return
                                }
                            }

                            if didLoadFirst.get(), didLoadSecond.get() {
                                finishOnce()
                            }
                        } catch {
                            fail("E2E setup failed: \(error)")
                            finishOnce()
                        }
                    }
                }

                expect(didLoadFirst.get()).to(beTrue())
                expect(didLoadSecond.get()).to(beTrue())
            }

            it("does not cache a WebArchive when a manifest file is 404 (fixture mode)") {
                guard let requestLog else { return }
                guard server != nil else { return }

                let testTimeoutSeconds = 120
                let vmTimeoutSeconds = 30.0
                let missingRequestTimeoutSeconds = 30.0

                let missingFlowId = "flow_e2e_missing_asset_\(UUID().uuidString)"
                let didLoadFirst = LockedValue(false)
                let didLoadSecond = LockedValue(false)

                waitUntil(timeout: .seconds(testTimeoutSeconds)) { done in
                    var finished = false

                    func finishOnce() {
                        guard !finished else { return }
                        finished = true
                        done()
                    }

                    Task {
                        do {
                            Container.shared.reset()
                            let config = NuxieConfiguration(apiKey: apiKey)
                            config.apiEndpoint = baseURL
                            config.enablePlugins = false
                            config.customStoragePath = FileManager.default.temporaryDirectory
                                .appendingPathComponent("nuxie-e2e-\(UUID().uuidString)", isDirectory: true)
                            Container.shared.sdkConfiguration.register { config }
                            Container.shared.eventService.register { MockEventService() }

                            let api = NuxieApi(apiKey: apiKey, baseURL: baseURL)
                            let remoteFlow = try await api.fetchFlow(flowId: missingFlowId)
                            let flow = Flow(remoteFlow: remoteFlow, products: [])

                            let archiveService = FlowArchiver()
                            await archiveService.removeArchive(for: flow.id)

                            // First presentation (remote URL; archive preload should fail on missing.js).
                            await MainActor.run {
                                let vc = FlowViewController(flow: flow, archiveService: archiveService)
                                let campaign = makeCampaign(flowId: missingFlowId)
                                let journey = Journey(campaign: campaign, distinctId: "e2e-user-missing")
                                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
                                runner.attach(viewController: vc)

                                let bridge = FlowJourneyRunnerRuntimeBridge(runner: runner)
                                let delegate = FlowJourneyRunnerRuntimeDelegate(bridge: bridge, onMessage: nil)
                                runtimeDelegate = delegate
                                vc.runtimeDelegate = delegate
                                flowViewController = vc

                                let testWindow = UIWindow(frame: UIScreen.main.bounds)
                                testWindow.rootViewController = vc
                                testWindow.makeKeyAndVisible()
                                window = testWindow
                                _ = vc.view
                            }

                            guard let vc = flowViewController else {
                                fail("E2E: FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }
                            let webView = await MainActor.run { vc.flowWebView }
                            guard let webView else {
                                fail("E2E: FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }

                            guard (try? await waitForVmText(webView, equals: "hello", timeoutSeconds: vmTimeoutSeconds)) == true else {
                                fail("E2E: first load did not reach runtime/view_model_init")
                                finishOnce()
                                return
                            }
                            didLoadFirst.set(true)

                            let missingRequest = "GET /bundles/\(missingFlowId)/missing.js"
                            let firstMissingDeadline = Date().addingTimeInterval(missingRequestTimeoutSeconds)
                            while Date() < firstMissingDeadline {
                                if requestLog.snapshot().contains(missingRequest) {
                                    break
                                }
                                try await Task.sleep(nanoseconds: 50_000_000)
                            }
                            guard requestLog.snapshot().contains(missingRequest) else {
                                fail("E2E: expected WebArchiver to request missing file (missing.js)")
                                finishOnce()
                                return
                            }

                            // Give the archiver a moment to attempt caching (it should fail).
                            try await Task.sleep(nanoseconds: 200_000_000)
                            if let url = await archiveService.getArchiveURL(for: flow) {
                                fail("E2E: expected no cached WebArchive after 404; got \(url)")
                                finishOnce()
                                return
                            }

                            let missingCountAfterFirst = requestLog.snapshot().filter { $0 == missingRequest }.count

                            // Second presentation should still load from remote URL (no cached archive).
                            await MainActor.run {
                                window?.rootViewController = nil
                                flowViewController = nil
                                runtimeDelegate = nil

                                let vc2 = FlowViewController(flow: flow, archiveService: archiveService)
                                let campaign = makeCampaign(flowId: missingFlowId)
                                let journey = Journey(campaign: campaign, distinctId: "e2e-user-missing-2")
                                let runner2 = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
                                runner2.attach(viewController: vc2)

                                let bridge2 = FlowJourneyRunnerRuntimeBridge(runner: runner2)
                                let delegate2 = FlowJourneyRunnerRuntimeDelegate(bridge: bridge2, onMessage: nil)
                                runtimeDelegate = delegate2
                                vc2.runtimeDelegate = delegate2
                                flowViewController = vc2

                                window?.rootViewController = vc2
                                window?.makeKeyAndVisible()
                                _ = vc2.view
                            }

                            guard let vc2 = flowViewController else {
                                fail("E2E: second FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }
                            let webView2 = await MainActor.run { vc2.flowWebView }
                            guard let webView2 else {
                                fail("E2E: second FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }

                            guard (try? await waitForVmText(webView2, equals: "hello", timeoutSeconds: vmTimeoutSeconds)) == true else {
                                fail("E2E: second load did not reach runtime/view_model_init")
                                finishOnce()
                                return
                            }
                            didLoadSecond.set(true)

                            let secondMissingDeadline = Date().addingTimeInterval(missingRequestTimeoutSeconds)
                            while Date() < secondMissingDeadline {
                                let count = requestLog.snapshot().filter { $0 == missingRequest }.count
                                if count >= missingCountAfterFirst + 1 {
                                    break
                                }
                                try await Task.sleep(nanoseconds: 50_000_000)
                            }
                            let missingCountAfterSecond = requestLog.snapshot().filter { $0 == missingRequest }.count
                            guard missingCountAfterSecond >= missingCountAfterFirst + 1 else {
                                fail("E2E: expected second load to attempt missing.js again (no cache)")
                                finishOnce()
                                return
                            }

                            if let url = await archiveService.getArchiveURL(for: flow) {
                                fail("E2E: expected no cached WebArchive after second 404; got \(url)")
                                finishOnce()
                                return
                            }

                            finishOnce()
                        } catch {
                            fail("E2E setup failed: \(error)")
                            finishOnce()
                        }
                    }
                }

                expect(didLoadFirst.get()).to(beTrue())
                expect(didLoadSecond.get()).to(beTrue())
            }

            it("caches and loads a compiled WebArchive on the next load (fixture mode)") {
                guard let requestLog else { return }
                guard let batchBodies else { return }
                guard server != nil else { return }
                guard isEnabled("NUXIE_E2E_ENABLE_EXPERIMENTS", legacyKeys: ["NUXIE_E2E_PHASE2"]) else { return }
                guard isEnabled("NUXIE_E2E_ENABLE_ANALYTICS", legacyKeys: ["NUXIE_E2E_PHASE2"]) else { return }
                guard experimentAbCompiledBundleFixture != nil else {
                    fail("E2E: missing experiment-ab compiled bundle fixture")
                    return
                }

                let experimentAbFlowId = "flow_e2e_experiment_ab_\(UUID().uuidString)"
                let distinctId = "e2e-user-archive-a"
                let variantKey = "a"
                let expectedScreenId = "screen-a"

                let didLoadFirst = LockedValue(false)
                let didLoadSecond = LockedValue(false)
                let didAvoidBundlesOnSecond = LockedValue(false)
                let secondExposureProps = LockedValue<[String: Any]?>(nil)
                let expectedSecondJourneyId = LockedValue<String?>(nil)

                waitUntil(timeout: .seconds(90)) { done in
                    var finished = false

                    func finishOnce() {
                        guard !finished else { return }
                        finished = true
                        done()
                    }

                    Task {
                        do {
                            Container.shared.reset()
                            let config = NuxieConfiguration(apiKey: apiKey)
                            config.apiEndpoint = baseURL
                            config.enablePlugins = false
                            config.customStoragePath = FileManager.default.temporaryDirectory
                                .appendingPathComponent("nuxie-e2e-\(UUID().uuidString)", isDirectory: true)
                            Container.shared.sdkConfiguration.register { config }

                            let identityService = Container.shared.identityService()
                            identityService.setDistinctId(distinctId)

                            let contextBuilder = NuxieContextBuilder(identityService: identityService, configuration: config)
                            let networkQueue = NuxieNetworkQueue(
                                flushAt: 1_000_000,
                                flushIntervalSeconds: config.flushInterval,
                                maxQueueSize: config.maxQueueSize,
                                maxBatchSize: config.eventBatchSize,
                                maxRetries: config.retryCount,
                                baseRetryDelay: config.retryDelay,
                                apiClient: Container.shared.nuxieApi()
                            )
                            let eventService = Container.shared.eventService()
                            try await withTimeout(seconds: 15, operationName: "eventService.configure") {
                                try await eventService.configure(
                                    networkQueue: networkQueue,
                                    journeyService: nil,
                                    contextBuilder: contextBuilder,
                                    configuration: config
                                )
                            }

                            let profileService = Container.shared.profileService()
                            let profile = try await profileService.fetchProfile(distinctId: distinctId)
                            let gotVariant = profile.experiments?["exp-1"]?.variantKey ?? "nil"
                            guard gotVariant == variantKey else {
                                fail("E2E: expected server profile assignment variant '\(variantKey)' but got '\(gotVariant)'")
                                finishOnce()
                                return
                            }

                            let api = NuxieApi(apiKey: apiKey, baseURL: baseURL)
                            let remoteFlow = try await api.fetchFlow(flowId: experimentAbFlowId)
                            let flow = Flow(remoteFlow: remoteFlow, products: [])

                            let archiveService = FlowArchiver()
                            await archiveService.removeArchive(for: flow.id)

                            // First presentation (remote URL; caches compiled WebArchive in background).
                            await MainActor.run {
                                let vc = FlowViewController(flow: flow, archiveService: archiveService)
                                let campaign = makeCampaign(flowId: experimentAbFlowId)
                                let journey = Journey(campaign: campaign, distinctId: distinctId)
                                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
                                runner.attach(viewController: vc)

                                let bridge = FlowJourneyRunnerRuntimeBridge(runner: runner)
                                let delegate = FlowJourneyRunnerRuntimeDelegate(bridge: bridge, onMessage: nil)
                                runtimeDelegate = delegate
                                vc.runtimeDelegate = delegate
                                flowViewController = vc

                                let testWindow = UIWindow(frame: UIScreen.main.bounds)
                                testWindow.rootViewController = vc
                                testWindow.makeKeyAndVisible()
                                window = testWindow
                                _ = vc.view
                            }

                            guard let vc = flowViewController else {
                                fail("E2E: FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }
                            let webView = await MainActor.run { vc.flowWebView }
                            guard let webView else {
                                fail("E2E: FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }

                            let entryMarkerId = "screen-screen-entry-marker"
                            guard (try? await waitForElementExists(webView, elementId: entryMarkerId, timeoutSeconds: 20.0)) == true else {
                                fail("E2E: compiled web runtime did not render entry marker '\(entryMarkerId)'")
                                finishOnce()
                                return
                            }

                            _ = try? await evaluateJavaScript(webView, script: "document.getElementById('tap').click()")

                            let expectedMarkerId = "screen-\(expectedScreenId)-marker"
                            guard (try? await waitForElementExists(webView, elementId: expectedMarkerId, timeoutSeconds: 20.0)) == true else {
                                fail("E2E: experiment did not render expected marker '\(expectedMarkerId)' on first load")
                                finishOnce()
                                return
                            }
                            didLoadFirst.set(true)

                            guard (try? await waitForArchiveURL(archiveService, for: flow, timeoutSeconds: 30.0)) != nil else {
                                fail("E2E: expected compiled WebArchive to be cached after first load")
                                finishOnce()
                                return
                            }

                            let logAfterFirst = requestLog.snapshot()
                            let firstLogCount = logAfterFirst.count
                            let didFetchBundleOnFirst = logAfterFirst.contains(where: { $0.contains("/bundles/") })
                            if !didFetchBundleOnFirst {
                                fail("E2E: expected first load to fetch /bundles/* resources (compiled runtime)")
                                finishOnce()
                                return
                            }

                            // Second presentation should load from cached WebArchive (no /bundles/* network).
                            await MainActor.run {
                                window?.rootViewController = nil
                                flowViewController = nil
                                runtimeDelegate = nil

                                let vc2 = FlowViewController(flow: flow, archiveService: archiveService)
                                let campaign = makeCampaign(flowId: experimentAbFlowId)
                                let journey2 = Journey(campaign: campaign, distinctId: distinctId)
                                expectedSecondJourneyId.set(journey2.id)

                                let runner2 = FlowJourneyRunner(journey: journey2, campaign: campaign, flow: flow)
                                runner2.attach(viewController: vc2)

                                let bridge2 = FlowJourneyRunnerRuntimeBridge(runner: runner2)
                                let delegate2 = FlowJourneyRunnerRuntimeDelegate(bridge: bridge2, onMessage: nil)
                                runtimeDelegate = delegate2
                                vc2.runtimeDelegate = delegate2
                                flowViewController = vc2

                                window?.rootViewController = vc2
                                window?.makeKeyAndVisible()
                                _ = vc2.view
                            }

                            guard let vc2 = flowViewController else {
                                fail("E2E: second FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }
                            let webView2 = await MainActor.run { vc2.flowWebView }
                            guard let webView2 else {
                                fail("E2E: second FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }

                            guard (try? await waitForElementExists(webView2, elementId: entryMarkerId, timeoutSeconds: 20.0)) == true else {
                                fail("E2E: compiled web runtime did not render entry marker on cached load")
                                finishOnce()
                                return
                            }

                            _ = try? await evaluateJavaScript(webView2, script: "document.getElementById('tap').click()")

                            guard (try? await waitForElementExists(webView2, elementId: expectedMarkerId, timeoutSeconds: 20.0)) == true else {
                                fail("E2E: experiment did not render expected marker '\(expectedMarkerId)' on cached load")
                                finishOnce()
                                return
                            }
                            didLoadSecond.set(true)

                            let logAfterSecond = requestLog.snapshot()
                            if logAfterSecond.count > firstLogCount {
                                let delta = logAfterSecond[firstLogCount..<logAfterSecond.count]
                                let didFetchBundleAgain = delta.contains(where: { $0.contains("/bundles/") })
                                if didFetchBundleAgain {
                                    fail("E2E: expected cached compiled WebArchive load to avoid /bundles/* fetches; delta=\(Array(delta))")
                                    finishOnce()
                                    return
                                }
                            }
                            didAvoidBundlesOnSecond.set(true)

                            await eventService.drain()
                            let didFlush = await eventService.flushEvents()
                            if !didFlush {
                                fail("E2E: expected flushEvents() to initiate a flush (didFlush=false)")
                                finishOnce()
                                return
                            }

                            guard let journeyId2 = expectedSecondJourneyId.get() else {
                                fail("E2E: expected second journey id to be set")
                                finishOnce()
                                return
                            }
                            let bodies = batchBodies.snapshot()
                            guard let props = exposureProperties(forJourneyId: journeyId2, fromBatchBodies: bodies) else {
                                fail("E2E: expected a $experiment_exposure event for second journey in POST /batch payload; requests=\(bodies.count)")
                                finishOnce()
                                return
                            }
                            secondExposureProps.set(props)
                            finishOnce()
                        } catch {
                            fail("E2E setup failed: \(error)")
                            finishOnce()
                        }
                    }
                }

                expect(didLoadFirst.get()).to(beTrue())
                expect(didLoadSecond.get()).to(beTrue())
                expect(didAvoidBundlesOnSecond.get()).to(beTrue())

                let props = secondExposureProps.get() ?? [:]
                expect(props["experiment_key"] as? String).to(equal("exp-1"))
                expect(props["variant_key"] as? String).to(equal(variantKey))
                expect(props["campaign_id"] as? String).to(equal("camp-e2e-1"))
                expect(props["flow_id"] as? String).to(equal(experimentAbFlowId))
                expect(props["journey_id"] as? String).to(equal(expectedSecondJourneyId.get()))
                expect(props["is_holdout"] as? Bool).to(equal(false))
            }

            it("tracks $flow_shown and $flow_dismissed when dismissed via action/dismiss (fixture mode)") {
                guard let batchBodies else { return }
                guard let requestLog else { return }
                guard server != nil else { return }
                guard isEnabled("NUXIE_E2E_ENABLE_ANALYTICS", legacyKeys: ["NUXIE_E2E_PHASE2"]) else { return }

                let distinctId = "e2e-user-dismiss-1"
                let step = LockedValue("start")
                let didPresent = LockedValue(false)
                let didDismiss = LockedValue(false)
                let shownProps = LockedValue<[String: Any]?>(nil)
                let dismissedProps = LockedValue<[String: Any]?>(nil)
                let expectedJourneyId = LockedValue<String?>(nil)

                waitUntil(timeout: .seconds(60)) { done in
                    var finished = false

                    func finishOnce() {
                        guard !finished else { return }
                        finished = true
                        done()
                    }

                    Task {
                        do {
                            step.set("configure-container")
                            Container.shared.reset()
                            let config = NuxieConfiguration(apiKey: apiKey)
                            config.apiEndpoint = baseURL
                            config.enablePlugins = false
                            config.customStoragePath = FileManager.default.temporaryDirectory
                                .appendingPathComponent("nuxie-e2e-\(UUID().uuidString)", isDirectory: true)
                            Container.shared.sdkConfiguration.register { config }

                            let identityService = Container.shared.identityService()
                            identityService.setDistinctId(distinctId)

                            step.set("configure-event-service")
                            let contextBuilder = NuxieContextBuilder(identityService: identityService, configuration: config)
                            let networkQueue = NuxieNetworkQueue(
                                flushAt: 1_000_000,
                                flushIntervalSeconds: config.flushInterval,
                                maxQueueSize: config.maxQueueSize,
                                maxBatchSize: config.eventBatchSize,
                                maxRetries: config.retryCount,
                                baseRetryDelay: config.retryDelay,
                                apiClient: Container.shared.nuxieApi()
                            )
                            let eventService = Container.shared.eventService()
                            try await eventService.configure(
                                networkQueue: networkQueue,
                                journeyService: nil,
                                contextBuilder: contextBuilder,
                                configuration: config
                            )

                            let campaign = makeCampaign(flowId: flowId)
                            let journey = Journey(campaign: campaign, distinctId: distinctId)
                            expectedJourneyId.set(journey.id)

                            let sawReady = LockedValue(false)
                            let didRequestDismiss = LockedValue(false)
                            let delegate = CapturingRuntimeDelegate(onMessage: { type, _, _ in
                                if type == "runtime/ready" {
                                    sawReady.set(true)
                                }
                            }, onDismiss: { _ in
                                didRequestDismiss.set(true)
                            })
                            runtimeDelegate = delegate

                            let presentationService = await MainActor.run {
                                FlowPresentationService(windowProvider: E2ETestWindowProvider())
                            }

                            step.set("present-flow")
                            let vc = try await withTimeout(seconds: 30) {
                                try await presentationService.presentFlow(flowId, from: journey, runtimeDelegate: delegate)
                            }
                            flowViewController = vc
                            didPresent.set(true)

                            let webView = await MainActor.run { vc.flowWebView }
                            guard let webView else {
                                fail("E2E: FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }

                            step.set("wait-ready")
                            let deadline = Date().addingTimeInterval(8.0)
                            while Date() < deadline, !sawReady.get() {
                                try await Task.sleep(nanoseconds: 50_000_000)
                            }
                            guard sawReady.get() else {
                                fail("E2E: expected runtime/ready after presenting flow")
                                finishOnce()
                                return
                            }

                            step.set("send-dismiss")
                            _ = try? await evaluateJavaScript(
                                webView,
                                script: "window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge && window.webkit.messageHandlers.bridge.postMessage({ type: 'action/dismiss', payload: {} })"
                            )

                            let dismissMsgDeadline = Date().addingTimeInterval(2.0)
                            while Date() < dismissMsgDeadline, !didRequestDismiss.get() {
                                try await Task.sleep(nanoseconds: 50_000_000)
                            }
                            guard didRequestDismiss.get() else {
                                fail("E2E: expected native to receive action/dismiss via bridge")
                                finishOnce()
                                return
                            }

                            step.set("wait-dismiss")
                            let dismissDeadline = Date().addingTimeInterval(10.0)
                            while Date() < dismissDeadline {
                                if !(await presentationService.isFlowPresented) {
                                    didDismiss.set(true)
                                    break
                                }
                                try await Task.sleep(nanoseconds: 50_000_000)
                            }

                            guard didDismiss.get() else {
                                fail("E2E: expected flow to dismiss after action/dismiss")
                                finishOnce()
                                return
                            }

                            step.set("drain-events")
                            try await withTimeout(seconds: 15) {
                                await eventService.drain()
                            }
                            step.set("flush-events")
                            let didFlush = try await withTimeout(seconds: 15) {
                                await eventService.flushEvents()
                            }
                            if !didFlush {
                                fail("E2E: expected flushEvents() to initiate a flush (didFlush=false)")
                                finishOnce()
                                return
                            }

                            guard let journeyId = expectedJourneyId.get() else {
                                fail("E2E: expected journey id")
                                finishOnce()
                                return
                            }
                            step.set("assert-batch")
                            let bodies = batchBodies.snapshot()
                            guard let shown = eventProperties(
                                forEventName: JourneyEvents.flowShown,
                                forJourneyId: journeyId,
                                fromBatchBodies: bodies
                            ) else {
                                fail("E2E: expected \(JourneyEvents.flowShown) event in POST /batch payload; requests=\(bodies.count)")
                                finishOnce()
                                return
                            }
                            guard let dismissed = eventProperties(
                                forEventName: JourneyEvents.flowDismissed,
                                forJourneyId: journeyId,
                                fromBatchBodies: bodies
                            ) else {
                                fail("E2E: expected \(JourneyEvents.flowDismissed) event in POST /batch payload; requests=\(bodies.count)")
                                finishOnce()
                                return
                            }
                            shownProps.set(shown)
                            dismissedProps.set(dismissed)
                            finishOnce()
                        } catch {
                            let log = requestLog.snapshot()
                            fail("E2E setup failed (step=\(step.get())): \(error); requests=\(log)")
                            finishOnce()
                        }
                    }
                }

                if !didPresent.get() || !didDismiss.get() {
                    let log = requestLog.snapshot()
                    fail("E2E: did not complete dismissal flow (step=\(step.get())); requests=\(log)")
                }
                expect(didPresent.get()).to(beTrue())
                expect(didDismiss.get()).to(beTrue())

                let journeyId = expectedJourneyId.get()

                let shown = shownProps.get() ?? [:]
                expect(shown["journey_id"] as? String).to(equal(journeyId))
                expect(shown["campaign_id"] as? String).to(equal("camp-e2e-1"))
                expect(shown["flow_id"] as? String).to(equal(flowId))

                let dismissed = dismissedProps.get() ?? [:]
                expect(dismissed["journey_id"] as? String).to(equal(journeyId))
                expect(dismissed["campaign_id"] as? String).to(equal("camp-e2e-1"))
                expect(dismissed["flow_id"] as? String).to(equal(flowId))
            }

            func runExperimentBranchTest(variantKey: String, expectedScreenId: String) {
                guard server != nil else { return }
                guard isEnabled("NUXIE_E2E_ENABLE_EXPERIMENTS", legacyKeys: ["NUXIE_E2E_PHASE2"]) else { return }
                guard isEnabled("NUXIE_E2E_ENABLE_ANALYTICS", legacyKeys: ["NUXIE_E2E_PHASE2"]) else { return }

                let experimentAbFlowId = "flow_e2e_experiment_ab_\(UUID().uuidString)"
                let distinctId = "e2e-user-1-\(variantKey)"

                let messages = LockedArray<String>()
                let didReceiveTap = LockedValue(false)
                let didNavigateToExpected = LockedValue(false)
                let exposureProps = LockedValue<[String: Any]?>(nil)
                let expectedJourneyId = LockedValue<String?>(nil)

                waitUntil(timeout: .seconds(60)) { done in
                    var finished = false

                    func finishOnce() {
                        guard !finished else { return }
                        finished = true
                        done()
                    }

                    Task {
                        do {
                            Container.shared.reset()
                            let config = NuxieConfiguration(apiKey: apiKey)
                            config.apiEndpoint = baseURL
                            config.enablePlugins = false
                            config.customStoragePath = FileManager.default.temporaryDirectory
                                .appendingPathComponent("nuxie-e2e-\(UUID().uuidString)", isDirectory: true)
                            Container.shared.sdkConfiguration.register { config }

                            let identityService = Container.shared.identityService()
                            identityService.setDistinctId(distinctId)

                            let contextBuilder = NuxieContextBuilder(identityService: identityService, configuration: config)
                            let networkQueue = NuxieNetworkQueue(
                                flushAt: 1_000_000,
                                flushIntervalSeconds: config.flushInterval,
                                maxQueueSize: config.maxQueueSize,
                                maxBatchSize: config.eventBatchSize,
                                maxRetries: config.retryCount,
                                baseRetryDelay: config.retryDelay,
                                apiClient: Container.shared.nuxieApi()
                            )
                            let eventService = Container.shared.eventService()
                            try await eventService.configure(
                                networkQueue: networkQueue,
                                journeyService: nil,
                                contextBuilder: contextBuilder,
                                configuration: config
                            )

                            let profileService = Container.shared.profileService()
                            let profile = try await profileService.fetchProfile(distinctId: distinctId)
                            let gotVariant = profile.experiments?["exp-1"]?.variantKey ?? "nil"
                            guard gotVariant == variantKey else {
                                fail("E2E: expected server profile assignment variant '\(variantKey)' but got '\(gotVariant)'")
                                finishOnce()
                                return
                            }

                            let api = NuxieApi(apiKey: apiKey, baseURL: baseURL)
                            let remoteFlow = try await api.fetchFlow(flowId: experimentAbFlowId)
                            let flow = Flow(remoteFlow: remoteFlow, products: [])

                            let archiveService = FlowArchiver()
                            await archiveService.removeArchive(for: flow.id)

                            await MainActor.run {
                                let vc = FlowViewController(flow: flow, archiveService: archiveService)
                                let campaign = makeCampaign(flowId: experimentAbFlowId)
                                let journey = Journey(campaign: campaign, distinctId: distinctId)
                                expectedJourneyId.set(journey.id)

                                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
                                runner.attach(viewController: vc)

                                let bridge = FlowJourneyRunnerRuntimeBridge(runner: runner)
                                let delegate = FlowJourneyRunnerRuntimeDelegate(bridge: bridge) { type, payload, _ in
                                    let payloadKeys = payload.keys.sorted().joined(separator: ",")
                                    messages.append("\(type) keys=[\(payloadKeys)]")
                                    if type == "action/press" {
                                        didReceiveTap.set(true)
                                    }
                                }

                                runtimeDelegate = delegate
                                vc.runtimeDelegate = delegate
                                flowViewController = vc
                                let testWindow = UIWindow(frame: UIScreen.main.bounds)
                                testWindow.rootViewController = vc
                                testWindow.makeKeyAndVisible()
                                window = testWindow
                                _ = vc.view
                            }

                            guard let vc = flowViewController else {
                                fail("E2E: FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }
                            let webView = await MainActor.run { vc.flowWebView }
                            guard let webView else {
                                fail("E2E: FlowViewController/webView was not created")
                                finishOnce()
                                return
                            }

                            let entryMarkerId = "screen-screen-entry-marker"
                            guard (try? await waitForElementExists(webView, elementId: entryMarkerId, timeoutSeconds: 20.0)) == true else {
                                fail("E2E: compiled web runtime did not render entry marker '\(entryMarkerId)'")
                                finishOnce()
                                return
                            }

                            _ = try? await evaluateJavaScript(webView, script: "document.getElementById('tap').click()")

                            let expectedMarkerId = "screen-\(expectedScreenId)-marker"
                            if (try? await waitForElementExists(webView, elementId: expectedMarkerId, timeoutSeconds: 20.0)) == true {
                                didNavigateToExpected.set(true)
                            } else {
                                fail("E2E: experiment did not render expected marker '\(expectedMarkerId)'")
                                finishOnce()
                                return
                            }

                            await eventService.drain()
                            let didFlush = await eventService.flushEvents()
                            if !didFlush {
                                fail("E2E: expected flushEvents() to initiate a flush (didFlush=false)")
                                finishOnce()
                                return
                            }

                            let bodies = batchBodies?.snapshot() ?? []
                            guard let props = firstExposureProperties(fromBatchBodies: bodies) else {
                                fail("E2E: expected a $experiment_exposure event in POST /batch payload; requests=\(bodies.count)")
                                finishOnce()
                                return
                            }
                            exposureProps.set(props)
                            finishOnce()
                        } catch {
                            fail("E2E setup failed: \(error)")
                            finishOnce()
                        }
                    }
                }

                let messagesSnapshot = messages.snapshot()
                expect(messagesSnapshot.contains(where: { $0.hasPrefix("runtime/ready") })).to(beTrue())
                expect(messagesSnapshot.contains(where: { $0.hasPrefix("action/press") })).to(beTrue())
                expect(didReceiveTap.get()).to(beTrue())
                expect(didNavigateToExpected.get()).to(beTrue())

                let props = exposureProps.get() ?? [:]
                expect(props["experiment_key"] as? String).to(equal("exp-1"))
                expect(props["variant_key"] as? String).to(equal(variantKey))
                expect(props["campaign_id"] as? String).to(equal("camp-e2e-1"))
                expect(props["flow_id"] as? String).to(equal(experimentAbFlowId))
                expect(props["journey_id"] as? String).to(equal(expectedJourneyId.get()))
                expect(props["is_holdout"] as? Bool).to(equal(false))

                let requestSnapshot = requestLog?.snapshot() ?? []
                expect(requestSnapshot.contains("POST /profile") || requestSnapshot.contains("GET /profile")).to(beTrue())
                expect(requestSnapshot.contains("POST /batch")).to(beTrue())
            }

	            it("branches to screen-a and tracks exposure (fixture mode)") {
	                runExperimentBranchTest(variantKey: "a", expectedScreenId: "screen-a")
	            }

		            it("branches to screen-b and tracks exposure (fixture mode)") {
		                runExperimentBranchTest(variantKey: "b", expectedScreenId: "screen-b")
		            }

	                it("navigates to screen-2 then back (fixture mode)") {
	                    guard server != nil else { return }
	                    guard isEnabled("NUXIE_E2E_ENABLE_NAVIGATION") else { return }
	                    guard experimentAbCompiledBundleFixture != nil else {
	                        fail("E2E: missing compiled bundle fixture")
                        return
                    }

                    let navFlowId = "flow_e2e_nav_stack_\(UUID().uuidString)"
                    let distinctId = "e2e-user-nav-stack-1"

                    let didNavigateTo2 = LockedValue(false)
                    let didNavigateBack = LockedValue(false)

                    waitUntil(timeout: .seconds(60)) { done in
                        var finished = false

                        func finishOnce() {
                            guard !finished else { return }
                            finished = true
                            done()
                        }

                        Task {
                            do {
                                Container.shared.reset()
                                let config = NuxieConfiguration(apiKey: apiKey)
                                config.apiEndpoint = baseURL
                                config.enablePlugins = false
                                config.customStoragePath = FileManager.default.temporaryDirectory
                                    .appendingPathComponent("nuxie-e2e-\(UUID().uuidString)", isDirectory: true)
                                Container.shared.sdkConfiguration.register { config }
                                Container.shared.eventService.register { MockEventService() }

                                let api = NuxieApi(apiKey: apiKey, baseURL: baseURL)
                                let remoteFlow = try await api.fetchFlow(flowId: navFlowId)
                                let flow = Flow(remoteFlow: remoteFlow, products: [])

                                let archiveService = FlowArchiver()
                                await archiveService.removeArchive(for: flow.id)

                                await MainActor.run {
                                    let vc = FlowViewController(flow: flow, archiveService: archiveService)
                                    let campaign = makeCampaign(flowId: navFlowId)
                                    let journey = Journey(campaign: campaign, distinctId: distinctId)
                                    let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
                                    runner.attach(viewController: vc)

                                    let bridge = FlowJourneyRunnerRuntimeBridge(runner: runner)
                                    let delegate = FlowJourneyRunnerRuntimeDelegate(bridge: bridge, onMessage: nil)
                                    runtimeDelegate = delegate
                                    vc.runtimeDelegate = delegate
                                    flowViewController = vc

                                    let testWindow = UIWindow(frame: UIScreen.main.bounds)
                                    testWindow.rootViewController = vc
                                    testWindow.makeKeyAndVisible()
                                    window = testWindow
                                    _ = vc.view
                                }

                                guard let vc = flowViewController else {
                                    fail("E2E: FlowViewController/webView was not created")
                                    finishOnce()
                                    return
                                }
                                let webView = await MainActor.run { vc.flowWebView }
                                guard let webView else {
                                    fail("E2E: FlowViewController/webView was not created")
                                    finishOnce()
                                    return
                                }

                                let entryMarkerId = "screen-screen-entry-marker"
                                guard (try? await waitForElementExists(webView, elementId: entryMarkerId, timeoutSeconds: 20.0)) == true else {
                                    fail("E2E: compiled web runtime did not render entry marker '\(entryMarkerId)'")
                                    finishOnce()
                                    return
                                }

                                let to2ButtonId = "to-2"
                                guard (try? await waitForElementExists(webView, elementId: to2ButtonId, timeoutSeconds: 10.0)) == true else {
                                    fail("E2E: compiled web runtime is missing button '\(to2ButtonId)'")
                                    finishOnce()
                                    return
                                }

                                _ = try? await evaluateJavaScript(webView, script: "document.getElementById('to-2').click()")

                                let screen2MarkerId = "screen-screen-2-marker"
                                guard (try? await waitForElementExists(webView, elementId: screen2MarkerId, timeoutSeconds: 20.0)) == true else {
                                    fail("E2E: expected navigation to render marker '\(screen2MarkerId)'")
                                    finishOnce()
                                    return
                                }
                                didNavigateTo2.set(true)

                                let backButtonId = "back"
                                guard (try? await waitForElementExists(webView, elementId: backButtonId, timeoutSeconds: 10.0)) == true else {
                                    fail("E2E: compiled web runtime is missing button '\(backButtonId)'")
                                    finishOnce()
                                    return
                                }

                                _ = try? await evaluateJavaScript(webView, script: "document.getElementById('back').click()")

                                guard (try? await waitForElementExists(webView, elementId: entryMarkerId, timeoutSeconds: 20.0)) == true else {
                                    fail("E2E: expected back to render entry marker '\(entryMarkerId)'")
                                    finishOnce()
                                    return
                                }
                                didNavigateBack.set(true)

                                finishOnce()
                            } catch {
                                fail("E2E setup failed: \(error)")
                                finishOnce()
                            }
                        }
                    }

	                    expect(didNavigateTo2.get()).to(beTrue())
	                    expect(didNavigateBack.get()).to(beTrue())
	                }

	                it("executes long_press trigger (fixture mode)") {
	                    guard server != nil else { return }
	                    guard isEnabled("NUXIE_E2E_ENABLE_GESTURES") else { return }
	                    guard experimentAbCompiledBundleFixture != nil else {
	                        fail("E2E: missing compiled bundle fixture")
	                        return
	                    }

	                    let flowId = "flow_e2e_long_press_\(UUID().uuidString)"
	                    let distinctId = "e2e-user-long-press-1"

	                    let didReceiveLongPress = LockedValue(false)
	                    let didNavigate = LockedValue(false)

	                    waitUntil(timeout: .seconds(60)) { done in
	                        var finished = false

	                        func finishOnce() {
	                            guard !finished else { return }
	                            finished = true
	                            done()
	                        }

	                        Task {
	                            do {
	                                Container.shared.reset()
	                                let config = NuxieConfiguration(apiKey: apiKey)
	                                config.apiEndpoint = baseURL
	                                config.enablePlugins = false
	                                config.customStoragePath = FileManager.default.temporaryDirectory
	                                    .appendingPathComponent("nuxie-e2e-\(UUID().uuidString)", isDirectory: true)
	                                Container.shared.sdkConfiguration.register { config }
	                                Container.shared.eventService.register { MockEventService() }

	                                let api = NuxieApi(apiKey: apiKey, baseURL: baseURL)
	                                let remoteFlow = try await api.fetchFlow(flowId: flowId)
	                                let flow = Flow(remoteFlow: remoteFlow, products: [])

	                                let archiveService = FlowArchiver()
	                                await archiveService.removeArchive(for: flow.id)

	                                await MainActor.run {
	                                    let vc = FlowViewController(flow: flow, archiveService: archiveService)
	                                    let campaign = makeCampaign(flowId: flowId)
	                                    let journey = Journey(campaign: campaign, distinctId: distinctId)
	                                    let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
	                                    runner.attach(viewController: vc)

	                                    let bridge = FlowJourneyRunnerRuntimeBridge(runner: runner)
	                                    let delegate = FlowJourneyRunnerRuntimeDelegate(bridge: bridge) { type, _, _ in
	                                        if type == "action/long_press" || type == "action/longpress" {
	                                            didReceiveLongPress.set(true)
	                                        }
	                                    }
	                                    runtimeDelegate = delegate
	                                    vc.runtimeDelegate = delegate
	                                    flowViewController = vc

	                                    let testWindow = UIWindow(frame: UIScreen.main.bounds)
	                                    testWindow.rootViewController = vc
	                                    testWindow.makeKeyAndVisible()
	                                    window = testWindow
	                                    _ = vc.view
	                                }

	                                guard let vc = flowViewController else {
	                                    fail("E2E: FlowViewController/webView was not created")
	                                    finishOnce()
	                                    return
	                                }
	                                let webView = await MainActor.run { vc.flowWebView }
	                                guard let webView else {
	                                    fail("E2E: FlowViewController/webView was not created")
	                                    finishOnce()
	                                    return
	                                }

	                                let entryMarkerId = "screen-screen-entry-marker"
	                                guard (try? await waitForElementExists(webView, elementId: entryMarkerId, timeoutSeconds: 20.0)) == true else {
	                                    fail("E2E: compiled web runtime did not render entry marker '\(entryMarkerId)'")
	                                    finishOnce()
	                                    return
	                                }

	                                _ = try? await evaluateJavaScript(
	                                    webView,
	                                    script: "window.webkit.messageHandlers.bridge.postMessage({type:'action/long_press',payload:{componentId:'tap',screenId:'screen-entry'}})"
	                                )

	                                let expectedMarkerId = "screen-screen-a-marker"
	                                guard (try? await waitForElementExists(webView, elementId: expectedMarkerId, timeoutSeconds: 20.0)) == true else {
	                                    fail("E2E: expected long_press to navigate and render marker '\(expectedMarkerId)'")
	                                    finishOnce()
	                                    return
	                                }
	                                didNavigate.set(true)

	                                finishOnce()
	                            } catch {
	                                fail("E2E setup failed: \(error)")
	                                finishOnce()
	                            }
	                        }
	                    }

	                    expect(didReceiveLongPress.get()).to(beTrue())
	                    expect(didNavigate.get()).to(beTrue())
	                }

	                it("executes drag trigger (fixture mode)") {
	                    guard server != nil else { return }
	                    guard isEnabled("NUXIE_E2E_ENABLE_GESTURES") else { return }
	                    guard experimentAbCompiledBundleFixture != nil else {
	                        fail("E2E: missing compiled bundle fixture")
	                        return
	                    }

	                    let flowId = "flow_e2e_drag_\(UUID().uuidString)"
	                    let distinctId = "e2e-user-drag-1"

	                    let didReceiveDrag = LockedValue(false)
	                    let didNavigate = LockedValue(false)

	                    waitUntil(timeout: .seconds(60)) { done in
	                        var finished = false

	                        func finishOnce() {
	                            guard !finished else { return }
	                            finished = true
	                            done()
	                        }

	                        Task {
	                            do {
	                                Container.shared.reset()
	                                let config = NuxieConfiguration(apiKey: apiKey)
	                                config.apiEndpoint = baseURL
	                                config.enablePlugins = false
	                                config.customStoragePath = FileManager.default.temporaryDirectory
	                                    .appendingPathComponent("nuxie-e2e-\(UUID().uuidString)", isDirectory: true)
	                                Container.shared.sdkConfiguration.register { config }
	                                Container.shared.eventService.register { MockEventService() }

	                                let api = NuxieApi(apiKey: apiKey, baseURL: baseURL)
	                                let remoteFlow = try await api.fetchFlow(flowId: flowId)
	                                let flow = Flow(remoteFlow: remoteFlow, products: [])

	                                let archiveService = FlowArchiver()
	                                await archiveService.removeArchive(for: flow.id)

	                                await MainActor.run {
	                                    let vc = FlowViewController(flow: flow, archiveService: archiveService)
	                                    let campaign = makeCampaign(flowId: flowId)
	                                    let journey = Journey(campaign: campaign, distinctId: distinctId)
	                                    let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
	                                    runner.attach(viewController: vc)

	                                    let bridge = FlowJourneyRunnerRuntimeBridge(runner: runner)
	                                    let delegate = FlowJourneyRunnerRuntimeDelegate(bridge: bridge) { type, _, _ in
	                                        if type == "action/drag" {
	                                            didReceiveDrag.set(true)
	                                        }
	                                    }
	                                    runtimeDelegate = delegate
	                                    vc.runtimeDelegate = delegate
	                                    flowViewController = vc

	                                    let testWindow = UIWindow(frame: UIScreen.main.bounds)
	                                    testWindow.rootViewController = vc
	                                    testWindow.makeKeyAndVisible()
	                                    window = testWindow
	                                    _ = vc.view
	                                }

	                                guard let vc = flowViewController else {
	                                    fail("E2E: FlowViewController/webView was not created")
	                                    finishOnce()
	                                    return
	                                }
	                                let webView = await MainActor.run { vc.flowWebView }
	                                guard let webView else {
	                                    fail("E2E: FlowViewController/webView was not created")
	                                    finishOnce()
	                                    return
	                                }

	                                let entryMarkerId = "screen-screen-entry-marker"
	                                guard (try? await waitForElementExists(webView, elementId: entryMarkerId, timeoutSeconds: 20.0)) == true else {
	                                    fail("E2E: compiled web runtime did not render entry marker '\(entryMarkerId)'")
	                                    finishOnce()
	                                    return
	                                }

	                                _ = try? await evaluateJavaScript(
	                                    webView,
	                                    script: "window.webkit.messageHandlers.bridge.postMessage({type:'action/drag',payload:{componentId:'tap',screenId:'screen-entry'}})"
	                                )

	                                let expectedMarkerId = "screen-screen-b-marker"
	                                guard (try? await waitForElementExists(webView, elementId: expectedMarkerId, timeoutSeconds: 20.0)) == true else {
	                                    fail("E2E: expected drag to navigate and render marker '\(expectedMarkerId)'")
	                                    finishOnce()
	                                    return
	                                }
	                                didNavigate.set(true)

	                                finishOnce()
	                            } catch {
	                                fail("E2E setup failed: \(error)")
	                                finishOnce()
	                            }
	                        }
	                    }

	                    expect(didReceiveDrag.get()).to(beTrue())
	                    expect(didNavigate.get()).to(beTrue())
	                }

	                it("executes call_delegate and tracks $delegate_called (fixture mode)") {
	                    guard server != nil else { return }
	                    guard isEnabled("NUXIE_E2E_ENABLE_CALL_DELEGATE") else { return }
	                    guard experimentAbCompiledBundleFixture != nil else {
	                        fail("E2E: missing compiled bundle fixture")
	                        return
	                    }

	                    let flowId = "flow_e2e_call_delegate_\(UUID().uuidString)"
	                    let distinctId = "e2e-user-call-delegate-1"
	                    let expectedMessage = "e2e_delegate"
	                    let expectedPayloadKey = "k"
	                    let expectedPayloadValue = "v"

	                    let didReceiveTap = LockedValue(false)
	                    let didReceiveNotification = LockedValue(false)
	                    let didTrackEvent = LockedValue(false)
	                    let expectedJourneyId = LockedValue<String?>(nil)
	                    let notificationInfo = LockedValue<[AnyHashable: Any]?>(nil)
	                    let trackedProps = LockedValue<[String: Any]?>(nil)

	                    waitUntil(timeout: .seconds(60)) { done in
	                        var finished = false

	                        func finishOnce() {
	                            guard !finished else { return }
	                            finished = true
	                            done()
	                        }

	                        Task {
	                            let mockEventService = MockEventService()
	                            let observer = NotificationCenter.default.addObserver(
	                                forName: .nuxieCallDelegate,
	                                object: nil,
	                                queue: nil
	                            ) { notification in
	                                notificationInfo.set(notification.userInfo)
	                                didReceiveNotification.set(true)
	                            }
	                            defer { NotificationCenter.default.removeObserver(observer) }

	                            do {
	                                Container.shared.reset()
	                                let config = NuxieConfiguration(apiKey: apiKey)
	                                config.apiEndpoint = baseURL
	                                config.enablePlugins = false
	                                config.customStoragePath = FileManager.default.temporaryDirectory
	                                    .appendingPathComponent("nuxie-e2e-\(UUID().uuidString)", isDirectory: true)
	                                Container.shared.sdkConfiguration.register { config }
	                                Container.shared.eventService.register { mockEventService }

	                                let api = NuxieApi(apiKey: apiKey, baseURL: baseURL)
	                                let remoteFlow = try await api.fetchFlow(flowId: flowId)
	                                let flow = Flow(remoteFlow: remoteFlow, products: [])

	                                let archiveService = FlowArchiver()
	                                await archiveService.removeArchive(for: flow.id)

	                                await MainActor.run {
	                                    let vc = FlowViewController(flow: flow, archiveService: archiveService)
	                                    let campaign = makeCampaign(flowId: flowId)
	                                    let journey = Journey(campaign: campaign, distinctId: distinctId)
	                                    expectedJourneyId.set(journey.id)

	                                    let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
	                                    runner.attach(viewController: vc)

	                                    let bridge = FlowJourneyRunnerRuntimeBridge(runner: runner)
	                                    let delegate = FlowJourneyRunnerRuntimeDelegate(bridge: bridge) { type, _, _ in
	                                        if type == "action/press" {
	                                            didReceiveTap.set(true)
	                                        }
	                                    }
	                                    runtimeDelegate = delegate
	                                    vc.runtimeDelegate = delegate
	                                    flowViewController = vc

	                                    let testWindow = UIWindow(frame: UIScreen.main.bounds)
	                                    testWindow.rootViewController = vc
	                                    testWindow.makeKeyAndVisible()
	                                    window = testWindow
	                                    _ = vc.view
	                                }

	                                guard let vc = flowViewController else {
	                                    fail("E2E: FlowViewController/webView was not created")
	                                    finishOnce()
	                                    return
	                                }
	                                let webView = await MainActor.run { vc.flowWebView }
	                                guard let webView else {
	                                    fail("E2E: FlowViewController/webView was not created")
	                                    finishOnce()
	                                    return
	                                }

	                                let entryMarkerId = "screen-screen-entry-marker"
	                                guard (try? await waitForElementExists(webView, elementId: entryMarkerId, timeoutSeconds: 20.0)) == true else {
	                                    fail("E2E: compiled web runtime did not render entry marker '\(entryMarkerId)'")
	                                    finishOnce()
	                                    return
	                                }

	                                _ = try? await evaluateJavaScript(webView, script: "document.getElementById('tap').click()")

	                                let deadline = Date().addingTimeInterval(10.0)
	                                while Date() < deadline {
	                                    if didReceiveNotification.get(), trackedProps.get() != nil {
	                                        break
	                                    }

	                                    let tracked = mockEventService.trackedEvents.first { $0.name == JourneyEvents.delegateCalled }
	                                    if let props = tracked?.properties {
	                                        trackedProps.set(props)
	                                        didTrackEvent.set(true)
	                                    }

	                                    try await Task.sleep(nanoseconds: 50_000_000)
	                                }

	                                if !didReceiveNotification.get() {
	                                    fail("E2E: expected a .nuxieCallDelegate notification after tap")
	                                    finishOnce()
	                                    return
	                                }
	                                if !didTrackEvent.get() {
	                                    fail("E2E: expected \(JourneyEvents.delegateCalled) to be tracked after tap")
	                                    finishOnce()
	                                    return
	                                }

	                                finishOnce()
	                            } catch {
	                                fail("E2E setup failed: \(error)")
	                                finishOnce()
	                            }
	                        }
	                    }

	                    expect(didReceiveTap.get()).to(beTrue())
	                    expect(didReceiveNotification.get()).to(beTrue())
	                    expect(didTrackEvent.get()).to(beTrue())

	                    guard let journeyId = expectedJourneyId.get() else {
	                        fail("E2E: expected journey id")
	                        return
	                    }

	                    guard let userInfo = notificationInfo.get() else {
	                        fail("E2E: missing .nuxieCallDelegate userInfo")
	                        return
	                    }
	                    expect(userInfo["journeyId"] as? String).to(equal(journeyId))
	                    expect(userInfo["campaignId"] as? String).to(equal("camp-e2e-1"))
	                    expect(userInfo["message"] as? String).to(equal(expectedMessage))
	                    if let payload = userInfo["payload"] as? [String: Any] {
	                        expect(payload[expectedPayloadKey] as? String).to(equal(expectedPayloadValue))
	                    } else {
	                        fail("E2E: expected payload dict in .nuxieCallDelegate userInfo; userInfo=\(userInfo)")
	                    }

	                    guard let props = trackedProps.get() else {
	                        fail("E2E: missing \(JourneyEvents.delegateCalled) properties")
	                        return
	                    }
	                    expect(props["journey_id"] as? String).to(equal(journeyId))
	                    expect(props["campaign_id"] as? String).to(equal("camp-e2e-1"))
	                    expect(props["message"] as? String).to(equal(expectedMessage))
	                    if let payload = props["payload"] as? [String: Any] {
	                        expect(payload[expectedPayloadKey] as? String).to(equal(expectedPayloadValue))
	                    } else {
	                        fail("E2E: expected payload dict in \(JourneyEvents.delegateCalled) properties; props=\(props)")
	                    }
	                }

	                it("executes open_link and notifies the host (fixture mode)") {
	                    guard server != nil else { return }
	                    guard isEnabled("NUXIE_E2E_ENABLE_OPEN_LINK") else { return }
	                    guard experimentAbCompiledBundleFixture != nil else {
	                        fail("E2E: missing compiled bundle fixture")
	                        return
	                    }

	                    let flowId = "flow_e2e_open_link_\(UUID().uuidString)"
	                    let distinctId = "e2e-user-open-link-1"
	                    let expectedUrl = "https://example.com"
	                    let expectedTarget = "external"

	                    let didReceiveTap = LockedValue(false)
	                    let didReceiveNotification = LockedValue(false)
	                    let didCaptureOpenLink = LockedValue(false)
	                    let expectedJourneyId = LockedValue<String?>(nil)
	                    let notificationInfo = LockedValue<[AnyHashable: Any]?>(nil)
	                    let openLinkRequest = LockedValue<OpenLinkCapturingFlowViewController.OpenLinkRequest?>(nil)

	                    waitUntil(timeout: .seconds(60)) { done in
	                        var finished = false

	                        func finishOnce() {
	                            guard !finished else { return }
	                            finished = true
	                            done()
	                        }

	                        Task {
	                            let observer = NotificationCenter.default.addObserver(
	                                forName: .nuxieOpenLink,
	                                object: nil,
	                                queue: nil
	                            ) { notification in
	                                notificationInfo.set(notification.userInfo)
	                                didReceiveNotification.set(true)
	                            }
	                            defer { NotificationCenter.default.removeObserver(observer) }

	                            do {
	                                Container.shared.reset()
	                                let config = NuxieConfiguration(apiKey: apiKey)
	                                config.apiEndpoint = baseURL
	                                config.enablePlugins = false
	                                config.customStoragePath = FileManager.default.temporaryDirectory
	                                    .appendingPathComponent("nuxie-e2e-\(UUID().uuidString)", isDirectory: true)
	                                Container.shared.sdkConfiguration.register { config }
	                                Container.shared.eventService.register { MockEventService() }

	                                let api = NuxieApi(apiKey: apiKey, baseURL: baseURL)
	                                let remoteFlow = try await api.fetchFlow(flowId: flowId)
	                                let flow = Flow(remoteFlow: remoteFlow, products: [])

	                                let archiveService = FlowArchiver()
	                                await archiveService.removeArchive(for: flow.id)

	                                await MainActor.run {
	                                    let vc = OpenLinkCapturingFlowViewController(flow: flow, archiveService: archiveService)
	                                    let campaign = makeCampaign(flowId: flowId)
	                                    let journey = Journey(campaign: campaign, distinctId: distinctId)
	                                    expectedJourneyId.set(journey.id)

	                                    let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
	                                    runner.attach(viewController: vc)

	                                    let bridge = FlowJourneyRunnerRuntimeBridge(runner: runner)
	                                    let delegate = FlowJourneyRunnerRuntimeDelegate(bridge: bridge) { type, _, _ in
	                                        if type == "action/press" {
	                                            didReceiveTap.set(true)
	                                        }
	                                    }
	                                    runtimeDelegate = delegate
	                                    vc.runtimeDelegate = delegate
	                                    flowViewController = vc

	                                    let testWindow = UIWindow(frame: UIScreen.main.bounds)
	                                    testWindow.rootViewController = vc
	                                    testWindow.makeKeyAndVisible()
	                                    window = testWindow
	                                    _ = vc.view
	                                }

	                                guard let vc = flowViewController else {
	                                    fail("E2E: FlowViewController/webView was not created")
	                                    finishOnce()
	                                    return
	                                }
	                                let webView = await MainActor.run { vc.flowWebView }
	                                guard let webView else {
	                                    fail("E2E: FlowViewController/webView was not created")
	                                    finishOnce()
	                                    return
	                                }

	                                let entryMarkerId = "screen-screen-entry-marker"
	                                guard (try? await waitForElementExists(webView, elementId: entryMarkerId, timeoutSeconds: 20.0)) == true else {
	                                    fail("E2E: compiled web runtime did not render entry marker '\(entryMarkerId)'")
	                                    finishOnce()
	                                    return
	                                }

	                                _ = try? await evaluateJavaScript(webView, script: "document.getElementById('tap').click()")

	                                let deadline = Date().addingTimeInterval(10.0)
	                                while Date() < deadline {
	                                    if didReceiveNotification.get(), didCaptureOpenLink.get() {
	                                        break
	                                    }

	                                    let request = await MainActor.run {
	                                        (flowViewController as? OpenLinkCapturingFlowViewController)?.openLinkRequests.first
	                                    }
	                                    if let request {
	                                        openLinkRequest.set(request)
	                                        didCaptureOpenLink.set(true)
	                                    }

	                                    try await Task.sleep(nanoseconds: 50_000_000)
	                                }

	                                if !didReceiveNotification.get() {
	                                    fail("E2E: expected a .nuxieOpenLink notification after tap")
	                                    finishOnce()
	                                    return
	                                }
	                                if !didCaptureOpenLink.get() {
	                                    fail("E2E: expected FlowViewController.performOpenLink to be called after tap")
	                                    finishOnce()
	                                    return
	                                }

	                                finishOnce()
	                            } catch {
	                                fail("E2E setup failed: \(error)")
	                                finishOnce()
	                            }
	                        }
	                    }

	                    expect(didReceiveTap.get()).to(beTrue())
	                    expect(didReceiveNotification.get()).to(beTrue())
	                    expect(didCaptureOpenLink.get()).to(beTrue())

	                    guard let journeyId = expectedJourneyId.get() else {
	                        fail("E2E: expected journey id")
	                        return
	                    }

	                    guard let request = openLinkRequest.get() else {
	                        fail("E2E: missing open link request")
	                        return
	                    }
	                    expect(request.urlString).to(equal(expectedUrl))
	                    expect(request.target).to(equal(expectedTarget))

	                    guard let userInfo = notificationInfo.get() else {
	                        fail("E2E: missing .nuxieOpenLink userInfo")
	                        return
	                    }
	                    expect(userInfo["journeyId"] as? String).to(equal(journeyId))
	                    expect(userInfo["campaignId"] as? String).to(equal("camp-e2e-1"))
	                    expect(userInfo["url"] as? String).to(equal(expectedUrl))
	                    expect(userInfo["target"] as? String).to(equal(expectedTarget))
	                }

	                it("executes remote nodes and applies server context updates (fixture mode)") {
	                    guard let eventBodies else { return }
	                    guard let requestLog else { return }
	                    guard server != nil else { return }
	                    guard isEnabled("NUXIE_E2E_ENABLE_REMOTE") else { return }
                    guard experimentAbCompiledBundleFixture != nil else {
                        fail("E2E: missing compiled bundle fixture")
                        return
                    }

                    let remoteFlowId = "flow_e2e_remote_action_\(UUID().uuidString)"
                    let distinctId = "e2e-user-remote-action-1"

                    let didReceiveTap = LockedValue(false)
                    let didPostTwoNodeEvents = LockedValue(false)
                    let didApplyContextUpdate = LockedValue(false)

                    waitUntil(timeout: .seconds(60)) { done in
                        var finished = false

                        func finishOnce() {
                            guard !finished else { return }
                            finished = true
                            done()
                        }

                        Task {
                            do {
                                Container.shared.reset()
                                let config = NuxieConfiguration(apiKey: apiKey)
                                config.apiEndpoint = baseURL
                                config.enablePlugins = false
                                config.customStoragePath = FileManager.default.temporaryDirectory
                                    .appendingPathComponent("nuxie-e2e-\(UUID().uuidString)", isDirectory: true)
                                Container.shared.sdkConfiguration.register { config }

                                let identityService = Container.shared.identityService()
                                identityService.setDistinctId(distinctId)

                                let contextBuilder = NuxieContextBuilder(identityService: identityService, configuration: config)
                                let networkQueue = NuxieNetworkQueue(
                                    flushAt: 1_000_000,
                                    flushIntervalSeconds: config.flushInterval,
                                    maxQueueSize: config.maxQueueSize,
                                    maxBatchSize: config.eventBatchSize,
                                    maxRetries: config.retryCount,
                                    baseRetryDelay: config.retryDelay,
                                    apiClient: Container.shared.nuxieApi()
                                )
                                let eventService = Container.shared.eventService()
                                try await withTimeout(seconds: 15, operationName: "eventService.configure") {
                                    try await eventService.configure(
                                        networkQueue: networkQueue,
                                        journeyService: nil,
                                        contextBuilder: contextBuilder,
                                        configuration: config
                                    )
                                }

                                let api = NuxieApi(apiKey: apiKey, baseURL: baseURL)
                                let remoteFlow = try await api.fetchFlow(flowId: remoteFlowId)
                                let flow = Flow(remoteFlow: remoteFlow, products: [])

                                let archiveService = FlowArchiver()
                                await archiveService.removeArchive(for: flow.id)

                                await MainActor.run {
                                    let vc = FlowViewController(flow: flow, archiveService: archiveService)
                                    let campaign = makeCampaign(flowId: remoteFlowId)
                                    let journey = Journey(campaign: campaign, distinctId: distinctId)

                                    let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
                                    runner.attach(viewController: vc)

                                    let bridge = FlowJourneyRunnerRuntimeBridge(runner: runner)
                                    let delegate = FlowJourneyRunnerRuntimeDelegate(bridge: bridge) { type, _, _ in
                                        if type == "action/press" {
                                            didReceiveTap.set(true)
                                        }
                                    }
                                    runtimeDelegate = delegate
                                    vc.runtimeDelegate = delegate
                                    flowViewController = vc

                                    let testWindow = UIWindow(frame: UIScreen.main.bounds)
                                    testWindow.rootViewController = vc
                                    testWindow.makeKeyAndVisible()
                                    window = testWindow
                                    _ = vc.view
                                }

                                guard let vc = flowViewController else {
                                    fail("E2E: FlowViewController/webView was not created")
                                    finishOnce()
                                    return
                                }
                                let webView = await MainActor.run { vc.flowWebView }
                                guard let webView else {
                                    fail("E2E: FlowViewController/webView was not created")
                                    finishOnce()
                                    return
                                }

                                let entryMarkerId = "screen-screen-entry-marker"
                                guard (try? await waitForElementExists(webView, elementId: entryMarkerId, timeoutSeconds: 20.0)) == true else {
                                    fail("E2E: compiled web runtime did not render entry marker '\(entryMarkerId)'")
                                    finishOnce()
                                    return
                                }

                                _ = try? await evaluateJavaScript(webView, script: "document.getElementById('tap').click()")

                                let deadline = Date().addingTimeInterval(20.0)
                                while Date() < deadline {
                                    let nodeEvents = eventBodies.snapshot().compactMap { body -> [String: Any]? in
                                        guard let root = decodeMaybeGzippedJSON(body) as? [String: Any] else { return nil }
                                        guard (root["event"] as? String) == "$journey_node_executed" else { return nil }
                                        return root
                                    }

                                    if nodeEvents.count >= 2 {
                                        didPostTwoNodeEvents.set(true)

                                        let firstProps = nodeEvents[0]["properties"] as? [String: Any]
                                        let secondProps = nodeEvents[1]["properties"] as? [String: Any]
                                        let firstContext = firstProps?["context"] as? [String: Any] ?? [:]
                                        let secondContext = secondProps?["context"] as? [String: Any] ?? [:]

                                        let firstHasKey = firstContext["remote_key"] != nil
                                        let secondHasKey = (secondContext["remote_key"] as? String) == "remote_value"
                                        if !firstHasKey, secondHasKey {
                                            didApplyContextUpdate.set(true)
                                        }
                                    }

                                    if didPostTwoNodeEvents.get(), didApplyContextUpdate.get() {
                                        break
                                    }

                                    try await Task.sleep(nanoseconds: 50_000_000)
                                }

                                if !didPostTwoNodeEvents.get() || !didApplyContextUpdate.get() {
                                    let eventNames = eventBodies.snapshot().compactMap { body -> String? in
                                        guard let root = decodeMaybeGzippedJSON(body) as? [String: Any] else { return nil }
                                        return root["event"] as? String
                                    }
                                    let requestSnapshot = requestLog.snapshot()
                                    fail(
                                        "E2E: remote context update did not apply; events=\(eventNames) requests=\(requestSnapshot)"
                                    )
                                }

                                finishOnce()
                            } catch {
                                fail("E2E setup failed: \(error)")
                                finishOnce()
                            }
                        }
                    }

                    expect(didReceiveTap.get()).to(beTrue())
                    expect(didPostTwoNodeEvents.get()).to(beTrue())
                    expect(didApplyContextUpdate.get()).to(beTrue())
                }

                it("updates customer properties and sends a custom event (fixture mode)") {
                    guard let batchBodies else { return }
                    guard let requestLog else { return }
                    guard server != nil else { return }
                    guard isEnabled("NUXIE_E2E_ENABLE_CUSTOMER") else { return }
                    guard isEnabled("NUXIE_E2E_ENABLE_ANALYTICS", legacyKeys: ["NUXIE_E2E_PHASE2"]) else { return }
                    guard experimentAbCompiledBundleFixture != nil else {
                        fail("E2E: missing compiled bundle fixture")
                        return
                    }

                    let customerFlowId = "flow_e2e_customer_update_event_\(UUID().uuidString)"
                    let distinctId = "e2e-user-customer-update-1"
                    let expectedPlan = "pro"
                    let expectedEventName = "custom_event"

                    let didReceiveTap = LockedValue(false)
                    let didUpdateProperties = LockedValue(false)
                    let failureReason = LockedValue<String?>(nil)
                    let customerUpdatedProps = LockedValue<[String: Any]?>(nil)
                    let eventSentProps = LockedValue<[String: Any]?>(nil)
                    let customEventProps = LockedValue<[String: Any]?>(nil)
                    let expectedJourneyId = LockedValue<String?>(nil)

                    waitUntil(timeout: .seconds(60)) { done in
                        var finished = false

                        func finishOnce() {
                            guard !finished else { return }
                            finished = true
                            done()
                        }

                        Task {
                            do {
                                Container.shared.reset()
                                let config = NuxieConfiguration(apiKey: apiKey)
                                config.apiEndpoint = baseURL
                                config.enablePlugins = false
                                config.customStoragePath = FileManager.default.temporaryDirectory
                                    .appendingPathComponent("nuxie-e2e-\(UUID().uuidString)", isDirectory: true)
                                Container.shared.sdkConfiguration.register { config }

                                let identityService = Container.shared.identityService()
                                identityService.setDistinctId(distinctId)

                                let beforeProps = identityService.getUserProperties()
                                if beforeProps["plan"] != nil {
                                    let message = "E2E: expected plan not set before click; props=\(beforeProps)"
                                    failureReason.set(message)
                                    fail(message)
                                    finishOnce()
                                    return
                                }

                                let contextBuilder = NuxieContextBuilder(identityService: identityService, configuration: config)
                                let networkQueue = NuxieNetworkQueue(
                                    flushAt: 1_000_000,
                                    flushIntervalSeconds: config.flushInterval,
                                    maxQueueSize: config.maxQueueSize,
                                    maxBatchSize: config.eventBatchSize,
                                    maxRetries: config.retryCount,
                                    baseRetryDelay: config.retryDelay,
                                    apiClient: Container.shared.nuxieApi()
                                )
                                let eventService = Container.shared.eventService()
                                try await withTimeout(seconds: 15, operationName: "eventService.configure") {
                                    try await eventService.configure(
                                        networkQueue: networkQueue,
                                        journeyService: nil,
                                        contextBuilder: contextBuilder,
                                        configuration: config
                                    )
                                }

                                let api = NuxieApi(apiKey: apiKey, baseURL: baseURL)
                                let remoteFlow = try await api.fetchFlow(flowId: customerFlowId)
                                let flow = Flow(remoteFlow: remoteFlow, products: [])

                                let archiveService = FlowArchiver()
                                await archiveService.removeArchive(for: flow.id)

                                await MainActor.run {
                                    let vc = FlowViewController(flow: flow, archiveService: archiveService)
                                    let campaign = makeCampaign(flowId: customerFlowId)
                                    let journey = Journey(campaign: campaign, distinctId: distinctId)
                                    expectedJourneyId.set(journey.id)

                                    let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
                                    runner.attach(viewController: vc)

                                    let bridge = FlowJourneyRunnerRuntimeBridge(runner: runner)
                                    let delegate = FlowJourneyRunnerRuntimeDelegate(bridge: bridge) { type, _, _ in
                                        if type == "action/press" {
                                            didReceiveTap.set(true)
                                        }
                                    }
                                    runtimeDelegate = delegate
                                    vc.runtimeDelegate = delegate
                                    flowViewController = vc

                                    let testWindow = UIWindow(frame: UIScreen.main.bounds)
                                    testWindow.rootViewController = vc
                                    testWindow.makeKeyAndVisible()
                                    window = testWindow
                                    _ = vc.view
                                }

                                guard let vc = flowViewController else {
                                    fail("E2E: FlowViewController/webView was not created")
                                    finishOnce()
                                    return
                                }
                                let webView = await MainActor.run { vc.flowWebView }
                                guard let webView else {
                                    fail("E2E: FlowViewController/webView was not created")
                                    finishOnce()
                                    return
                                }

                                let entryMarkerId = "screen-screen-entry-marker"
                                guard (try? await waitForElementExists(webView, elementId: entryMarkerId, timeoutSeconds: 20.0)) == true else {
                                    fail("E2E: compiled web runtime did not render entry marker '\(entryMarkerId)'")
                                    finishOnce()
                                    return
                                }

                                _ = try? await evaluateJavaScript(webView, script: "document.getElementById('tap').click()")

                                let propertiesDeadline = Date().addingTimeInterval(5.0)
                                while Date() < propertiesDeadline {
                                    let props = identityService.getUserProperties()
                                    if (props["plan"] as? String) == expectedPlan {
                                        didUpdateProperties.set(true)
                                        break
                                    }
                                    try await Task.sleep(nanoseconds: 50_000_000)
                                }
                                if !didUpdateProperties.get() {
                                    fail("E2E: expected update_customer to write plan='\(expectedPlan)' into identity properties")
                                    finishOnce()
                                    return
                                }

                                await eventService.drain()
                                let queuedDeadline = Date().addingTimeInterval(5.0)
                                var queuedCount = await eventService.getQueuedEventCount()
                                while queuedCount == 0, Date() < queuedDeadline {
                                    try await Task.sleep(nanoseconds: 50_000_000)
                                    queuedCount = await eventService.getQueuedEventCount()
                                }
                                if queuedCount == 0 {
                                    let recentNames = await eventService.getRecentEvents(limit: 20).map(\.name)
                                    let requests = requestLog.snapshot()
                                    let message = "E2E: expected update_customer/send_event to enqueue events; queued=0 recent=\(recentNames) requests=\(requests)"
                                    failureReason.set(message)
                                    fail(message)
                                    finishOnce()
                                    return
                                }

                                _ = await eventService.flushEvents()

                                let batchDeadline = Date().addingTimeInterval(10.0)
                                while Date() < batchDeadline {
                                    if !batchBodies.snapshot().isEmpty { break }
                                    try await Task.sleep(nanoseconds: 50_000_000)
                                }
                                let bodies = batchBodies.snapshot()
                                if bodies.isEmpty {
                                    let recentNames = await eventService.getRecentEvents(limit: 20).map(\.name)
                                    let queued = await eventService.getQueuedEventCount()
                                    let requests = requestLog.snapshot()
                                    let message = "E2E: expected POST /batch after flush; queued=\(queued) recent=\(recentNames) requests=\(requests)"
                                    failureReason.set(message)
                                    fail(message)
                                    finishOnce()
                                    return
                                }

                                guard let journeyId = expectedJourneyId.get() else {
                                    fail("E2E: expected journey id")
                                    finishOnce()
                                    return
                                }

                                guard let customerProps = eventProperties(
                                    forEventName: JourneyEvents.customerUpdated,
                                    forJourneyId: journeyId,
                                    fromBatchBodies: bodies
                                ) else {
                                    let message = "E2E: expected \(JourneyEvents.customerUpdated) event in POST /batch payload; requests=\(bodies.count)"
                                    failureReason.set(message)
                                    fail(message)
                                    finishOnce()
                                    return
                                }
                                customerUpdatedProps.set(customerProps)

                                guard let sentProps = eventProperties(
                                    forEventName: JourneyEvents.eventSent,
                                    forJourneyId: journeyId,
                                    fromBatchBodies: bodies
                                ) else {
                                    let message = "E2E: expected \(JourneyEvents.eventSent) event in POST /batch payload; requests=\(bodies.count)"
                                    failureReason.set(message)
                                    fail(message)
                                    finishOnce()
                                    return
                                }
                                eventSentProps.set(sentProps)

                                guard let customProps = customEventProperties(
                                    forEventName: expectedEventName,
                                    forJourneyId: journeyId,
                                    fromBatchBodies: bodies
                                ) else {
                                    let message = "E2E: expected '\(expectedEventName)' event in POST /batch payload; requests=\(bodies.count)"
                                    failureReason.set(message)
                                    fail(message)
                                    finishOnce()
                                    return
                                }
                                customEventProps.set(customProps)

                                finishOnce()
                            } catch {
                                let requests = requestLog.snapshot()
                                fail("E2E setup failed: \(error); requests=\(requests)")
                                finishOnce()
                            }
                        }
                    }

                    if failureReason.get() != nil {
                        return
                    }

                    expect(didReceiveTap.get()).to(beTrue())
                    expect(didUpdateProperties.get()).to(beTrue())

                    guard let journeyId = expectedJourneyId.get() else {
                        fail("E2E: expected journey id")
                        return
                    }
                    guard let customerProps = customerUpdatedProps.get() else {
                        fail("E2E: missing \(JourneyEvents.customerUpdated) properties")
                        return
                    }
                    if let updated = customerProps["attributes_updated"] as? [String] {
                        expect(updated).to(contain("plan"))
                    } else if let updatedAny = customerProps["attributes_updated"] as? [Any] {
                        let updated = updatedAny.compactMap { $0 as? String }
                        expect(updated).to(contain("plan"))
                    } else {
                        fail("E2E: expected attributes_updated list in \(JourneyEvents.customerUpdated) properties; props=\(customerProps)")
                    }
                    expect(customerProps["journey_id"] as? String).to(equal(journeyId))
                    expect(customerProps["campaign_id"] as? String).to(equal("camp-e2e-1"))

                    guard let sentProps = eventSentProps.get() else {
                        fail("E2E: missing \(JourneyEvents.eventSent) properties")
                        return
                    }
                    expect(sentProps["journey_id"] as? String).to(equal(journeyId))
                    expect(sentProps["campaign_id"] as? String).to(equal("camp-e2e-1"))
                    expect(sentProps["event_name"] as? String).to(equal(expectedEventName))
                    if let evProps = sentProps["event_properties"] as? [String: Any] {
                        expect(evProps["k"] as? String).to(equal("v"))
                    } else {
                        fail("E2E: expected event_properties dict in \(JourneyEvents.eventSent) properties; props=\(sentProps)")
                    }

                    guard let customProps = customEventProps.get() else {
                        fail("E2E: missing \(expectedEventName) properties")
                        return
                    }
                    expect(customProps["journeyId"] as? String).to(equal(journeyId))
                    expect(customProps["campaignId"] as? String).to(equal("camp-e2e-1"))
                    expect(customProps["screenId"] as? String).to(equal("screen-entry"))
                    expect(customProps["k"] as? String).to(equal("v"))

                    let requestSnapshot = requestLog.snapshot()
                    expect(requestSnapshot.contains("POST /batch")).to(beTrue())
                }

		            it("executes purchase (tap→purchase) and confirms host/web + backend sync (fixture mode)") {
		                guard let requestLog else { return }
		                guard let eventBodies else { return }
		                guard server != nil else { return }
		                guard isEnabled("NUXIE_E2E_ENABLE_PURCHASES") else { return }
	                guard experimentAbCompiledBundleFixture != nil else {
	                    fail("E2E: missing compiled bundle fixture")
	                    return
	                }

	                let purchaseFlowId = "flow_e2e_purchase_\(UUID().uuidString)"
	                let distinctId = "e2e-user-purchase-1"
	                let productId = "pro"

	                let messages = LockedArray<String>()
	                let didReceiveTap = LockedValue(false)
	                let didSeeUiSuccess = LockedValue(false)
	                let didSeeConfirmed = LockedValue(false)
	                let didPostPurchase = LockedValue(false)
	                let didPostPurchaseCompletedEvent = LockedValue(false)
	                let didPostPurchaseSyncedEvent = LockedValue(false)

	                waitUntil(timeout: .seconds(90)) { done in
	                    var finished = false

	                    func finishOnce() {
	                        guard !finished else { return }
	                        finished = true
	                        done()
	                    }

	                    func shutdownAndFinish(_ message: String? = nil) async {
	                        await NuxieSDK.shared.shutdown()
	                        if let message {
	                            fail(message)
	                        }
	                        finishOnce()
	                    }

	                    Task {
	                        do {
	                            // Ensure we can setup the singleton SDK even if another test previously configured it.
	                            await NuxieSDK.shared.shutdown()
	                            Container.shared.reset()

	                            let storagePath = FileManager.default.temporaryDirectory
	                                .appendingPathComponent("nuxie-e2e-\(UUID().uuidString)", isDirectory: true)

	                            let config = NuxieConfiguration(apiKey: apiKey)
	                            config.apiEndpoint = baseURL
	                            config.enablePlugins = false
	                            config.customStoragePath = storagePath

	                            let purchaseDelegate = MockPurchaseDelegate()
	                            purchaseDelegate.simulatedDelay = 0
	                            purchaseDelegate.purchaseOutcomeOverride = PurchaseOutcome(
	                                result: .success,
	                                transactionJws: "test-jws",
	                                transactionId: "tx-1",
	                                originalTransactionId: "otx-1",
	                                productId: productId
	                            )
	                            config.purchaseDelegate = purchaseDelegate

	                            try NuxieSDK.shared.setup(with: config)

	                            let identityService = Container.shared.identityService()
	                            identityService.setDistinctId(distinctId)

	                            let productService = MockProductService()
	                            productService.mockProducts = [
	                                MockStoreProduct(
	                                    id: productId,
	                                    displayName: "Pro",
	                                    price: 9.99,
	                                    displayPrice: "$9.99"
	                                )
	                            ]
	                            Container.shared.productService.register { productService }

	                            // Wait for the SDK-configured event pipeline to be ready; purchase lifecycle events use /event.
	                            _ = await Container.shared.eventService().getRecentEvents(limit: 1)

	                            let api = NuxieApi(apiKey: apiKey, baseURL: baseURL)
	                            let remoteFlow = try await api.fetchFlow(flowId: purchaseFlowId)
	                            let flow = Flow(remoteFlow: remoteFlow, products: [])

	                            let archiveService = FlowArchiver()
	                            await archiveService.removeArchive(for: flow.id)

	                            await MainActor.run {
	                                let vc = FlowViewController(flow: flow, archiveService: archiveService)
	                                let campaign = makeCampaign(flowId: purchaseFlowId)
	                                let journey = Journey(campaign: campaign, distinctId: distinctId)

	                                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
	                                runner.attach(viewController: vc)

	                                let bridge = FlowJourneyRunnerRuntimeBridge(runner: runner)
	                                let delegate = FlowJourneyRunnerRuntimeDelegate(bridge: bridge) { type, payload, _ in
	                                    let payloadKeys = payload.keys.sorted().joined(separator: ",")
	                                    messages.append("\(type) keys=[\(payloadKeys)]")
	                                    if type == "action/press" {
	                                        didReceiveTap.set(true)
	                                    }
	                                }
	                                runtimeDelegate = delegate
	                                vc.runtimeDelegate = delegate
	                                flowViewController = vc

	                                let testWindow = UIWindow(frame: UIScreen.main.bounds)
	                                testWindow.rootViewController = vc
	                                testWindow.makeKeyAndVisible()
	                                window = testWindow
	                                _ = vc.view
	                            }

	                            guard let vc = flowViewController else {
	                                await shutdownAndFinish("E2E: FlowViewController/webView was not created")
	                                return
	                            }
	                            let webView = await MainActor.run { vc.flowWebView }
	                            guard let webView else {
	                                await shutdownAndFinish("E2E: FlowViewController/webView was not created")
	                                return
	                            }

	                            let entryMarkerId = "screen-screen-entry-marker"
	                            guard (try? await waitForElementExists(webView, elementId: entryMarkerId, timeoutSeconds: 20.0)) == true else {
	                                await shutdownAndFinish(
	                                    "E2E: compiled web runtime did not render entry marker '\(entryMarkerId)'"
	                                )
	                                return
	                            }

	                            let quotedProductId = jsStringLiteral(productId)
	                            let installHostMessageLogger = """
	                            (function(){
	                              try {
	                                window.__hostMessages = window.__hostMessages || [];
	                                function wrap(){
	                                  if (!window.nuxie || typeof window.nuxie._handleHostMessage !== 'function') return false;
	                                  if (window.nuxie._handleHostMessage && window.nuxie._handleHostMessage.__e2eWrapped) return true;
	                                  var original = window.nuxie._handleHostMessage;
	                                  function wrapped(envelope){
	                                    try { window.__hostMessages.push(envelope); } catch (e) {}
	                                    return original.apply(this, arguments);
	                                  }
	                                  wrapped.__e2eWrapped = true;
	                                  window.nuxie._handleHostMessage = wrapped;
	                                  return true;
	                                }
	                                if (wrap()) return true;
	                                if (!window.__e2eHostWrapTimer) {
	                                  window.__e2eHostWrapTimer = setInterval(function(){
	                                    if (wrap()) { clearInterval(window.__e2eHostWrapTimer); window.__e2eHostWrapTimer = null; }
	                                  }, 50);
	                                }
	                              } catch (e) {}
	                              return false;
	                            })();
	                            """
	                            _ = try? await evaluateJavaScript(webView, script: installHostMessageLogger)

	                            _ = try? await evaluateJavaScript(webView, script: "document.getElementById('tap').click()")

	                            let deadline = Date().addingTimeInterval(30.0)
	                            while Date() < deadline {
	                                let checkHostMessages = """
	                                (function(){
	                                  try {
	                                    var msgs = window.__hostMessages || [];
	                                    var hasUi = msgs.some(function(m){
	                                      return m && m.type === "purchase_ui_success" && m.payload && m.payload.productId === \(quotedProductId);
	                                    });
	                                    var hasConfirmed = msgs.some(function(m){
	                                      return m && m.type === "purchase_confirmed" && m.payload && m.payload.productId === \(quotedProductId);
	                                    });
	                                    return { uiSuccess: hasUi, confirmed: hasConfirmed, count: msgs.length };
	                                  } catch (e) { return { uiSuccess: false, confirmed: false, count: -1 }; }
	                                })();
	                                """
	                                if let dict = (try? await evaluateJavaScript(webView, script: checkHostMessages)) as? [String: Any] {
	                                    if (dict["uiSuccess"] as? Bool) == true { didSeeUiSuccess.set(true) }
	                                    if (dict["confirmed"] as? Bool) == true { didSeeConfirmed.set(true) }
	                                }

	                                let requests = requestLog.snapshot()
	                                if requests.contains("POST /purchase") {
	                                    didPostPurchase.set(true)
	                                }

	                                let names = eventBodies.snapshot().compactMap { body -> String? in
	                                    guard let root = decodeMaybeGzippedJSON(body) as? [String: Any] else { return nil }
	                                    return root["event"] as? String
	                                }
	                                if names.contains(SystemEventNames.purchaseCompleted) {
	                                    didPostPurchaseCompletedEvent.set(true)
	                                }
	                                if names.contains("$purchase_synced") {
	                                    didPostPurchaseSyncedEvent.set(true)
	                                }

	                                if
	                                    didSeeUiSuccess.get(),
	                                    didSeeConfirmed.get(),
	                                    didPostPurchase.get(),
	                                    didPostPurchaseCompletedEvent.get(),
	                                    didPostPurchaseSyncedEvent.get()
	                                {
	                                    break
	                                }

	                                try await Task.sleep(nanoseconds: 50_000_000)
	                            }

	                            if
	                                !didSeeUiSuccess.get()
	                                || !didSeeConfirmed.get()
	                                || !didPostPurchase.get()
	                                || !didPostPurchaseCompletedEvent.get()
	                                || !didPostPurchaseSyncedEvent.get()
	                            {
	                                let hostTypesScript = """
	                                (function(){
	                                  try {
	                                    return (window.__hostMessages || []).map(function(m){ return m && m.type; }).join(",");
	                                  } catch (e) { return ""; }
	                                })();
	                                """
	                                let hostTypes = (try? await evaluateJavaScript(webView, script: hostTypesScript)) as? String ?? ""
	                                let eventNames = eventBodies.snapshot().compactMap { body -> String? in
	                                    guard let root = decodeMaybeGzippedJSON(body) as? [String: Any] else { return nil }
	                                    return root["event"] as? String
	                                }
	                                let requestSnapshot = requestLog.snapshot()
	                                await shutdownAndFinish(
	                                    "E2E: purchase did not complete; host=[\(hostTypes)] events=\(eventNames) requests=\(requestSnapshot) messages=\(messages.snapshot())"
	                                )
	                                return
	                            }

	                            await shutdownAndFinish()
	                        } catch {
	                            await shutdownAndFinish("E2E setup failed: \(error)")
	                        }
	                    }
	                }

	                expect(didReceiveTap.get()).to(beTrue())
	                expect(didSeeUiSuccess.get()).to(beTrue())
	                expect(didSeeConfirmed.get()).to(beTrue())
	                expect(didPostPurchase.get()).to(beTrue())
	                expect(didPostPurchaseCompletedEvent.get()).to(beTrue())
	                expect(didPostPurchaseSyncedEvent.get()).to(beTrue())
	            }

	            it("executes restore (tap→restore) and confirms host/web + analytics (fixture mode)") {
	                guard let eventBodies else { return }
	                guard server != nil else { return }
	                guard isEnabled("NUXIE_E2E_ENABLE_PURCHASES") else { return }
	                guard experimentAbCompiledBundleFixture != nil else {
	                    fail("E2E: missing compiled bundle fixture")
	                    return
	                }

	                let restoreFlowId = "flow_e2e_restore_\(UUID().uuidString)"
	                let distinctId = "e2e-user-restore-1"

	                let messages = LockedArray<String>()
	                let didReceiveTap = LockedValue(false)
	                let didSeeRestoreSuccess = LockedValue(false)
	                let didPostRestoreCompletedEvent = LockedValue(false)

	                waitUntil(timeout: .seconds(90)) { done in
	                    var finished = false

	                    func finishOnce() {
	                        guard !finished else { return }
	                        finished = true
	                        done()
	                    }

	                    func shutdownAndFinish(_ message: String? = nil) async {
	                        await NuxieSDK.shared.shutdown()
	                        if let message {
	                            fail(message)
	                        }
	                        finishOnce()
	                    }

	                    Task {
	                        do {
	                            await NuxieSDK.shared.shutdown()
	                            Container.shared.reset()

	                            let storagePath = FileManager.default.temporaryDirectory
	                                .appendingPathComponent("nuxie-e2e-\(UUID().uuidString)", isDirectory: true)

	                            let config = NuxieConfiguration(apiKey: apiKey)
	                            config.apiEndpoint = baseURL
	                            config.enablePlugins = false
	                            config.customStoragePath = storagePath

	                            let purchaseDelegate = MockPurchaseDelegate()
	                            purchaseDelegate.simulatedDelay = 0
	                            purchaseDelegate.restoreResult = .success(restoredCount: 1)
	                            config.purchaseDelegate = purchaseDelegate

	                            try NuxieSDK.shared.setup(with: config)

	                            let identityService = Container.shared.identityService()
	                            identityService.setDistinctId(distinctId)

	                            _ = await Container.shared.eventService().getRecentEvents(limit: 1)

	                            let api = NuxieApi(apiKey: apiKey, baseURL: baseURL)
	                            let remoteFlow = try await api.fetchFlow(flowId: restoreFlowId)
	                            let flow = Flow(remoteFlow: remoteFlow, products: [])

	                            let archiveService = FlowArchiver()
	                            await archiveService.removeArchive(for: flow.id)

	                            await MainActor.run {
	                                let vc = FlowViewController(flow: flow, archiveService: archiveService)
	                                let campaign = makeCampaign(flowId: restoreFlowId)
	                                let journey = Journey(campaign: campaign, distinctId: distinctId)

	                                let runner = FlowJourneyRunner(journey: journey, campaign: campaign, flow: flow)
	                                runner.attach(viewController: vc)

	                                let bridge = FlowJourneyRunnerRuntimeBridge(runner: runner)
	                                let delegate = FlowJourneyRunnerRuntimeDelegate(bridge: bridge) { type, payload, _ in
	                                    let payloadKeys = payload.keys.sorted().joined(separator: ",")
	                                    messages.append("\(type) keys=[\(payloadKeys)]")
	                                    if type == "action/press" {
	                                        didReceiveTap.set(true)
	                                    }
	                                }
	                                runtimeDelegate = delegate
	                                vc.runtimeDelegate = delegate
	                                flowViewController = vc

	                                let testWindow = UIWindow(frame: UIScreen.main.bounds)
	                                testWindow.rootViewController = vc
	                                testWindow.makeKeyAndVisible()
	                                window = testWindow
	                                _ = vc.view
	                            }

	                            guard let vc = flowViewController else {
	                                await shutdownAndFinish("E2E: FlowViewController/webView was not created")
	                                return
	                            }
	                            let webView = await MainActor.run { vc.flowWebView }
	                            guard let webView else {
	                                await shutdownAndFinish("E2E: FlowViewController/webView was not created")
	                                return
	                            }

	                            let entryMarkerId = "screen-screen-entry-marker"
	                            guard (try? await waitForElementExists(webView, elementId: entryMarkerId, timeoutSeconds: 20.0)) == true else {
	                                await shutdownAndFinish(
	                                    "E2E: compiled web runtime did not render entry marker '\(entryMarkerId)'"
	                                )
	                                return
	                            }

	                            let installHostMessageLogger = """
	                            (function(){
	                              try {
	                                window.__hostMessages = window.__hostMessages || [];
	                                function wrap(){
	                                  if (!window.nuxie || typeof window.nuxie._handleHostMessage !== 'function') return false;
	                                  if (window.nuxie._handleHostMessage && window.nuxie._handleHostMessage.__e2eWrapped) return true;
	                                  var original = window.nuxie._handleHostMessage;
	                                  function wrapped(envelope){
	                                    try { window.__hostMessages.push(envelope); } catch (e) {}
	                                    return original.apply(this, arguments);
	                                  }
	                                  wrapped.__e2eWrapped = true;
	                                  window.nuxie._handleHostMessage = wrapped;
	                                  return true;
	                                }
	                                if (wrap()) return true;
	                                if (!window.__e2eHostWrapTimer) {
	                                  window.__e2eHostWrapTimer = setInterval(function(){
	                                    if (wrap()) { clearInterval(window.__e2eHostWrapTimer); window.__e2eHostWrapTimer = null; }
	                                  }, 50);
	                                }
	                              } catch (e) {}
	                              return false;
	                            })();
	                            """
	                            _ = try? await evaluateJavaScript(webView, script: installHostMessageLogger)

	                            _ = try? await evaluateJavaScript(webView, script: "document.getElementById('tap').click()")

	                            let deadline = Date().addingTimeInterval(20.0)
	                            while Date() < deadline {
	                                let checkHostMessages = """
	                                (function(){
	                                  try {
	                                    var msgs = window.__hostMessages || [];
	                                    var hasRestore = msgs.some(function(m){
	                                      return m && m.type === "restore_success";
	                                    });
	                                    return { restoreSuccess: hasRestore, count: msgs.length };
	                                  } catch (e) { return { restoreSuccess: false, count: -1 }; }
	                                })();
	                                """
	                                if let dict = (try? await evaluateJavaScript(webView, script: checkHostMessages)) as? [String: Any] {
	                                    if (dict["restoreSuccess"] as? Bool) == true { didSeeRestoreSuccess.set(true) }
	                                }

	                                let bodies = eventBodies.snapshot()
	                                for body in bodies {
	                                    guard let root = decodeMaybeGzippedJSON(body) as? [String: Any] else { continue }
	                                    guard (root["event"] as? String) == SystemEventNames.restoreCompleted else { continue }
	                                    guard (root["distinct_id"] as? String) == distinctId else { continue }
	                                    if let props = root["properties"] as? [String: Any] {
	                                        let value = props["restored_count"]
	                                        if (value as? Int) == 1 || (value as? Double) == 1 {
	                                            didPostRestoreCompletedEvent.set(true)
	                                        }
	                                    }
	                                }

	                                if didSeeRestoreSuccess.get(), didPostRestoreCompletedEvent.get() {
	                                    break
	                                }

	                                try await Task.sleep(nanoseconds: 50_000_000)
	                            }

	                            if !didSeeRestoreSuccess.get() || !didPostRestoreCompletedEvent.get() {
	                                let hostTypesScript = """
	                                (function(){
	                                  try {
	                                    return (window.__hostMessages || []).map(function(m){ return m && m.type; }).join(",");
	                                  } catch (e) { return ""; }
	                                })();
	                                """
	                                let hostTypes = (try? await evaluateJavaScript(webView, script: hostTypesScript)) as? String ?? ""
	                                let eventNames = eventBodies.snapshot().compactMap { body -> String? in
	                                    guard let root = decodeMaybeGzippedJSON(body) as? [String: Any] else { return nil }
	                                    return root["event"] as? String
	                                }
	                                await shutdownAndFinish(
	                                    "E2E: restore did not complete; host=[\(hostTypes)] events=\(eventNames) messages=\(messages.snapshot())"
	                                )
	                                return
	                            }

	                            await shutdownAndFinish()
	                        } catch {
	                            await shutdownAndFinish("E2E setup failed: \(error)")
	                        }
	                    }
	                }

	                expect(didReceiveTap.get()).to(beTrue())
	                expect(didSeeRestoreSuccess.get()).to(beTrue())
	                expect(didPostRestoreCompletedEvent.get()).to(beTrue())
	            }
	            }
	        }
	    }

// MARK: - Test helpers

private final class CapturingRuntimeDelegate: FlowRuntimeDelegate {
    typealias OnMessage = (_ type: String, _ payload: [String: Any], _ id: String?) -> Void
    typealias OnDismiss = (_ reason: CloseReason) -> Void
    private let onMessage: OnMessage
    private let onDismiss: OnDismiss?

    init(onMessage: @escaping OnMessage, onDismiss: OnDismiss? = nil) {
        self.onMessage = onMessage
        self.onDismiss = onDismiss
    }

    func flowViewController(_ controller: FlowViewController, didReceiveRuntimeMessage type: String, payload: [String: Any], id: String?) {
        onMessage(type, payload, id)
    }

    func flowViewController(
        _ controller: FlowViewController,
        didSendRuntimeMessage type: String,
        payload: [String : Any],
        replyTo: String?
    ) {
        onMessage(type, payload, replyTo)
    }

    func flowViewControllerDidRequestDismiss(_ controller: FlowViewController, reason: CloseReason) {
        onDismiss?(reason)
    }
}

private final class OpenLinkCapturingFlowViewController: FlowViewController {
    struct OpenLinkRequest {
        let urlString: String
        let target: String?
    }

    private(set) var openLinkRequests: [OpenLinkRequest] = []

    override func performOpenLink(urlString: String, target: String? = nil) {
        openLinkRequests.append(OpenLinkRequest(urlString: urlString, target: target))
    }
}

private final class LockedArray<T> {
    private let lock = NSLock()
    private(set) var values: [T] = []

    func append(_ value: T) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [T] {
        lock.lock()
        let snapshot = values
        lock.unlock()
        return snapshot
    }
}

private final class LockedValue<T> {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func set(_ value: T) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> T {
        lock.lock()
        let current = value
        lock.unlock()
        return current
    }
}

private struct ParityRendererSelection {
    let expectedRendererBackend: String
    let supportedCapabilities: Set<String>
    let preferredCompilerBackends: [String]
    let renderableCompilerBackends: Set<String>
}

private func parityRendererSelectionFromEnvironment() -> ParityRendererSelection {
    let env = ProcessInfo.processInfo.environment
    let rawRenderer = env["NUXIE_E2E_PARITY_RENDERER"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

    if rawRenderer == "rive" {
        return ParityRendererSelection(
            expectedRendererBackend: "rive",
            supportedCapabilities: [
                "renderer.react.webview.v1",
                "renderer.rive.native.v1",
            ],
            preferredCompilerBackends: ["rive", "react"],
            renderableCompilerBackends: ["react", "rive"]
        )
    }

    return ParityRendererSelection(
        expectedRendererBackend: "react",
        supportedCapabilities: ["renderer.react.webview.v1"],
        preferredCompilerBackends: ["react", "rive"],
        renderableCompilerBackends: ["react"]
    )
}

private func isEnabled(_ key: String, legacyKeys: [String] = []) -> Bool {
    let env = ProcessInfo.processInfo.environment
    if env[key] == "0" { return false }
    for legacyKey in legacyKeys {
        if env[legacyKey] == "0" { return false }
    }
    return true
}

private func decodeMaybeGzippedJSON(_ data: Data) -> Any? {
    let decoded: Data
    if data.isGzipped, let unzipped = try? data.gunzipped() {
        decoded = unzipped
    } else {
        decoded = data
    }
    return try? JSONSerialization.jsonObject(with: decoded, options: [])
}

private func firstExposureProperties(fromBatchBodies bodies: [Data]) -> [String: Any]? {
    for body in bodies {
        guard let root = decodeMaybeGzippedJSON(body) as? [String: Any] else { continue }
        guard let batch = root["batch"] as? [[String: Any]] else { continue }
        for item in batch {
            guard (item["event"] as? String) == JourneyEvents.experimentExposure else { continue }
            return item["properties"] as? [String: Any]
        }
    }
    return nil
}

private func exposureProperties(forJourneyId journeyId: String, fromBatchBodies bodies: [Data]) -> [String: Any]? {
    for body in bodies {
        guard let root = decodeMaybeGzippedJSON(body) as? [String: Any] else { continue }
        guard let batch = root["batch"] as? [[String: Any]] else { continue }
        for item in batch {
            guard (item["event"] as? String) == JourneyEvents.experimentExposure else { continue }
            guard let props = item["properties"] as? [String: Any] else { continue }
            guard (props["journey_id"] as? String) == journeyId else { continue }
            return props
        }
    }
    return nil
}

private func eventProperties(
    forEventName eventName: String,
    forJourneyId journeyId: String,
    fromBatchBodies bodies: [Data]
) -> [String: Any]? {
    for body in bodies {
        guard let root = decodeMaybeGzippedJSON(body) as? [String: Any] else { continue }
        guard let batch = root["batch"] as? [[String: Any]] else { continue }
        for item in batch {
            guard (item["event"] as? String) == eventName else { continue }
            guard let props = item["properties"] as? [String: Any] else { continue }
            guard (props["journey_id"] as? String) == journeyId else { continue }
            return props
        }
    }
    return nil
}

private func customEventProperties(
    forEventName eventName: String,
    forJourneyId journeyId: String,
    fromBatchBodies bodies: [Data]
) -> [String: Any]? {
    for body in bodies {
        guard let root = decodeMaybeGzippedJSON(body) as? [String: Any] else { continue }
        guard let batch = root["batch"] as? [[String: Any]] else { continue }
        for item in batch {
            guard (item["event"] as? String) == eventName else { continue }
            guard let props = item["properties"] as? [String: Any] else { continue }
            guard (props["journeyId"] as? String) == journeyId else { continue }
            return props
        }
    }
    return nil
}

@MainActor
private final class E2ETestWindowProvider: WindowProviderProtocol {
    func canPresentWindow() -> Bool { true }

    func createPresentationWindow() -> PresentationWindowProtocol? {
        E2ETestPresentationWindow()
    }
}

@MainActor
private final class E2ETestPresentationWindow: PresentationWindowProtocol {
    private let window: UIWindow
    private let rootViewController: UIViewController

    init() {
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
        } else {
            window = UIWindow(frame: UIScreen.main.bounds)
        }
        rootViewController = UIViewController()
        rootViewController.view.backgroundColor = .clear
        window.rootViewController = rootViewController
        window.windowLevel = .alert
        window.backgroundColor = .clear
    }

    func present(_ viewController: NuxiePlatformViewController) async {
        window.makeKeyAndVisible()
        // In unit test bundles, UIKit sometimes fails to call the completion block for modal
        // presentations off a synthetic window. Avoid hanging the E2E suite by not awaiting it.
        rootViewController.present(viewController, animated: false)
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, rootViewController.presentedViewController == nil {
            await Task.yield()
        }
    }

    func dismiss() async {
        guard rootViewController.presentedViewController != nil else { return }
        rootViewController.dismiss(animated: false)
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, rootViewController.presentedViewController != nil {
            await Task.yield()
        }
    }

    func destroy() {
        window.isHidden = true
        window.rootViewController = nil
    }

    var isPresenting: Bool {
        rootViewController.presentedViewController != nil
    }
}

private struct ExperimentAbCompiledBundleFixture {
    struct FileEntry {
        let data: Data
        let contentType: String
        let size: Int
    }

    let filesByPath: [String: FileEntry]
    let buildFiles: [BuildFile]
    let totalSize: Int
}

private func contentTypeForFixtureFile(path: String) -> String {
    if path.hasSuffix(".html") { return "text/html" }
    if path.hasSuffix(".css") { return "text/css" }
    if path.hasSuffix(".js") { return "text/javascript" }
    if path.hasSuffix(".map") { return "application/json" }
    return "application/octet-stream"
}

private func loadExperimentAbCompiledBundleFixture() -> ExperimentAbCompiledBundleFixture? {
    let bundle = Bundle(for: FlowRuntimeE2ESpec.self)
    guard let resourceURL = bundle.resourceURL else { return nil }
    let fm = FileManager.default

    let folderRoot = resourceURL.appendingPathComponent("experiment-ab-compiled-bundle", isDirectory: true)
    let root: URL
    if fm.fileExists(atPath: folderRoot.path) {
        root = folderRoot
    } else if let indexURL = bundle.url(forResource: "index", withExtension: "html") {
        // Some Xcode resource configurations flatten folder resources into the test bundle root.
        // Fall back to whichever directory contains index.html.
        root = indexURL.deletingLastPathComponent()
    } else {
        return nil
    }

    let urls: [URL]
    do {
        urls = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
    } catch {
        return nil
    }

    let executableName = bundle.executableURL?.lastPathComponent

    var filesByPath: [String: ExperimentAbCompiledBundleFixture.FileEntry] = [:]
    var buildFiles: [BuildFile] = []
    var totalSize = 0

    for url in urls {
        guard
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true
        else {
            continue
        }

        let fileName = url.lastPathComponent
        if fileName == "Info.plist" { continue }
        if let executableName, fileName == executableName { continue }

        let data = (try? Data(contentsOf: url)) ?? Data()
        let size = values.fileSize ?? data.count
        let contentType = contentTypeForFixtureFile(path: fileName)

        filesByPath[fileName] = .init(data: data, contentType: contentType, size: size)
        buildFiles.append(BuildFile(path: fileName, size: size, contentType: contentType))
        totalSize += size
    }

    guard filesByPath["index.html"] != nil else { return nil }

    buildFiles.sort { $0.path < $1.path }
    return ExperimentAbCompiledBundleFixture(
        filesByPath: filesByPath,
        buildFiles: buildFiles,
        totalSize: totalSize
    )
}

private func jsStringLiteral(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "'", with: "\\'")
    return "'\(escaped)'"
}

@MainActor
private func evaluateJavaScript(_ webView: WKWebView, script: String) async throws -> Any? {
    try await withCheckedThrowingContinuation { continuation in
        webView.evaluateJavaScript(script) { result, error in
            if let error = error {
                continuation.resume(throwing: error)
                return
            }
            continuation.resume(returning: result)
        }
    }
}

@MainActor
private func waitForElementExists(
    _ webView: WKWebView,
    elementId: String,
    timeoutSeconds: Double = 3.0
) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    let quoted = jsStringLiteral(elementId)
    while Date() < deadline {
        do {
            let value = try await evaluateJavaScript(
                webView,
                script: "Boolean(document.getElementById(\(quoted)))"
            ) as? Bool
            if value == true {
                return true
            }
        } catch {
            // Ignore transient WebKit errors while the page is still loading.
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    return false
}

@MainActor
private func waitForVmText(_ webView: WKWebView, equals expected: String, timeoutSeconds: Double = 3.0) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        do {
            let value = try await evaluateJavaScript(
                webView,
                script: "document.getElementById('vm-text') && document.getElementById('vm-text').textContent"
            ) as? String
            if value == expected {
                return true
            }
        } catch {
            // Ignore transient WebKit errors while the page is still loading.
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    return false
}

@MainActor
private func waitForListItems(
    _ webView: WKWebView,
    containerId: String,
    equals expected: [String],
    timeoutSeconds: Double = 3.0
) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    let quoted = jsStringLiteral(containerId)
    let expectedJoined = expected.joined(separator: "|")

    let script = """
    (function(){
      var root = document.getElementById(\(quoted));
      if (!root) return null;
      var items = Array.from(root.querySelectorAll('[data-e2e=\"list-item\"]')).map(function(el){
        return (el && el.textContent ? String(el.textContent).trim() : '').trim();
      }).filter(function(v){ return v.length > 0; });
      return items.join('|');
    })();
    """

    while Date() < deadline {
        do {
            let value = try await evaluateJavaScript(webView, script: script) as? String
            if value == expectedJoined {
                return true
            }
        } catch {
            // Ignore transient WebKit errors while the page is still loading.
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    return false
}

@MainActor
private func waitForElementText(
    _ webView: WKWebView,
    elementId: String,
    equals expected: String,
    timeoutSeconds: Double = 3.0
) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    let quoted = jsStringLiteral(elementId)
    while Date() < deadline {
        do {
            let value = try await evaluateJavaScript(
                webView,
                script: "document.getElementById(\(quoted)) && document.getElementById(\(quoted)).textContent"
            ) as? String
            if value == expected {
                return true
            }
        } catch {
            // Ignore transient WebKit errors while the page is still loading.
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    return false
}

@MainActor
private func waitForScreenId(_ webView: WKWebView, equals expected: String, timeoutSeconds: Double = 3.0) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        do {
            let value = try await evaluateJavaScript(
                webView,
                script: "document.getElementById('screen-id') && document.getElementById('screen-id').textContent"
            ) as? String
            if value == expected {
                return true
            }
        } catch {
            // Ignore transient WebKit errors while the page is still loading.
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    return false
}

private func waitForArchiveURL(_ archiveService: FlowArchiver, for flow: Flow, timeoutSeconds: Double = 8.0) async throws -> URL? {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if let url = await archiveService.getArchiveURL(for: flow) {
            return url
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    return nil
}

private struct E2ETimeoutError: Error, CustomStringConvertible {
    let seconds: Double
    let operation: String?

    var description: String {
        if let operation {
            return "timeout(seconds=\(seconds), operation=\(operation))"
        }
        return "timeout(seconds=\(seconds))"
    }
}

private func withTimeout<T>(
    seconds: Double,
    operationName: String? = nil,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw E2ETimeoutError(seconds: seconds, operation: operationName)
        }
        guard let result = try await group.next() else {
            throw E2ETimeoutError(seconds: seconds, operation: operationName)
        }
        group.cancelAll()
        return result
    }
}
