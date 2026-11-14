import XCTest
@testable import EasyDisplay

final class DisplayTests: XCTestCase {
    let identity = DisplayIdentity(vendor: 7789, product: 23789, serial: 1234)

    func testUserResolutionsAcceptMultiplicationSymbolAndDeduplicate() throws {
        let values = try CustomResolution.parse("1920 × 1080, 2048x1152\n1920x1080")
        XCTAssertEqual(values.map(\.id), ["1920x1080", "2048x1152"])
    }

    func testUnsafeOrMalformedDimensionsAreRejected() {
        for input in ["", "0x1080", "-1920x1080", "999999999999999999999x1080", "3841x2160", "1920x2161", "1920x1080x2", "1920x", "NaNx1080", "640x359"] {
            XCTAssertThrowsError(try CustomResolution.parse(input), input)
        }
        XCTAssertThrowsError(try CustomResolution.parse(Array(repeating: "1920x1080", count: 25).joined(separator: ",")))
    }

    func testHiDPIIsEncodedAsBigEndianDoubleResolutionWithFlags() {
        let res = CustomResolution(width: 1920, height: 1080)
        let base = OverrideStore.encodedResolution(res, extended: false)
        XCTAssertEqual(Array(base), [0,0,15,0, 0,0,8,112, 0,0,0,1])
        XCTAssertEqual(Array(OverrideStore.encodedResolution(res, extended: true)), Array(base) + [0,32,0,0])
    }

    func testMergePreservesExistingKeysAndResolutionEntries() throws {
        let existingEntry = Data([0, 0, 1, 0])
        let before: [String: Any] = ["DisplayVendorID": 7789, "DisplayProductID": 23789,
                                     "DisplayProductName": "My Monitor", "scale-resolutions": [existingEntry],
                                     "unrelated-setting": true]
        let original = try PropertyListSerialization.data(fromPropertyList: before, format: .xml, options: 0)
        let res = CustomResolution(width: 1920, height: 1080)
        let after = try OverrideStore.merged(original: original, identity: identity, resolutions: [res])
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: after, format: nil) as? [String: Any])
        XCTAssertEqual(plist["DisplayProductName"] as? String, "My Monitor")
        XCTAssertEqual(plist["unrelated-setting"] as? Bool, true)
        let entries = try XCTUnwrap(plist["scale-resolutions"] as? [Data])
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.first, existingEntry)
        let twice = try OverrideStore.merged(original: after, identity: identity, resolutions: [res])
        let plistTwice = try XCTUnwrap(PropertyListSerialization.propertyList(from: twice, format: nil) as? [String: Any])
        XCTAssertEqual((plistTwice["scale-resolutions"] as? [Data])?.count, 3)
    }

    func testMismatchedExistingOverrideIsNotOverwritten() throws {
        let original = try PropertyListSerialization.data(fromPropertyList: ["DisplayProductID": 999], format: .xml, options: 0)
        XCTAssertThrowsError(try OverrideStore.merged(original: original, identity: identity, resolutions: [.init(width: 1920, height: 1080)]))
        XCTAssertThrowsError(try OverrideStore.merged(original: Data("broken".utf8), identity: identity, resolutions: []))
    }

    func testModeDeduplicationRetainsHiDPIAndRefreshRateChoices() {
        let modes = [
            DisplayMode(id: 1, width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 120),
            DisplayMode(id: 2, width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 120),
            DisplayMode(id: 3, width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 120),
            DisplayMode(id: 4, width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60)
        ]
        let result = DisplayMode.distinct(modes)
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result[0].isHiDPI)
        XCTAssertEqual(result[0].refreshRate, 120)
        XCTAssertEqual(result[1].refreshRate, 60)
        XCTAssertFalse(result[2].isHiDPI)
    }

    func testRestoreTargetIsScopedToVendorAndProduct() {
        XCTAssertEqual(OverrideStore.target(identity).path, "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-1e6d/DisplayProductID-5ced")
        let second = DisplayIdentity(vendor: 7789, product: 30470, serial: 1)
        XCTAssertNotEqual(OverrideStore.target(identity), OverrideStore.target(second))
    }

    func testRepeatedInstallPreservesOriginallyAbsentFileForUndo() {
        let current = Data("installed override".utf8)
        let backup = OverrideBackup(original: nil, installedHash: "hash", identity: identity)
        XCTAssertNil(OverrideStore.originalForBackup(existing: backup, current: current))
        XCTAssertEqual(OverrideStore.originalForBackup(existing: nil, current: current), current)
    }

    func testMalformedExistingScaleEntriesAreNotDiscarded() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["scale-resolutions": "invalid"], format: .xml, options: 0)
        XCTAssertThrowsError(try OverrideStore.merged(original: data, identity: identity, resolutions: []))
    }

    func testShellQuoteProtectsSingleQuotesAndSubstitutions() {
        XCTAssertEqual(OverrideStore.shellQuote("a'b$(touch /tmp/no)"), "'a'\\''b$(touch /tmp/no)'")
    }

    // MARK: - Arrangement

    func testDroppedDisplaySnapsToNearestEdgeAndAlignsTops() {
        let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let dropped = CGRect(x: 2000, y: 30, width: 2560, height: 1440)
        XCTAssertEqual(DisplayArrangement.snap(dropped, others: [main]), CGPoint(x: 1920, y: 0))
        let above = CGRect(x: 300, y: -1500, width: 1280, height: 800)
        XCTAssertEqual(DisplayArrangement.snap(above, others: [main]), CGPoint(x: 320, y: -800))
    }

    func testSnapNeverOverlapsAndKeepsSharedEdge() {
        let a = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let b = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let dropped = CGRect(x: 1000, y: 100, width: 1920, height: 1080)
        let origin = try! XCTUnwrap(DisplayArrangement.snap(dropped, others: [a, b]))
        let placed = CGRect(origin: origin, size: dropped.size)
        XCTAssertFalse(DisplayArrangement.overlaps(placed, a))
        XCTAssertFalse(DisplayArrangement.overlaps(placed, b))
        // Far below: must still be clamped to touch, not float away.
        let far = DisplayArrangement.snap(CGRect(x: 0, y: 5000, width: 800, height: 600), others: [a])
        XCTAssertEqual(far?.y, 1080)
    }

    func testNormalizationPutsMainAtOrigin() {
        let result = DisplayArrangement.normalized(["a": CGPoint(x: 100, y: -50), "b": CGPoint(x: 2020, y: 0)], main: "a")
        XCTAssertEqual(result["a"], .zero)
        XCTAssertEqual(result["b"], CGPoint(x: 1920, y: 50))
    }

    func testMirroringRedirectsChainsAndSwapsRoles() {
        let entries = [LayoutEntry(uuid: "a", origin: .zero, modeID: 1),
                       LayoutEntry(uuid: "b", origin: CGPoint(x: 1920, y: 0), modeID: 2),
                       LayoutEntry(uuid: "c", origin: CGPoint(x: 3840, y: 0), mirrorOf: "b")]
        // b follows a; c (which followed b) must follow a too, since sets are one level deep.
        let mirrored = DisplayArrangement.mirroring(entries, display: "b", of: "a")
        XCTAssertEqual(mirrored.map(\.mirrorOf), [nil, "a", "a"])
        XCTAssertNil(mirrored[1].origin)
        XCTAssertTrue(mirrored.allSatisfy { $0.modeID == nil })
        // Choosing a display's own follower as source swaps them.
        let swapped = DisplayArrangement.mirroring(entries, display: "b", of: "c")
        XCTAssertEqual(swapped.map(\.mirrorOf), [nil, "c", nil])
        // Extending clears mirroring and lets macOS place former mirrors.
        let extended = DisplayArrangement.extendAll(DisplayArrangement.mirrorAll(entries, to: "a"))
        XCTAssertEqual(extended.map(\.mirrorOf), [nil, nil, nil])
        XCTAssertEqual(extended[0].origin, .zero)
        XCTAssertNil(extended[1].origin)
    }

    func testLayoutSnapshotRoundTripsForWatchdog() throws {
        let entries = [LayoutEntry(uuid: "a", origin: CGPoint(x: -1920, y: 12), mirrorOf: nil, modeID: 7),
                       LayoutEntry(uuid: "b", origin: nil, mirrorOf: "a", modeID: nil)]
        let data = try XCTUnwrap(Data(base64Encoded: try JSONEncoder().encode(entries).base64EncodedString()))
        XCTAssertEqual(try JSONDecoder().decode([LayoutEntry].self, from: data), entries)
    }
}
