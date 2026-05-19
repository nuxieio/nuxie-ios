#if canImport(RiveRuntime) && canImport(UIKit)
import RiveRuntime
@testable import Nuxie
import UIKit
import XCTest

@MainActor
final class FlowViewModelBridgeTests: XCTestCase {
    func testDiscoversNativeViewModelsFromRiveFile() throws {
        let bridge = try makeBridge()

        let definitions = bridge.discoverViewModels()
        let testDefinition = try XCTUnwrap(definitions.first(where: { $0.name == "Test" }))

        XCTAssertEqual(Set(definitions.map(\.name)), ["Test", "Nested", "Default"])
        XCTAssertEqual(Set(testDefinition.instanceNames), ["Editor Defaults", "Default"])
        XCTAssertTrue(testDefinition.properties.contains(.init(name: "String", type: "string")))
        XCTAssertTrue(testDefinition.properties.contains(.init(name: "Number", type: "number")))
        XCTAssertTrue(testDefinition.properties.contains(.init(name: "Boolean", type: "boolean")))
        XCTAssertTrue(testDefinition.properties.contains(.init(name: "Trigger Red", type: "trigger")))
    }

    func testBindsDefaultInstanceAndWritesHostValuesThroughRiveRuntime() throws {
        let bridge = try makeBridge()

        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())
        XCTAssertEqual(bridge.boundViewModelName, "Test")
        XCTAssertEqual(bridge.boundInstanceName, "Default")

        try bridge.setString("native-sdk", path: "String")
        try bridge.setNumber(44, path: "Number")
        try bridge.setBoolean(true, path: "Boolean")

        XCTAssertEqual(try bridge.stringValue(path: "String"), "native-sdk")
        XCTAssertEqual(try bridge.numberValue(path: "Number"), 44)
        XCTAssertEqual(try bridge.booleanValue(path: "Boolean"), true)
        XCTAssertTrue(try bridge.fireTrigger(path: "Trigger Red"))
    }

    func testAppliesRuntimeInitPayloadToBoundRiveViewModel() throws {
        let bridge = try makeBridge(remoteFlow: makeRemoteFlow())
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        let handled = bridge.handleRuntimeMessage(
            type: "runtime/view_model_init",
            payload: [
                "viewModelInstances": [
                    [
                        "viewModelId": "vm-test",
                        "instanceId": "instance-test",
                        "name": "Default",
                        "values": [
                            "String": "from-flow-state",
                            "Number": 77,
                            "Boolean": true,
                        ],
                    ],
                ],
            ]
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(try bridge.stringValue(path: "String"), "from-flow-state")
        XCTAssertEqual(try bridge.numberValue(path: "Number"), 77)
        XCTAssertEqual(try bridge.booleanValue(path: "Boolean"), true)
    }

    func testAppliesRuntimePatchAndTriggerMessagesToBoundRiveViewModel() throws {
        let bridge = try makeBridge(remoteFlow: makeRemoteFlow())
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        XCTAssertTrue(bridge.handleRuntimeMessage(
            type: "runtime/view_model_patch",
            payload: [
                "pathIds": [100, 1],
                "value": "patched",
            ]
        ))
        XCTAssertTrue(bridge.handleRuntimeMessage(
            type: "runtime/view_model_patch",
            payload: [
                "pathIds": [100, 2],
                "value": 12,
            ]
        ))
        XCTAssertTrue(bridge.handleRuntimeMessage(
            type: "runtime/view_model_patch",
            payload: [
                "pathIds": [100, 3],
                "value": true,
            ]
        ))

        XCTAssertEqual(try bridge.stringValue(path: "String"), "patched")
        XCTAssertEqual(try bridge.numberValue(path: "Number"), 12)
        XCTAssertEqual(try bridge.booleanValue(path: "Boolean"), true)
        XCTAssertTrue(bridge.handleRuntimeMessage(
            type: "runtime/view_model_trigger",
            payload: [
                "pathIds": [100, 4],
            ]
        ))
    }

    func testKeepsSeparateFlowInstancesForTheSameRiveViewModel() throws {
        let bridge = try makeBridge(remoteFlow: makeRemoteFlow(screens: [
            RemoteFlowScreen(id: "screen-1", defaultViewModelId: "vm-test", defaultInstanceId: "instance-a"),
            RemoteFlowScreen(id: "screen-2", defaultViewModelId: "vm-test", defaultInstanceId: "instance-b"),
        ]))
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        XCTAssertTrue(bridge.handleRuntimeMessage(
            type: "runtime/view_model_init",
            payload: [
                "viewModelInstances": [
                    [
                        "viewModelId": "vm-test",
                        "instanceId": "instance-a",
                        "values": ["String": "screen-a"],
                    ],
                    [
                        "viewModelId": "vm-test",
                        "instanceId": "instance-b",
                        "values": ["String": "screen-b"],
                    ],
                ],
                "screenDefaults": [
                    "screen-1": ["defaultInstanceId": "instance-a"],
                    "screen-2": ["defaultInstanceId": "instance-b"],
                ],
            ]
        ))

        XCTAssertEqual(try bridge.stringValue(path: "String"), "screen-a")
        XCTAssertTrue(bridge.handleRuntimeMessage(
            type: "runtime/view_model_patch",
            payload: [
                "pathIds": [100, 1],
                "instanceId": "instance-b",
                "value": "patched-b",
            ]
        ))
        XCTAssertEqual(try bridge.stringValue(path: "String"), "screen-a")

        XCTAssertTrue(bridge.bindDefaultInstance(forScreenId: "screen-2"))
        XCTAssertEqual(try bridge.stringValue(path: "String"), "patched-b")
    }

    func testNavigatingAcrossViewModelsRoutesScreenPatchesToVisibleInstance() throws {
        let bridge = try makeBridge(remoteFlow: makeRemoteFlow(screens: [
            RemoteFlowScreen(id: "screen-1", defaultViewModelId: "vm-test", defaultInstanceId: "instance-test"),
            RemoteFlowScreen(id: "screen-2", defaultViewModelId: "vm-nested", defaultInstanceId: "instance-nested"),
        ]))
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        XCTAssertTrue(bridge.handleRuntimeMessage(
            type: "runtime/view_model_init",
            payload: [
                "viewModelInstances": [
                    [
                        "viewModelId": "vm-test",
                        "instanceId": "instance-test",
                        "values": ["String": "screen-a"],
                    ],
                    [
                        "viewModelId": "vm-nested",
                        "instanceId": "instance-nested",
                        "values": ["String": "screen-b"],
                    ],
                ],
            ]
        ))

        XCTAssertTrue(bridge.bindDefaultInstance(forScreenId: "screen-2"))
        XCTAssertEqual(try bridge.stringValue(path: "String"), "screen-b")

        XCTAssertTrue(bridge.handleRuntimeMessage(
            type: "runtime/view_model_patch",
            payload: [
                "pathIds": [200, 1],
                "value": "visible-patch",
            ]
        ))
        XCTAssertEqual(try bridge.stringValue(path: "String"), "visible-patch")
    }

    func testOffscreenPatchWithoutInstanceIdUsesCachedDefaultInstance() throws {
        let bridge = try makeBridge(remoteFlow: makeRemoteFlow(screens: [
            RemoteFlowScreen(id: "screen-1", defaultViewModelId: "vm-test", defaultInstanceId: "instance-test"),
            RemoteFlowScreen(id: "screen-2", defaultViewModelId: "vm-nested", defaultInstanceId: "instance-nested"),
        ]))
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        XCTAssertTrue(bridge.handleRuntimeMessage(
            type: "runtime/view_model_init",
            payload: [
                "viewModelInstances": [
                    [
                        "viewModelId": "vm-test",
                        "instanceId": "instance-test",
                        "values": ["String": "screen-a"],
                    ],
                    [
                        "viewModelId": "vm-nested",
                        "instanceId": "instance-nested",
                        "values": ["String": "screen-b"],
                    ],
                ],
            ]
        ))

        XCTAssertTrue(bridge.handleRuntimeMessage(
            type: "runtime/view_model_patch",
            payload: [
                "pathIds": [200, 1],
                "value": "preloaded-offscreen",
            ]
        ))
        XCTAssertEqual(try bridge.stringValue(path: "String"), "screen-a")

        XCTAssertTrue(bridge.bindDefaultInstance(forScreenId: "screen-2"))
        XCTAssertEqual(try bridge.stringValue(path: "String"), "preloaded-offscreen")
    }

    func testDuplicatePathRootsPreferBoundViewModelWhenPatchOmitsInstanceId() throws {
        let duplicateRoot = ViewModel(
            id: "vm-nested-duplicate-root",
            name: "Nested",
            viewModelPathId: 100,
            properties: [
                "String": ViewModelProperty(type: .string, propertyId: 1),
            ]
        )
        let bridge = try makeBridge(remoteFlow: makeRemoteFlow(
            screens: [
                RemoteFlowScreen(id: "screen-1", defaultViewModelId: "vm-test", defaultInstanceId: "instance-test"),
                RemoteFlowScreen(
                    id: "screen-2",
                    defaultViewModelId: duplicateRoot.id,
                    defaultInstanceId: "instance-nested"
                ),
            ],
            extraViewModels: [duplicateRoot]
        ))
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        XCTAssertTrue(bridge.handleRuntimeMessage(
            type: "runtime/view_model_init",
            payload: [
                "viewModelInstances": [
                    [
                        "viewModelId": "vm-test",
                        "instanceId": "instance-test",
                        "values": ["String": "screen-a"],
                    ],
                    [
                        "viewModelId": duplicateRoot.id,
                        "instanceId": "instance-nested",
                        "values": ["String": "screen-b"],
                    ],
                ],
            ]
        ))
        XCTAssertTrue(bridge.bindDefaultInstance(forScreenId: "screen-2"))

        XCTAssertTrue(bridge.handleRuntimeMessage(
            type: "runtime/view_model_patch",
            payload: [
                "pathIds": [100, 1],
                "value": "patched-visible-duplicate",
            ]
        ))
        XCTAssertEqual(try bridge.stringValue(path: "String"), "patched-visible-duplicate")
    }

    func testNavigatesByDefaultViewModelWhenDefaultInstanceIsOmitted() throws {
        let bridge = try makeBridge(remoteFlow: makeRemoteFlow(screens: [
            RemoteFlowScreen(id: "screen-1", defaultViewModelId: "vm-test", defaultInstanceId: "instance-test"),
            RemoteFlowScreen(id: "screen-2", defaultViewModelId: "vm-nested", defaultInstanceId: nil),
        ]))
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        XCTAssertTrue(bridge.handleRuntimeMessage(
            type: "runtime/view_model_init",
            payload: [
                "viewModelInstances": [
                    [
                        "viewModelId": "vm-test",
                        "instanceId": "instance-test",
                        "values": ["String": "screen-a"],
                    ],
                    [
                        "viewModelId": "vm-nested",
                        "instanceId": "instance-nested",
                        "values": ["String": "screen-b"],
                    ],
                ],
            ]
        ))

        XCTAssertTrue(bridge.bindDefaultInstance(forScreenId: "screen-2"))
        XCTAssertEqual(try bridge.stringValue(path: "String"), "screen-b")
    }

    func testListOperationsRecomputeItemIndexesAndEmptyListPatchApplies() throws {
        let bridge = try makeBridge(remoteFlow: makeRemoteFlow())
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        XCTAssertTrue(bridge.handleRuntimeMessage(
            type: "runtime/view_model_init",
            payload: [
                "viewModelInstances": [
                    [
                        "viewModelId": "vm-test",
                        "instanceId": "instance-test",
                        "values": [
                            "List": [
                                [
                                    "vmInstanceId": "item-a",
                                    "viewModelId": "vm-test",
                                    "values": ["String": "a", "Number": 99],
                                ],
                                [
                                    "vmInstanceId": "item-b",
                                    "viewModelId": "vm-test",
                                    "values": ["String": "b", "Number": 99],
                                ],
                            ],
                        ],
                    ],
                ],
            ]
        ))
        XCTAssertEqual(try bridge.listCount(path: "List"), 2)
        XCTAssertEqual(try bridge.numberValue(path: "Number", instanceId: "item-a"), 0)
        XCTAssertEqual(try bridge.numberValue(path: "Number", instanceId: "item-b"), 1)

        XCTAssertTrue(bridge.handleRuntimeMessage(
            type: "runtime/view_model_list_insert",
            payload: [
                "pathIds": [100, 5],
                "index": 0,
                "value": [
                    "vmInstanceId": "item-c",
                    "viewModelId": "vm-test",
                    "values": ["String": "c", "Number": 99],
                ],
            ]
        ))
        XCTAssertEqual(try bridge.numberValue(path: "Number", instanceId: "item-c"), 0)
        XCTAssertEqual(try bridge.numberValue(path: "Number", instanceId: "item-a"), 1)
        XCTAssertEqual(try bridge.numberValue(path: "Number", instanceId: "item-b"), 2)

        XCTAssertTrue(bridge.handleRuntimeMessage(
            type: "runtime/view_model_list_set",
            payload: [
                "pathIds": [100, 5],
                "index": 1,
                "value": [
                    "vmInstanceId": "item-a",
                    "viewModelId": "vm-test",
                    "values": ["String": "updated-a", "Number": 99],
                ],
            ]
        ))
        XCTAssertEqual(try bridge.stringValue(path: "String", instanceId: "item-a"), "updated-a")
        XCTAssertEqual(try bridge.numberValue(path: "Number", instanceId: "item-a"), 1)

        XCTAssertTrue(bridge.handleRuntimeMessage(
            type: "runtime/view_model_patch",
            payload: [
                "pathIds": [100, 5],
                "value": [],
            ]
        ))
        XCTAssertEqual(try bridge.listCount(path: "List"), 0)
    }

    func testListInsertClampsOutOfRangeIndexesLikeHostRuntime() throws {
        let bridge = try makeBridge(remoteFlow: makeRemoteFlow())
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        XCTAssertTrue(bridge.handleRuntimeMessage(
            type: "runtime/view_model_patch",
            payload: [
                "pathIds": [100, 5],
                "value": [
                    [
                        "vmInstanceId": "item-a",
                        "viewModelId": "vm-test",
                        "values": ["String": "a", "Number": 99],
                    ],
                ],
            ]
        ))

        XCTAssertTrue(bridge.handleRuntimeMessage(
            type: "runtime/view_model_list_insert",
            payload: [
                "pathIds": [100, 5],
                "index": 99,
                "value": [
                    "vmInstanceId": "item-b",
                    "viewModelId": "vm-test",
                    "values": ["String": "b", "Number": 99],
                ],
            ]
        ))
        XCTAssertEqual(try bridge.numberValue(path: "Number", instanceId: "item-a"), 0)
        XCTAssertEqual(try bridge.numberValue(path: "Number", instanceId: "item-b"), 1)

        XCTAssertTrue(bridge.handleRuntimeMessage(
            type: "runtime/view_model_list_insert",
            payload: [
                "pathIds": [100, 5],
                "index": -5,
                "value": [
                    "vmInstanceId": "item-c",
                    "viewModelId": "vm-test",
                    "values": ["String": "c", "Number": 99],
                ],
            ]
        ))
        XCTAssertEqual(try bridge.numberValue(path: "Number", instanceId: "item-c"), 0)
        XCTAssertEqual(try bridge.numberValue(path: "Number", instanceId: "item-a"), 1)
        XCTAssertEqual(try bridge.numberValue(path: "Number", instanceId: "item-b"), 2)
    }

    func testCanBindScreenInstanceAfterInitWithoutInitialArtboardBinding() throws {
        let bridge = try makeBridge(remoteFlow: makeRemoteFlow(screens: [
            RemoteFlowScreen(id: "screen-1", defaultViewModelId: nil, defaultInstanceId: nil),
            RemoteFlowScreen(id: "screen-2", defaultViewModelId: "vm-nested", defaultInstanceId: "instance-nested"),
        ]))

        XCTAssertTrue(bridge.handleRuntimeMessage(
            type: "runtime/view_model_init",
            payload: [
                "viewModelInstances": [
                    [
                        "viewModelId": "vm-nested",
                        "instanceId": "instance-nested",
                        "values": ["String": "screen-b"],
                    ],
                ],
            ]
        ))
        XCTAssertTrue(bridge.bindDefaultInstance(forScreenId: "screen-2"))
        XCTAssertEqual(try bridge.stringValue(path: "String"), "screen-b")
    }

    func testCanRetryScreenBindingAfterPreInitNavigate() throws {
        let bridge = try makeBridge(remoteFlow: makeRemoteFlow(screens: [
            RemoteFlowScreen(id: "screen-1", defaultViewModelId: "vm-test", defaultInstanceId: "instance-test"),
            RemoteFlowScreen(id: "screen-2", defaultViewModelId: "vm-nested", defaultInstanceId: "instance-nested"),
        ]))
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        XCTAssertFalse(bridge.bindDefaultInstance(forScreenId: "screen-2"))
        XCTAssertTrue(bridge.handleRuntimeMessage(
            type: "runtime/view_model_init",
            payload: [
                "viewModelInstances": [
                    [
                        "viewModelId": "vm-test",
                        "instanceId": "instance-test",
                        "values": ["String": "screen-a"],
                    ],
                    [
                        "viewModelId": "vm-nested",
                        "instanceId": "instance-nested",
                        "values": ["String": "screen-b"],
                    ],
                ],
            ]
        ))
        XCTAssertTrue(bridge.bindDefaultInstance(forScreenId: "screen-2"))
        XCTAssertEqual(try bridge.stringValue(path: "String"), "screen-b")
    }

    func testUsesInstanceIdToDisambiguateDuplicatePathRoots() throws {
        let otherViewModel = ViewModel(
            id: "vm-other",
            name: "Other",
            viewModelPathId: 100,
            properties: [
                "OtherString": ViewModelProperty(type: .string, propertyId: 1),
            ]
        )
        let bridge = try makeBridge(remoteFlow: makeRemoteFlow(extraViewModels: [otherViewModel]))
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        XCTAssertTrue(bridge.handleRuntimeMessage(
            type: "runtime/view_model_init",
            payload: [
                "viewModelInstances": [
                    [
                        "viewModelId": "vm-test",
                        "instanceId": "instance-test",
                        "values": ["String": "bound"],
                    ],
                    [
                        "viewModelId": "vm-other",
                        "instanceId": "instance-other",
                        "values": ["OtherString": "other"],
                    ],
                ],
            ]
        ))

        XCTAssertFalse(bridge.handleRuntimeMessage(
            type: "runtime/view_model_patch",
            payload: [
                "pathIds": [100, 1],
                "instanceId": "instance-other",
                "value": "should-not-hit-bound",
            ]
        ))
        XCTAssertEqual(try bridge.stringValue(path: "String"), "bound")
    }

    func testAppliesImagePayloadsThroughRiveImageProperty() throws {
        let image = try makeRenderImage()
        let bridge = try makeBridge(remoteFlow: makeRemoteFlow())
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        XCTAssertTrue(bridge.handleRuntimeMessage(
            type: "runtime/view_model_patch",
            payload: [
                "pathIds": [100, 6],
                "value": image,
            ]
        ))
    }

    func testThrowsWhenWritingBeforeBinding() throws {
        let bridge = try makeBridge()

        XCTAssertThrowsError(try bridge.setString("missing", path: "String")) { error in
            XCTAssertEqual(error as? FlowViewModelBridgeError, .instanceNotBound)
        }
    }

    private func makeBridge(remoteFlow: RemoteFlow? = nil) throws -> FlowViewModelBridge {
        let bundle = Bundle(for: FlowViewModelBridgeTests.self)
        let url = bundle.url(forResource: "data_binding_test", withExtension: "riv", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "data_binding_test", withExtension: "riv")
        let fixtureURL = try XCTUnwrap(url)
        let data = try Data(contentsOf: fixtureURL)
        let file = try RiveFile(data: data, loadCdn: false)
        let model = RiveModel(riveFile: file)
        try model.setArtboard()
        try model.setStateMachine("State Machine 1")
        return FlowViewModelBridge(model: model, remoteFlow: remoteFlow)
    }

    private func makeRenderImage() throws -> RiveRenderImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return try XCTUnwrap(RiveRenderImage(image: image, format: .png))
    }

    private func makeRemoteFlow(
        screens: [RemoteFlowScreen]? = nil,
        extraViewModels: [ViewModel] = []
    ) -> RemoteFlow {
        let nestedViewModel = ViewModel(
            id: "vm-nested",
            name: "Nested",
            viewModelPathId: 200,
            properties: [
                "String": ViewModelProperty(type: .string, propertyId: 1),
                "Number": ViewModelProperty(type: .list_index, propertyId: 2),
            ]
        )
        let viewModel = ViewModel(
            id: "vm-test",
            name: "Test",
            viewModelPathId: 100,
            properties: [
                "String": ViewModelProperty(type: .string, propertyId: 1),
                "Number": ViewModelProperty(type: .list_index, propertyId: 2),
                "Boolean": ViewModelProperty(type: .boolean, propertyId: 3),
                "Trigger Red": ViewModelProperty(type: .trigger, propertyId: 4),
                "List": ViewModelProperty(
                    type: .list,
                    propertyId: 5,
                    itemType: ViewModelProperty(type: .viewModel, viewModelId: "vm-test")
                ),
                "Image": ViewModelProperty(type: .image, propertyId: 6),
            ]
        )

        return RemoteFlow(
            id: "flow-native-vm",
            flowArtifact: FlowArtifact(
                url: "https://example.com/flow/native-vm",
                manifest: BuildManifest(
                    totalFiles: 1,
                    totalSize: 100,
                    contentHash: "native-vm",
                    files: [BuildFile(path: "flow.riv", size: 100, contentType: "application/octet-stream")]
                )
            ),
            screens: screens ?? [
                RemoteFlowScreen(
                    id: "screen-1",
                    defaultViewModelId: viewModel.id,
                    defaultInstanceId: "instance-test"
                ),
            ],
            interactions: [:],
            viewModels: [viewModel, nestedViewModel] + extraViewModels,
            viewModelInstances: nil,
            converters: nil
        )
    }
}
#endif
