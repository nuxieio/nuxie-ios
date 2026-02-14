import Foundation
import Quick
import Nimble
@testable import Nuxie

final class FlowRuntimeTraceTests: QuickSpec {
    override class func spec() {
        func makeFlow(id: String = "trace-flow") -> Flow {
            let remoteFlow = RemoteFlow(
                id: id,
                bundle: FlowBundleRef(
                    url: "https://cdn.example/\(id)/index.html",
                    manifest: BuildManifest(
                        totalFiles: 1,
                        totalSize: 100,
                        contentHash: "hash-\(id)",
                        files: [BuildFile(path: "index.html", size: 100, contentType: "text/html")]
                    )
                ),
                screens: [RemoteFlowScreen(id: "screen-entry", defaultViewModelId: nil, defaultInstanceId: nil)],
                interactions: [:],
                viewModels: [],
                viewModelInstances: nil,
                converters: nil
            )
            return Flow(remoteFlow: remoteFlow, products: [])
        }

        final class TraceOnlyRuntimeDelegate: FlowRuntimeDelegate {
            private let recorder: FlowRuntimeTraceRecorder

            init(recorder: FlowRuntimeTraceRecorder) {
                self.recorder = recorder
            }

            func flowViewController(
                _ controller: FlowViewController,
                didReceiveRuntimeMessage type: String,
                payload: [String : Any],
                id: String?
            ) {}

            func flowViewController(
                _ controller: FlowViewController,
                didSendRuntimeMessage type: String,
                payload: [String : Any],
                replyTo: String?
            ) {
                recorder.recordRuntimeMessage(type: type, payload: payload)
            }

            func flowViewControllerDidRequestDismiss(_ controller: FlowViewController, reason: CloseReason) {}
        }

        describe("FlowRuntimeTraceRecorder") {
            it("records navigation and binding entries in deterministic step order") {
                let recorder = FlowRuntimeTraceRecorder()

                recorder.recordRuntimeMessage(
                    type: "runtime/navigate",
                    payload: ["screenId": "screen-2"]
                )
                recorder.recordRuntimeMessage(
                    type: "action/did_set",
                    payload: [
                        "screenId": "screen-2",
                        "pathIds": [1, 2, 3],
                        "source": "input",
                        "value": ["title": "Hello", "count": 2],
                    ]
                )
                recorder.recordRuntimeMessage(
                    type: "runtime/screen_changed",
                    payload: ["screenId": "screen-2"]
                )

                let trace = recorder.trace(
                    fixtureId: "fixture-nav-binding",
                    rendererBackend: "react"
                )

                expect(trace.schemaVersion).to(equal(FlowRuntimeTrace.currentSchemaVersion))
                expect(trace.entries.map(\.step)).to(equal([1, 2, 3]))

                expect(trace.entries[0].kind).to(equal(.navigation))
                expect(trace.entries[0].name).to(equal("navigate"))
                expect(trace.entries[0].output).to(equal("screen-2"))

                expect(trace.entries[1].kind).to(equal(.binding))
                expect(trace.entries[1].name).to(equal("did_set"))
                expect(trace.entries[1].screenId).to(equal("screen-2"))
                expect(trace.entries[1].output).to(contain("\"path_ids\":[1,2,3]"))
                expect(trace.entries[1].output).to(contain("\"title\":\"Hello\""))
                expect(trace.entries[1].metadata?["source"]).to(equal("input"))

                expect(trace.entries[2].kind).to(equal(.navigation))
                expect(trace.entries[2].name).to(equal("screen_changed"))
            }

            it("records event entries with canonicalized properties") {
                let recorder = FlowRuntimeTraceRecorder()

                recorder.recordEvent(
                    name: "$flow_shown",
                    properties: [
                        "flow_id": "flow-1",
                        "screen_id": "screen-entry",
                        "nested": ["b": 2, "a": 1],
                    ]
                )

                let trace = recorder.trace(
                    fixtureId: "fixture-events",
                    rendererBackend: "react"
                )
                let entry = trace.entries.first

                expect(entry?.kind).to(equal(.event))
                expect(entry?.name).to(equal("$flow_shown"))
                expect(entry?.screenId).to(equal("screen-entry"))
                expect(entry?.output).to(equal("{\"flow_id\":\"flow-1\",\"nested\":{\"a\":1,\"b\":2},\"screen_id\":\"screen-entry\"}"))
            }

            it("ingests tracked events and supports codable round-trip") {
                let recorder = FlowRuntimeTraceRecorder()
                recorder.ingestTrackedEvents([
                    (name: "$flow_artifact_load_succeeded", properties: ["flow_id": "flow-abc"]),
                    (name: "$flow_dismissed", properties: ["flow_id": "flow-abc"]),
                ])

                let trace = recorder.trace(
                    fixtureId: "fixture-round-trip",
                    rendererBackend: "rive"
                )

                let data = try! JSONEncoder().encode(trace)
                let decoded = try! JSONDecoder().decode(FlowRuntimeTrace.self, from: data)

                expect(decoded).to(equal(trace))
                expect(decoded.entries.map(\.kind)).to(equal([.event, .event]))
            }

            it("records host-sent runtime navigation messages via runtime delegate") { @MainActor in
                let recorder = FlowRuntimeTraceRecorder()
                let delegate = TraceOnlyRuntimeDelegate(recorder: recorder)

                let viewController = FlowViewController(
                    flow: makeFlow(id: "trace-host-sent"),
                    archiveService: FlowArchiver()
                )
                viewController.runtimeDelegate = delegate

                viewController.sendRuntimeMessage(
                    type: "runtime/navigate",
                    payload: ["screenId": "screen-2"]
                )

                let trace = recorder.trace(
                    fixtureId: "fixture-host-sent-navigation",
                    rendererBackend: "react"
                )
                guard let entry = trace.entries.first else {
                    fail("Expected at least one trace entry")
                    return
                }

                expect(entry.kind).to(equal(.navigation))
                expect(entry.name).to(equal("navigate"))
                expect(entry.screenId).to(equal("screen-2"))
            }
        }
    }
}
