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
}
