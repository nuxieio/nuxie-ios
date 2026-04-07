import XCTest
@testable import Nuxie

final class ResponseModelContractTests: XCTestCase {
    func testEventTriggerConfigRequiresIRObjectCondition() {
        let data = Data(
            """
            {
              "eventName": "$app_opened",
              "condition": "{\"ir_version\":1,\"expr\":{\"type\":\"Bool\",\"value\":true}}"
            }
            """.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(EventTriggerConfig.self, from: data))
    }

    func testEventResponseDecodesTopLevelEventId() throws {
        let data = Data(
            """
            {
              "status": "ok",
              "eventId": "evt_123",
              "customerId": "cus_123",
              "message": "tracked"
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(EventResponse.self, from: data)

        XCTAssertEqual(response.status, "ok")
        XCTAssertEqual(response.eventId, "evt_123")
        XCTAssertEqual(response.customerId, "cus_123")
        XCTAssertEqual(response.message, "tracked")
    }
}
