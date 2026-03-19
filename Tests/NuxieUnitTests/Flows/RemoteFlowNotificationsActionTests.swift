import XCTest
@testable import Nuxie

final class RemoteFlowNotificationsActionTests: XCTestCase {
    func testDecodesRequestNotificationsAction() throws {
        let data = Data(
            """
            {
              "type": "request_notifications"
            }
            """.utf8
        )

        let action = try JSONDecoder().decode(InteractionAction.self, from: data)

        switch action {
        case .requestNotifications(let requestNotifications):
            XCTAssertEqual(requestNotifications.type, "request_notifications")
        default:
            XCTFail("Expected request_notifications action")
        }
    }

    func testEncodesRequestNotificationsAction() throws {
        let action = InteractionAction.requestNotifications(RequestNotificationsAction())

        let data = try JSONEncoder().encode(action)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(decoded?["type"] as? String, "request_notifications")
    }

    func testDecodesRequestTrackingAction() throws {
        let data = Data(
            """
            {
              "type": "request_tracking"
            }
            """.utf8
        )

        let action = try JSONDecoder().decode(InteractionAction.self, from: data)

        switch action {
        case .requestTracking(let requestTracking):
            XCTAssertEqual(requestTracking.type, "request_tracking")
        default:
            XCTFail("Expected request_tracking action")
        }
    }

    func testEncodesRequestTrackingAction() throws {
        let action = InteractionAction.requestTracking(RequestTrackingAction())

        let data = try JSONEncoder().encode(action)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(decoded?["type"] as? String, "request_tracking")
    }
}
