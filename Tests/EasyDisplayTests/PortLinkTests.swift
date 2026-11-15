import XCTest
@testable import EasyDisplay

final class PortLinkTests: XCTestCase {
    func testParsesIOKitTransportProperties() throws {
        let sample = try XCTUnwrap(PortLinkSample(properties: [
            "ParentBuiltInPortTypeDescription": "HDMI", "ParentBuiltInPortNumber": NSNumber(value: 1),
            "HPD_StateDescription": "High", "SinkCount": NSNumber(value: 0), "Tunneled": false
        ]))
        XCTAssertTrue(sample.isStalled)
        XCTAssertEqual(sample.key, "HDMI-1")
        XCTAssertEqual(sample.portLabel, "HDMI 포트")
    }

    func testFallsBackToNumericHotPlugStateAndRejectsUnknownLayouts() {
        let linked = PortLinkSample(properties: [
            "ParentBuiltInPortTypeDescription": "USB-C", "ParentBuiltInPortNumber": NSNumber(value: 2),
            "HPD_State": NSNumber(value: 2), "SinkCount": NSNumber(value: 1), "Tunneled": true
        ])
        XCTAssertEqual(linked?.isStalled, false)
        XCTAssertEqual(linked?.portLabel, "USB-C 포트 2 (썬더볼트 독)")
        XCTAssertNil(PortLinkSample(properties: ["SinkCount": NSNumber(value: 0)]))
    }

    func testNoCableOrLinkedMonitorIsNotStalled() {
        XCTAssertFalse(PortLinkSample(portType: "HDMI", portNumber: 1, hotPlug: false, sinkCount: 0).isStalled)
        XCTAssertFalse(PortLinkSample(portType: "HDMI", portNumber: 1, hotPlug: true, sinkCount: 1).isStalled)
    }

    func testReportsOnlyAfterStalledForThreshold() {
        var tracker = PortLinkTracker(threshold: 8)
        let stalled = [PortLinkSample(portType: "HDMI", portNumber: 1, hotPlug: true, sinkCount: 0)]
        let start = Date()
        XCTAssertTrue(tracker.update(stalled, now: start).isEmpty)
        XCTAssertTrue(tracker.update(stalled, now: start + 4).isEmpty)
        XCTAssertEqual(tracker.update(stalled, now: start + 8).map(\.id), ["HDMI-1"])
    }

    func testRecoveryResetsTheTimer() {
        var tracker = PortLinkTracker(threshold: 8)
        let stalled = [PortLinkSample(portType: "HDMI", portNumber: 1, hotPlug: true, sinkCount: 0)]
        let linked = [PortLinkSample(portType: "HDMI", portNumber: 1, hotPlug: true, sinkCount: 1)]
        let start = Date()
        _ = tracker.update(stalled, now: start)
        XCTAssertTrue(tracker.update(linked, now: start + 5).isEmpty)
        XCTAssertTrue(tracker.update(stalled, now: start + 10).isEmpty)
        XCTAssertEqual(tracker.update(stalled, now: start + 18).count, 1)
    }
}

final class MirrorSourceTests: XCTestCase {
    func testCurrentMirrorCanBecomeTheSource() {
        let entries = [LayoutEntry(uuid: "A", origin: .zero), LayoutEntry(uuid: "B", origin: .zero, mirrorOf: "A")]
        let result = DisplayArrangement.mirrorAll(entries, to: "B")
        XCTAssertNil(result.first { $0.uuid == "B" }?.mirrorOf)
        XCTAssertEqual(result.first { $0.uuid == "A" }?.mirrorOf, "B")
    }
}
