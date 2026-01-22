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
            viewModelId: String? = nil
        ) -> ViewModelProperty {
            return ViewModelProperty(
                type: type,
                propertyId: id,
                defaultValue: defaultValue,
                required: nil,
                enumValues: nil,
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
                version: "v1",
                bundle: FlowBundleRef(
                    url: "https://example.com/flow/runtime",
                    manifest: BuildManifest(
                        totalFiles: 1,
                        totalSize: 100,
                        contentHash: "runtime-hash",
                        files: [BuildFile(path: "index.html", size: 100, contentType: "text/html")]
                    )
                ),
                entryScreenId: "screen-1",
                entryActions: nil,
                screens: [
                    RemoteFlowScreen(
                        id: "screen-1",
                        name: nil,
                        locale: nil,
                        route: nil,
                        defaultViewModelId: defaultViewModelId ?? viewModels.first?.id,
                        defaultInstanceId: nil
                    )
                ],
                interactions: RemoteFlowInteractions(screens: [:], components: nil),
                viewModels: viewModels,
                viewModelInstances: viewModelInstances,
                converters: nil,
                pathIndex: nil
            )
        }

        describe("FlowViewModelRuntime") {
            it("resolves pathIds to the correct view model instance") {
                let flagProperty = makeProperty(type: .boolean, id: 1, defaultValue: AnyCodable(false))
                let countProperty = makeProperty(type: .number, id: 2, defaultValue: AnyCodable(0))

                let viewModelA = ViewModel(
                    id: "vm-a",
                    name: "A",
                    properties: ["flag": flagProperty]
                )
                let viewModelB = ViewModel(
                    id: "vm-b",
                    name: "B",
                    properties: ["count": countProperty]
                )

                let remoteFlow = makeRemoteFlow(
                    viewModels: [viewModelA, viewModelB],
                    defaultViewModelId: viewModelA.id
                )
                let runtime = FlowViewModelRuntime(remoteFlow: remoteFlow)

                let ok = runtime.setValue(path: .ids([1, 2]), value: 7, screenId: "screen-1")
                expect(ok).to(beTrue())

                let count = runtime.getValue(path: .ids([1, 2]), screenId: "screen-1") as? Int
                expect(count).to(equal(7))

                let flag = runtime.getValue(path: .ids([0, 1]), screenId: "screen-1") as? Bool
                expect(flag).to(equal(false))
            }

            it("supports list operations via pathIds") {
                let itemType = makeProperty(type: .number, id: 3)
                let listProperty = makeProperty(type: .list, id: 2, itemType: itemType)
                let viewModel = ViewModel(
                    id: "vm-list",
                    name: "List",
                    properties: ["items": listProperty]
                )
                let runtime = FlowViewModelRuntime(remoteFlow: makeRemoteFlow(viewModels: [viewModel]))

                _ = runtime.setValue(path: .ids([0, 2]), value: [1, 2, 3], screenId: nil)
                _ = runtime.setListValue(
                    path: .ids([0, 2]),
                    operation: "move",
                    payload: ["from": 0, "to": 2],
                    screenId: nil
                )
                var list = runtime.getValue(path: .ids([0, 2]), screenId: nil) as? [Int]
                expect(list).to(equal([2, 3, 1]))

                _ = runtime.setListValue(
                    path: .ids([0, 2]),
                    operation: "swap",
                    payload: ["from": 0, "to": 1],
                    screenId: nil
                )
                list = runtime.getValue(path: .ids([0, 2]), screenId: nil) as? [Int]
                expect(list).to(equal([3, 2, 1]))

                _ = runtime.setListValue(
                    path: .ids([0, 2]),
                    operation: "set",
                    payload: ["index": 1, "value": 9],
                    screenId: nil
                )
                list = runtime.getValue(path: .ids([0, 2]), screenId: nil) as? [Int]
                expect(list).to(equal([3, 9, 1]))

                _ = runtime.setListValue(
                    path: .ids([0, 2]),
                    operation: "remove",
                    payload: ["index": 0],
                    screenId: nil
                )
                list = runtime.getValue(path: .ids([0, 2]), screenId: nil) as? [Int]
                expect(list).to(equal([9, 1]))

                _ = runtime.setListValue(
                    path: .ids([0, 2]),
                    operation: "clear",
                    payload: [:],
                    screenId: nil
                )
                list = runtime.getValue(path: .ids([0, 2]), screenId: nil) as? [Int]
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
                    properties: ["title": titleProperty]
                )
                let runtime = FlowViewModelRuntime(remoteFlow: makeRemoteFlow(viewModels: [viewModel]))

                let title = runtime.getValue(path: .ids([0, 5]), screenId: "screen-1") as? String
                expect(title).to(equal("Hello"))
            }

            it("detects trigger properties via pathIds") {
                let triggerProperty = makeProperty(type: .trigger, id: 7)
                let viewModel = ViewModel(
                    id: "vm-trigger",
                    name: "Trigger",
                    properties: ["pulse": triggerProperty]
                )
                let runtime = FlowViewModelRuntime(remoteFlow: makeRemoteFlow(viewModels: [viewModel]))

                let isTrigger = runtime.isTriggerPath(path: .ids([0, 7]), screenId: "screen-1")
                expect(isTrigger).to(beTrue())
            }
        }
    }
}
