import Foundation
import Quick
import Nimble
@testable import Nuxie

final class FlowViewModelRuntimeTests: QuickSpec {
    override class func spec() {
        func makeProperty(
            type: ViewModelPropertyType,
            id: Int,
            defaultValue: AnyCodable? = nil,
            itemType: ViewModelProperty? = nil,
            schema: [String: ViewModelProperty]? = nil,
            viewModelId: String? = nil,
            enumValues: [String]? = nil
        ) -> ViewModelProperty {
            return ViewModelProperty(
                type: type,
                propertyId: id,
                defaultValue: defaultValue,
                required: nil,
                enumValues: enumValues,
                itemType: itemType,
                schema: schema,
                viewModelId: viewModelId,
                validation: nil
            )
        }

        func makeRemoteFlow(
            viewModels: [ViewModel],
            viewModelInstances: [ViewModelInstance]? = nil,
            defaultViewModelId: String? = nil
        ) -> RemoteFlow {
            return RemoteFlow(
                id: "flow-runtime",
                bundle: FlowBundleRef(
                    url: "https://example.com/flow/runtime",
                    manifest: BuildManifest(
                        totalFiles: 1,
                        totalSize: 100,
                        contentHash: "runtime-hash",
                        files: [BuildFile(path: "index.html", size: 100, contentType: "text/html")]
                    )
                ),
                screens: [
                    RemoteFlowScreen(
                        id: "screen-1",
                        defaultViewModelId: defaultViewModelId ?? viewModels.first?.id,
                        defaultInstanceId: nil
                    )
                ],
                interactions: [:],
                viewModels: viewModels,
                viewModelInstances: viewModelInstances,
                converters: nil,
            )
        }

        describe("FlowViewModelRuntime") {
            it("resolves pathIds to the correct view model instance") {
                let flagProperty = makeProperty(type: .boolean, id: 1, defaultValue: AnyCodable(false))
                let countProperty = makeProperty(type: .number, id: 2, defaultValue: AnyCodable(0))

                let viewModelA = ViewModel(
                    id: "vm-a",
                    name: "A",
                    viewModelPathId: 0,
                    properties: ["flag": flagProperty]
                )
                let viewModelB = ViewModel(
                    id: "vm-b",
                    name: "B",
                    viewModelPathId: 1,
                    properties: ["count": countProperty]
                )

                let remoteFlow = makeRemoteFlow(
                    viewModels: [viewModelA, viewModelB],
                    defaultViewModelId: viewModelA.id
                )
                let runtime = FlowViewModelRuntime(remoteFlow: remoteFlow)

                let ok = runtime.setValue(path: .ids(VmPathIds(pathIds: [1, 2])), value: 7, screenId: "screen-1")
                expect(ok).to(beTrue())

                let count = runtime.getValue(path: .ids(VmPathIds(pathIds: [1, 2])), screenId: "screen-1") as? Int
                expect(count).to(equal(7))

                let flag = runtime.getValue(path: .ids(VmPathIds(pathIds: [0, 1])), screenId: "screen-1") as? Bool
                expect(flag).to(equal(false))
            }

            it("supports list operations via pathIds") {
                let itemType = makeProperty(type: .number, id: 3)
                let listProperty = makeProperty(type: .list, id: 2, itemType: itemType)
                let viewModel = ViewModel(
                    id: "vm-list",
                    name: "List",
                    viewModelPathId: 0,
                    properties: ["items": listProperty]
                )
                let runtime = FlowViewModelRuntime(remoteFlow: makeRemoteFlow(viewModels: [viewModel]))

                _ = runtime.setValue(path: .ids(VmPathIds(pathIds: [0, 2])), value: [1, 2, 3], screenId: nil)
                _ = runtime.setListValue(
                    path: .ids(VmPathIds(pathIds: [0, 2])),
                    operation: "move",
                    payload: ["from": 0, "to": 2],
                    screenId: nil
                )
                var list = runtime.getValue(path: .ids(VmPathIds(pathIds: [0, 2])), screenId: nil) as? [Int]
                expect(list).to(equal([2, 3, 1]))

                _ = runtime.setListValue(
                    path: .ids(VmPathIds(pathIds: [0, 2])),
                    operation: "swap",
                    payload: ["from": 0, "to": 1],
                    screenId: nil
                )
                list = runtime.getValue(path: .ids(VmPathIds(pathIds: [0, 2])), screenId: nil) as? [Int]
                expect(list).to(equal([3, 2, 1]))

                _ = runtime.setListValue(
                    path: .ids(VmPathIds(pathIds: [0, 2])),
                    operation: "set",
                    payload: ["index": 1, "value": 9],
                    screenId: nil
                )
                list = runtime.getValue(path: .ids(VmPathIds(pathIds: [0, 2])), screenId: nil) as? [Int]
                expect(list).to(equal([3, 9, 1]))

                _ = runtime.setListValue(
                    path: .ids(VmPathIds(pathIds: [0, 2])),
                    operation: "remove",
                    payload: ["index": 0],
                    screenId: nil
                )
                list = runtime.getValue(path: .ids(VmPathIds(pathIds: [0, 2])), screenId: nil) as? [Int]
                expect(list).to(equal([9, 1]))

                _ = runtime.setListValue(
                    path: .ids(VmPathIds(pathIds: [0, 2])),
                    operation: "clear",
                    payload: [:],
                    screenId: nil
                )
                list = runtime.getValue(path: .ids(VmPathIds(pathIds: [0, 2])), screenId: nil) as? [Int]
                expect(list).to(equal([]))
            }

            it("applies default values to new instances") {
                let titleProperty = makeProperty(
                    type: .string,
                    id: 5,
                    defaultValue: AnyCodable("Hello")
                )
                let viewModel = ViewModel(
                    id: "vm-default",
                    name: "Default",
                    viewModelPathId: 0,
                    properties: ["title": titleProperty]
                )
                let runtime = FlowViewModelRuntime(remoteFlow: makeRemoteFlow(viewModels: [viewModel]))

                let title = runtime.getValue(path: .ids(VmPathIds(pathIds: [0, 5])), screenId: "screen-1") as? String
                expect(title).to(equal("Hello"))
            }

            it("applies concrete defaults when missing explicit defaults") {
                let titleProperty = makeProperty(type: .string, id: 10)
                let countProperty = makeProperty(type: .number, id: 11)
                let flagProperty = makeProperty(type: .boolean, id: 12)
                let colorProperty = makeProperty(type: .color, id: 13)
                let enumProperty = makeProperty(type: .enum, id: 14, enumValues: ["alpha", "beta"])
                let listProperty = makeProperty(
                    type: .list,
                    id: 15,
                    itemType: makeProperty(type: .string, id: 16)
                )
                let nestedFlag = makeProperty(type: .boolean, id: 18)
                let objectProperty = makeProperty(
                    type: .object,
                    id: 17,
                    schema: ["nestedFlag": nestedFlag]
                )
                let triggerProperty = makeProperty(type: .trigger, id: 19)
                let listIndexProperty = makeProperty(type: .list_index, id: 20)

                let viewModel = ViewModel(
                    id: "vm-fallback",
                    name: "Fallback",
                    viewModelPathId: 0,
                    properties: [
                        "title": titleProperty,
                        "count": countProperty,
                        "flag": flagProperty,
                        "color": colorProperty,
                        "choice": enumProperty,
                        "items": listProperty,
                        "meta": objectProperty,
                        "pulse": triggerProperty,
                        "index": listIndexProperty
                    ]
                )

                let runtime = FlowViewModelRuntime(remoteFlow: makeRemoteFlow(viewModels: [viewModel]))

                expect(runtime.getValue(path: .ids(VmPathIds(pathIds: [0, 10])), screenId: "screen-1") as? String)
                    .to(equal(""))
                expect(runtime.getValue(path: .ids(VmPathIds(pathIds: [0, 11])), screenId: "screen-1") as? Int)
                    .to(equal(0))
                expect(runtime.getValue(path: .ids(VmPathIds(pathIds: [0, 12])), screenId: "screen-1") as? Bool)
                    .to(equal(false))
                expect(runtime.getValue(path: .ids(VmPathIds(pathIds: [0, 13])), screenId: "screen-1") as? String)
                    .to(equal(""))
                expect(runtime.getValue(path: .ids(VmPathIds(pathIds: [0, 14])), screenId: "screen-1") as? String)
                    .to(equal("alpha"))
                let list = runtime.getValue(path: .ids(VmPathIds(pathIds: [0, 15])), screenId: "screen-1") as? [Any]
                expect(list?.isEmpty).to(beTrue())
                expect(runtime.getValue(path: .ids(VmPathIds(pathIds: [0, 17, 18])), screenId: "screen-1") as? Bool)
                    .to(equal(false))
                expect(runtime.getValue(path: .ids(VmPathIds(pathIds: [0, 19])), screenId: "screen-1") as? Int)
                    .to(equal(0))
                expect(runtime.getValue(path: .ids(VmPathIds(pathIds: [0, 20])), screenId: "screen-1") as? Int)
                    .to(equal(0))
            }

            it("detects trigger properties via pathIds") {
                let triggerProperty = makeProperty(type: .trigger, id: 7)
                let viewModel = ViewModel(
                    id: "vm-trigger",
                    name: "Trigger",
                    viewModelPathId: 0,
                    properties: ["pulse": triggerProperty]
                )
                let runtime = FlowViewModelRuntime(remoteFlow: makeRemoteFlow(viewModels: [viewModel]))

                let isTrigger = runtime.isTriggerPath(path: .ids(VmPathIds(pathIds: [0, 7])), screenId: "screen-1")
                expect(isTrigger).to(beTrue())
            }
        }
    }
}
