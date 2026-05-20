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

    func testAppliesSnapshotToBoundRiveViewModel() throws {
        let bridge = try makeBridge(remoteFlow: makeRemoteFlow())
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        let handled = bridge.applySnapshot(
            makeSnapshot([
                makeInstance(
                    viewModelId: "Test",
                    instanceId: "instance-test",
                    name: "Default",
                    values: [
                        "String": "from-flow-state",
                        "Number": 77,
                        "Boolean": true,
                    ]
                )
            ]),
            screenId: "screen-1"
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(try bridge.stringValue(path: "String"), "from-flow-state")
        XCTAssertEqual(try bridge.numberValue(path: "Number"), 77)
        XCTAssertEqual(try bridge.booleanValue(path: "Boolean"), true)
    }

    func testAppliesTypedPatchAndTriggerCommandsToBoundRiveViewModel() throws {
        let bridge = try makeBridge(remoteFlow: makeRemoteFlow())
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        XCTAssertTrue(bridge.applyValue(path: path("String"), value: "patched", screenId: "screen-1", instanceId: nil))
        XCTAssertTrue(bridge.applyValue(path: path("Number"), value: 12, screenId: "screen-1", instanceId: nil))
        XCTAssertTrue(bridge.applyValue(path: path("Boolean"), value: true, screenId: "screen-1", instanceId: nil))

        XCTAssertEqual(try bridge.stringValue(path: "String"), "patched")
        XCTAssertEqual(try bridge.numberValue(path: "Number"), 12)
        XCTAssertEqual(try bridge.booleanValue(path: "Boolean"), true)
        XCTAssertTrue(bridge.fireTrigger(path: path("Trigger Red"), screenId: "screen-1", instanceId: nil))
    }

    func testKeepsSeparateFlowInstancesForTheSameRiveViewModel() throws {
        let bridge = try makeBridge(remoteFlow: makeRemoteFlow(screens: [
            RemoteFlowScreen(id: "screen-1", defaultViewModelName: "Test", defaultInstanceId: "instance-a"),
            RemoteFlowScreen(id: "screen-2", defaultViewModelName: "Test", defaultInstanceId: "instance-b"),
        ]))
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        XCTAssertTrue(bridge.applySnapshot(
            makeSnapshot([
                makeInstance(viewModelId: "Test", instanceId: "instance-a", values: ["String": "screen-a"]),
                makeInstance(viewModelId: "Test", instanceId: "instance-b", values: ["String": "screen-b"]),
            ]),
            screenId: "screen-1"
        ))

        XCTAssertEqual(try bridge.stringValue(path: "String"), "screen-a")
        XCTAssertTrue(bridge.applyValue(path: path("String"), value: "patched-b", screenId: "screen-2", instanceId: "instance-b"))
        XCTAssertEqual(try bridge.stringValue(path: "String"), "screen-a")

        XCTAssertTrue(bridge.bindDefaultInstance(forScreenId: "screen-2"))
        XCTAssertEqual(try bridge.stringValue(path: "String"), "patched-b")
    }

    func testNavigatingAcrossViewModelsRoutesScreenPatchesToVisibleInstance() throws {
        let bridge = try makeBridge(remoteFlow: makeRemoteFlow(screens: [
            RemoteFlowScreen(id: "screen-1", defaultViewModelName: "Test", defaultInstanceId: "instance-test"),
            RemoteFlowScreen(id: "screen-2", defaultViewModelName: "Nested", defaultInstanceId: "instance-nested"),
        ]))
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        XCTAssertTrue(bridge.applySnapshot(
            makeSnapshot([
                makeInstance(viewModelId: "Test", instanceId: "instance-test", values: ["String": "screen-a"]),
                makeInstance(viewModelId: "Nested", instanceId: "instance-nested", values: ["String": "screen-b"]),
            ]),
            screenId: "screen-1"
        ))

        XCTAssertTrue(bridge.bindDefaultInstance(forScreenId: "screen-2"))
        XCTAssertEqual(try bridge.stringValue(path: "String"), "screen-b")

        XCTAssertTrue(bridge.applyValue(path: path("String", viewModelName: "Nested"), value: "visible-patch", screenId: "screen-2", instanceId: nil))
        XCTAssertEqual(try bridge.stringValue(path: "String"), "visible-patch")
    }

    func testOffscreenPatchWithoutInstanceIdUsesCachedDefaultInstance() throws {
        let bridge = try makeBridge(remoteFlow: makeRemoteFlow(screens: [
            RemoteFlowScreen(id: "screen-1", defaultViewModelName: "Test", defaultInstanceId: "instance-test"),
            RemoteFlowScreen(id: "screen-2", defaultViewModelName: "Nested", defaultInstanceId: "instance-nested"),
        ]))
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        XCTAssertTrue(bridge.applySnapshot(
            makeSnapshot([
                makeInstance(viewModelId: "Test", instanceId: "instance-test", values: ["String": "screen-a"]),
                makeInstance(viewModelId: "Nested", instanceId: "instance-nested", values: ["String": "screen-b"]),
            ]),
            screenId: "screen-1"
        ))

        XCTAssertTrue(bridge.applyValue(path: path("String", viewModelName: "Nested"), value: "preloaded-offscreen", screenId: "screen-2", instanceId: nil))
        XCTAssertEqual(try bridge.stringValue(path: "String"), "screen-a")

        XCTAssertTrue(bridge.bindDefaultInstance(forScreenId: "screen-2"))
        XCTAssertEqual(try bridge.stringValue(path: "String"), "preloaded-offscreen")
    }

    func testRelativeScreenPatchUsesDefaultInstanceWhenDefaultViewModelIsOmitted() throws {
        let bridge = try makeBridge(remoteFlow: makeRemoteFlow(screens: [
            RemoteFlowScreen(id: "screen-1", defaultViewModelName: "Test", defaultInstanceId: "instance-test"),
            RemoteFlowScreen(id: "screen-2", defaultViewModelName: nil, defaultInstanceId: "instance-nested"),
        ]))
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        XCTAssertTrue(bridge.applySnapshot(
            makeSnapshot([
                makeInstance(viewModelId: "Test", instanceId: "instance-test", values: ["String": "screen-a"]),
                makeInstance(viewModelId: "Nested", instanceId: "instance-nested", values: ["String": "screen-b"]),
            ]),
            screenId: "screen-1"
        ))

        XCTAssertTrue(bridge.applyValue(
            path: path("String", viewModelName: nil, isRelative: true),
            value: "patched-by-instance-default",
            screenId: "screen-2",
            instanceId: nil
        ))
        XCTAssertEqual(try bridge.stringValue(path: "String"), "screen-a")

        XCTAssertTrue(bridge.bindDefaultInstance(forScreenId: "screen-2"))
        XCTAssertEqual(try bridge.stringValue(path: "String"), "patched-by-instance-default")
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
                RemoteFlowScreen(id: "screen-1", defaultViewModelName: "Test", defaultInstanceId: "instance-test"),
                RemoteFlowScreen(
                    id: "screen-2",
                    defaultViewModelName: duplicateRoot.name,
                    defaultInstanceId: "instance-nested"
                ),
            ],
            extraViewModels: [duplicateRoot]
        ))
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        XCTAssertTrue(bridge.applySnapshot(
            makeSnapshot([
                makeInstance(viewModelId: "Test", instanceId: "instance-test", values: ["String": "screen-a"]),
                makeInstance(viewModelId: duplicateRoot.name, instanceId: "instance-nested", values: ["String": "screen-b"]),
            ]),
            screenId: "screen-1"
        ))
        XCTAssertTrue(bridge.bindDefaultInstance(forScreenId: "screen-2"))

        XCTAssertTrue(bridge.applyValue(path: path("String", viewModelName: "Nested"), value: "patched-visible-duplicate", screenId: "screen-2", instanceId: nil))
        XCTAssertEqual(try bridge.stringValue(path: "String"), "patched-visible-duplicate")
    }

    func testNavigatesByDefaultViewModelWhenDefaultInstanceIsOmitted() throws {
        let bridge = try makeBridge(remoteFlow: makeRemoteFlow(screens: [
            RemoteFlowScreen(id: "screen-1", defaultViewModelName: "Test", defaultInstanceId: "instance-test"),
            RemoteFlowScreen(id: "screen-2", defaultViewModelName: "Nested", defaultInstanceId: nil),
        ]))
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        XCTAssertTrue(bridge.applySnapshot(
            makeSnapshot([
                makeInstance(viewModelId: "Test", instanceId: "instance-test", values: ["String": "screen-a"]),
                makeInstance(viewModelId: "Nested", instanceId: "instance-nested", values: ["String": "screen-b"]),
            ]),
            screenId: "screen-1"
        ))

        XCTAssertTrue(bridge.bindDefaultInstance(forScreenId: "screen-2"))
        XCTAssertEqual(try bridge.stringValue(path: "String"), "screen-b")
    }

    func testListOperationsApplyValuesAndEmptyListPatchApplies() throws {
        let bridge = try makeBridge(remoteFlow: makeRemoteFlow())
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        XCTAssertTrue(bridge.applySnapshot(
            makeSnapshot([
                makeInstance(
                    viewModelId: "Test",
                    instanceId: "instance-test",
                    values: [
                        "List": [
                            [
                                "vmInstanceId": "item-a",
                                "viewModelId": "Test",
                                "values": ["String": "a", "Number": 99],
                            ],
                            [
                                "vmInstanceId": "item-b",
                                "viewModelId": "Test",
                                "values": ["String": "b", "Number": 99],
                            ],
                        ],
                    ]
                )
            ]),
            screenId: "screen-1"
        ))
        XCTAssertEqual(try bridge.listCount(path: "List"), 2)
        XCTAssertEqual(try bridge.stringValue(path: "String", instanceId: "item-a"), "a")
        XCTAssertEqual(try bridge.stringValue(path: "String", instanceId: "item-b"), "b")

        XCTAssertTrue(bridge.applyListOperation(
            .insert,
            path: path("List"),
            payload: [
                "index": 0,
                "value": [
                    "vmInstanceId": "item-c",
                    "viewModelId": "Test",
                    "values": ["String": "c", "Number": 99],
                ],
            ],
            screenId: "screen-1",
            instanceId: nil
        ))
        XCTAssertEqual(try bridge.listCount(path: "List"), 3)
        XCTAssertEqual(try bridge.stringValue(path: "String", instanceId: "item-c"), "c")
        XCTAssertEqual(try bridge.stringValue(path: "String", instanceId: "item-a"), "a")
        XCTAssertEqual(try bridge.stringValue(path: "String", instanceId: "item-b"), "b")

        XCTAssertTrue(bridge.applyListOperation(
            .set,
            path: path("List"),
            payload: [
                "index": 1,
                "value": [
                    "vmInstanceId": "item-a",
                    "viewModelId": "Test",
                    "values": ["String": "updated-a", "Number": 99],
                ],
            ],
            screenId: "screen-1",
            instanceId: nil
        ))
        XCTAssertEqual(try bridge.stringValue(path: "String", instanceId: "item-a"), "updated-a")
        XCTAssertEqual(try bridge.listCount(path: "List"), 3)

        XCTAssertTrue(bridge.applyValue(path: path("List"), value: [], screenId: "screen-1", instanceId: nil))
        XCTAssertEqual(try bridge.listCount(path: "List"), 0)
    }

    func testListInsertClampsOutOfRangeIndexesLikeHostRuntime() throws {
        let bridge = try makeBridge(remoteFlow: makeRemoteFlow())
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        XCTAssertTrue(bridge.applyValue(
            path: path("List"),
            value: [
                    [
                        "vmInstanceId": "item-a",
                        "viewModelId": "Test",
                        "values": ["String": "a", "Number": 99],
                    ],
            ],
            screenId: "screen-1",
            instanceId: nil
        ))

        XCTAssertTrue(bridge.applyListOperation(
            .insert,
            path: path("List"),
            payload: [
                "index": 99,
                "value": [
                    "vmInstanceId": "item-b",
                    "viewModelId": "Test",
                    "values": ["String": "b", "Number": 99],
                ],
            ],
            screenId: "screen-1",
            instanceId: nil
        ))
        XCTAssertEqual(try bridge.listCount(path: "List"), 2)
        XCTAssertEqual(try bridge.stringValue(path: "String", instanceId: "item-a"), "a")
        XCTAssertEqual(try bridge.stringValue(path: "String", instanceId: "item-b"), "b")

        XCTAssertTrue(bridge.applyListOperation(
            .insert,
            path: path("List"),
            payload: [
                "index": -5,
                "value": [
                    "vmInstanceId": "item-c",
                    "viewModelId": "Test",
                    "values": ["String": "c", "Number": 99],
                ],
            ],
            screenId: "screen-1",
            instanceId: nil
        ))
        XCTAssertEqual(try bridge.listCount(path: "List"), 3)
        XCTAssertEqual(try bridge.stringValue(path: "String", instanceId: "item-c"), "c")
        XCTAssertEqual(try bridge.stringValue(path: "String", instanceId: "item-a"), "a")
        XCTAssertEqual(try bridge.stringValue(path: "String", instanceId: "item-b"), "b")
    }

    func testCanBindScreenInstanceAfterInitWithoutInitialArtboardBinding() throws {
        let bridge = try makeBridge(remoteFlow: makeRemoteFlow(screens: [
            RemoteFlowScreen(id: "screen-1", defaultViewModelName: nil, defaultInstanceId: nil),
            RemoteFlowScreen(id: "screen-2", defaultViewModelName: "Nested", defaultInstanceId: "instance-nested"),
        ]))

        XCTAssertTrue(bridge.applySnapshot(
            makeSnapshot([
                makeInstance(viewModelId: "Nested", instanceId: "instance-nested", values: ["String": "screen-b"]),
            ]),
            screenId: "screen-2"
        ))
        XCTAssertTrue(bridge.bindDefaultInstance(forScreenId: "screen-2"))
        XCTAssertEqual(try bridge.stringValue(path: "String"), "screen-b")
    }

    func testCanRetryScreenBindingAfterPreInitNavigate() throws {
        let bridge = try makeBridge(remoteFlow: makeRemoteFlow(screens: [
            RemoteFlowScreen(id: "screen-1", defaultViewModelName: "Test", defaultInstanceId: "instance-test"),
            RemoteFlowScreen(id: "screen-2", defaultViewModelName: "Nested", defaultInstanceId: "instance-nested"),
        ]))
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        XCTAssertFalse(bridge.bindDefaultInstance(forScreenId: "screen-2"))
        XCTAssertTrue(bridge.applySnapshot(
            makeSnapshot([
                makeInstance(viewModelId: "Test", instanceId: "instance-test", values: ["String": "screen-a"]),
                makeInstance(viewModelId: "Nested", instanceId: "instance-nested", values: ["String": "screen-b"]),
            ]),
            screenId: "screen-1"
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

        XCTAssertTrue(bridge.applySnapshot(
            makeSnapshot([
                makeInstance(viewModelId: "Test", instanceId: "instance-test", values: ["String": "bound"]),
                makeInstance(viewModelId: "vm-other", instanceId: "instance-other", values: ["OtherString": "other"]),
            ]),
            screenId: "screen-1"
        ))

        XCTAssertFalse(bridge.applyValue(
            path: path("OtherString", viewModelName: "Other"),
            value: "should-not-hit-bound",
            screenId: "screen-1",
            instanceId: "instance-other"
        ))
        XCTAssertEqual(try bridge.stringValue(path: "String"), "bound")
    }

    func testAppliesImagePayloadsThroughRiveImageProperty() throws {
        let image = try makeRenderImage()
        let bridge = try makeBridge(remoteFlow: makeRemoteFlow())
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        XCTAssertTrue(bridge.applyValue(path: path("Image"), value: image, screenId: "screen-1", instanceId: nil))
    }

    func testEmitsBoundValueChangesFromRiveListeners() throws {
        var changes: [(path: VmPathRef, value: Any, source: String?)] = []
        let bridge = try makeBridge(
            remoteFlow: makeRemoteFlow(),
            onValueChange: { path, value, source in
                changes.append((path, value, source))
            }
        )
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        let property = try XCTUnwrap(bridge.boundInstance?.stringProperty(fromPath: "String"))
        property.value = "from-rive"
        bridge.boundInstance?.updateListeners()

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.path, path("String"))
        XCTAssertEqual(changes.first?.value as? String, "from-rive")
        XCTAssertEqual(changes.first?.source, "rive")
    }

    func testEmitsNameBasedBoundValueChangesWhenPropertyIdsAreAbsent() throws {
        var changes: [(path: VmPathRef, value: Any, source: String?)] = []
        let bridge = try makeBridge(
            remoteFlow: makeRemoteFlow(properties: [
                "String": Nuxie.ViewModelProperty(type: .string, propertyId: nil),
            ]),
            onValueChange: { path, value, source in
                changes.append((path, value, source))
            }
        )
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        let property = try XCTUnwrap(bridge.boundInstance?.stringProperty(fromPath: "String"))
        property.value = "name-based"
        bridge.boundInstance?.updateListeners()

        let emittedPath = try XCTUnwrap(changes.first?.path)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(emittedPath, path("String"))
        XCTAssertEqual(changes.first?.value as? String, "name-based")
        XCTAssertEqual(changes.first?.source, "rive")

        XCTAssertTrue(bridge.applyValue(
            path: emittedPath,
            value: "patched-by-name",
            screenId: "screen-1",
            instanceId: nil
        ))
        XCTAssertEqual(try bridge.stringValue(path: "String"), "patched-by-name")
    }

    func testHostAppliedValuesDoNotReemitBoundValueChanges() throws {
        var changes: [(path: VmPathRef, value: Any, source: String?)] = []
        let bridge = try makeBridge(
            remoteFlow: makeRemoteFlow(),
            onValueChange: { path, value, source in
                changes.append((path, value, source))
            }
        )
        XCTAssertTrue(try bridge.bindDefaultInstanceForActiveArtboard())

        XCTAssertTrue(bridge.applyValue(
            path: path("String"),
            value: "from-host",
            screenId: "screen-1",
            instanceId: nil
        ))

        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(try bridge.stringValue(path: "String"), "from-host")
    }

    func testThrowsWhenWritingBeforeBinding() throws {
        let bridge = try makeBridge()

        XCTAssertThrowsError(try bridge.setString("missing", path: "String")) { error in
            XCTAssertEqual(error as? FlowViewModelBridgeError, .instanceNotBound)
        }
    }

    private func path(
        _ propertyPath: String,
        viewModelName: String? = "Test",
        isRelative: Bool? = nil
    ) -> VmPathRef {
        VmPathRef(viewModelName: viewModelName, path: propertyPath, isRelative: isRelative)
    }

    private func makeSnapshot(_ instances: [Nuxie.ViewModelInstance]) -> FlowViewModelSnapshot {
        FlowViewModelSnapshot(viewModelInstances: instances)
    }

    private func makeInstance(
        viewModelId: String,
        instanceId: String,
        name: String? = nil,
        values: [String: Any]
    ) -> Nuxie.ViewModelInstance {
        Nuxie.ViewModelInstance(
            viewModelId: viewModelId,
            instanceId: instanceId,
            name: name,
            values: values.mapValues(AnyCodable.init)
        )
    }

    private func makeBridge(
        remoteFlow: RemoteFlow? = nil,
        onValueChange: FlowViewModelBridge.ValueChangeHandler? = nil
    ) throws -> FlowViewModelBridge {
        let bundle = Bundle(for: FlowViewModelBridgeTests.self)
        let url = bundle.url(forResource: "data_binding_test", withExtension: "riv", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "data_binding_test", withExtension: "riv")
        let fixtureURL = try XCTUnwrap(url)
        let data = try Data(contentsOf: fixtureURL)
        let file = try RiveFile(data: data, loadCdn: false)
        let model = RiveModel(riveFile: file)
        try model.setArtboard()
        try model.setStateMachine("State Machine 1")
        return FlowViewModelBridge(model: model, remoteFlow: remoteFlow, onValueChange: onValueChange)
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
        properties: [String: Nuxie.ViewModelProperty]? = nil,
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
            properties: properties ?? [
                "String": ViewModelProperty(type: .string, propertyId: 1),
                "Number": ViewModelProperty(type: .list_index, propertyId: 2),
                "Boolean": ViewModelProperty(type: .boolean, propertyId: 3),
                "Trigger Red": ViewModelProperty(type: .trigger, propertyId: 4),
                "List": ViewModelProperty(
                    type: .list,
                    propertyId: 5,
                    itemType: ViewModelProperty(type: .viewModel, viewModelId: "Test")
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
                    defaultViewModelName: viewModel.name,
                    defaultInstanceId: "instance-test"
                ),
            ],
            interactions: [:],
            viewModelValues: nil
        )
    }
}
#endif
