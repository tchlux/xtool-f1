import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import xToolF1Core

final class F1ProtocolTests: XCTestCase {
    func testProcessingUploadURLUsesReadyStateEndpoint() throws {
        let url = F1FramingClient(host: "192.168.1.199", port: 8080).uploadProcessingURL(taskID: "task-1")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(components.scheme, "http")
        XCTAssertEqual(components.host, "192.168.1.199")
        XCTAssertEqual(components.port, 8080)
        XCTAssertEqual(components.path, "/processing/upload")
        XCTAssertEqual(query["gcodeType"], "processing")
        XCTAssertEqual(query["fileType"], "txt")
        XCTAssertEqual(query["taskId"], "task-1")
        XCTAssertNil(query["autoStart"])
    }

    func testFrameReplaceURLUsesWalkBorderReplaceEndpoint() throws {
        let url = F1FramingClient(host: "192.168.1.199", port: 8080).replaceFrameURL()
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(components.path, "/processing/replace")
        XCTAssertEqual(query["gcodeType"], "frame")
        XCTAssertEqual(query["loopPrint"], "1")
        XCTAssertNil(query["autoStart"])
    }

    func testReadyStatusParsing() {
        XCTAssertTrue(F1ProcessingStatus(raw: #"{"type":"WORK_PREPARED"}"#).ready)
        XCTAssertTrue(F1ProcessingStatus(raw: #"{"mode":"workReady"}"#).ready)
        XCTAssertTrue(F1ProcessingStatus(raw: #"{"step":"BEFORE_START"}"#).ready)
        XCTAssertFalse(F1ProcessingStatus(raw: #"{"type":"WORK_STARTED"}"#).ready)
        XCTAssertTrue(F1ProcessingStatus(raw: #"{"type":"WORK_STARTED"}"#).working)
        XCTAssertTrue(F1ProcessingStatus(raw: #"{"type":"WORK_FINISHED"}"#).finished)
        XCTAssertTrue(F1ProcessingStatus(raw: #"{"type":"P_WORK_DONE"}"#).finished)
        XCTAssertTrue(F1ProcessingStatus(raw: #"{"type":"WORK_STOPED"}"#).stopped)
        XCTAssertTrue(F1ProcessingStatus(raw: #"{"currentStatus":"IDLE"}"#).idle)
        XCTAssertFalse(F1ProcessingStatus(raw: #"{"type":"UNKNOWN"}"#).finished)
    }

}
