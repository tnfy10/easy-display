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

    func testGuidesMarkSharedEdgeAndAlignedTops() {
        let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let right = CGRect(x: 1920, y: 0, width: 1280, height: 800)
        let guides = DisplayArrangement.guides(for: right, others: [main])
        XCTAssertTrue(guides.contains(.init(axis: .vertical, position: 1920, start: 0, end: 1080)))
        XCTAssertTrue(guides.contains(.init(axis: .horizontal, position: 0, start: 0, end: 3200)))
        XCTAssertFalse(guides.contains { $0.axis == .horizontal && $0.position == 800 })
    }

    /// The real three-monitor row: 4K on the left, built-in (main) in the middle, QHD on the right.
    private var threeInRow: [String: CGRect] {
        ["lg4k": CGRect(x: -1920, y: 180, width: 1920, height: 1080),
         "builtin": CGRect(x: 0, y: 0, width: 1512, height: 982),
         "qhd": CGRect(x: 1512, y: 0, width: 2560, height: 1440)]
    }

    private func assertJoinedWithoutOverlap(_ frames: [String: CGRect], file: StaticString = #filePath, line: UInt = #line) {
        let keys = frames.keys.sorted()
        XCTAssertEqual(DisplayArrangement.connected(frames, from: keys[0]).count, keys.count, "displays left detached", file: file, line: line)
        for (i, a) in keys.enumerated() { for b in keys[(i + 1)...] {
            XCTAssertFalse(DisplayArrangement.overlaps(frames[a]!, frames[b]!), "\(a) overlaps \(b)", file: file, line: line)
        } }
    }

    func testMovingMiddleOfThreeBelowKeepsTheOthersJoined() throws {
        // Dropping the built-in under the 4K pulls it out of the row and would leave a gap between 4K and QHD.
        let dropped = CGRect(x: -1700, y: 1300, width: 1512, height: 982)
        let result = try XCTUnwrap(DisplayArrangement.drop("builtin", at: dropped, frames: threeInRow))
        XCTAssertEqual(result["builtin"]?.minY, 1260)
        XCTAssertEqual(result["lg4k"], threeInRow["lg4k"], "the 4K the built-in was dropped on stays put")
        XCTAssertEqual(result["qhd"]?.minX, 0, "the QHD slides left to touch the 4K")
        assertJoinedWithoutOverlap(result)
    }

    func testReorderingThreeInARowClosesTheGap() throws {
        // Moving the left 4K past the QHD on the right: the built-in and QHD close up behind it.
        let dropped = CGRect(x: 4100, y: 0, width: 1920, height: 1080)
        let result = try XCTUnwrap(DisplayArrangement.drop("lg4k", at: dropped, frames: threeInRow))
        XCTAssertEqual(result["lg4k"]?.minX, 4072)
        XCTAssertEqual(result["builtin"]?.minX, 0)
        assertJoinedWithoutOverlap(result)

        // Moving the middle display to the far right: the outer two must end up side by side.
        let middle = try XCTUnwrap(DisplayArrangement.drop("builtin", at: CGRect(x: 4200, y: 0, width: 1512, height: 982), frames: threeInRow))
        XCTAssertEqual(middle["qhd"]!.minX, middle["lg4k"]!.maxX)
        XCTAssertEqual(middle["builtin"]!.minX, middle["qhd"]!.maxX)
        assertJoinedWithoutOverlap(middle)
    }

    func testMirroringTheMiddleDisplayClosesTheGap() {
        let entries = threeInRow.map { LayoutEntry(uuid: $0.key, origin: $0.value.origin) }
        let sizes = threeInRow.mapValues(\.size)
        // The built-in leaves the row to copy the 4K; the QHD must move over to keep touching the 4K.
        let mirrored = DisplayArrangement.mirroring(entries, display: "builtin", of: "lg4k")
        let result = DisplayArrangement.closingGaps(mirrored, sizes: sizes, anchor: "lg4k")
        let origins = Dictionary(uniqueKeysWithValues: result.map { ($0.uuid, $0.origin) })
        XCTAssertEqual(origins["lg4k"], threeInRow["lg4k"]!.origin)
        XCTAssertEqual(origins["qhd"]??.x, 0)
        XCTAssertEqual(origins["builtin"], .some(nil), "the mirror takes its source's place")
        assertJoinedWithoutOverlap(["lg4k": CGRect(origin: origins["lg4k"]!!, size: sizes["lg4k"]!),
                                    "qhd": CGRect(origin: origins["qhd"]!!, size: sizes["qhd"]!)])

        // Mirroring an end display leaves nothing to close.
        let end = DisplayArrangement.mirroring(entries, display: "qhd", of: "builtin")
        XCTAssertEqual(DisplayArrangement.closingGaps(end, sizes: sizes, anchor: "builtin"), end)
    }

    func testCompactionLeavesJoinedLayoutsAlone() {
        XCTAssertEqual(DisplayArrangement.compacted(threeInRow, anchor: "builtin"), threeInRow)
        XCTAssertFalse(DisplayArrangement.touches(CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 10, y: 10, width: 10, height: 10)),
                       "corner contact does not join displays")
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

    // MARK: - Updater

    func testSemanticVersionComparison() {
        XCTAssertTrue(SemanticVersion.isNewer("v0.10.0", than: "0.9.3"))
        XCTAssertTrue(SemanticVersion.isNewer("0.2.1", than: "0.2"))
        XCTAssertFalse(SemanticVersion.isNewer("v0.2.0", than: "0.2.0"))
        XCTAssertFalse(SemanticVersion.isNewer("0.1.9", than: "0.2.0"))
        XCTAssertEqual(SemanticVersion.parts("v1.2.0-beta+5"), [1, 2, 0])
    }

    func testReleaseParsingPicksAppZipAndRejectsPrereleases() throws {
        let json = """
        {"tag_name":"v0.3.0","body":"notes","html_url":"https://github.com/tnfy10/easy-display/releases/tag/v0.3.0",
         "draft":false,"prerelease":false,"assets":[
          {"name":"other.txt","browser_download_url":"https://github.com/x/other.txt"},
          {"name":"Easy-Display-v0.3.0.zip","browser_download_url":"https://github.com/tnfy10/easy-display/releases/download/v0.3.0/Easy-Display-v0.3.0.zip","digest":"sha256:abc"}]}
        """
        let release = try Updater.parseRelease(Data(json.utf8))
        XCTAssertEqual(release.version, "0.3.0")
        XCTAssertEqual(release.asset.lastPathComponent, "Easy-Display-v0.3.0.zip")
        XCTAssertEqual(release.digest, "sha256:abc")
        XCTAssertThrowsError(try Updater.parseRelease(Data(json.replacingOccurrences(of: "\"prerelease\":false", with: "\"prerelease\":true").utf8)))
        XCTAssertThrowsError(try Updater.parseRelease(Data(json.replacingOccurrences(of: "https://github.com/tnfy10", with: "https://evil.example/tnfy10").utf8)))
    }

    /// Live end-to-end check against GitHub; run with EASY_DISPLAY_NETWORK_TESTS=1.
    func testDownloadsAndVerifiesLatestRelease() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EASY_DISPLAY_NETWORK_TESTS"] == "1")
        let release = try await Updater.latestRelease()
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let app = try await Updater.download(release, into: staging, expectedBundleID: "com.tnfy10.easy-display")
        XCTAssertEqual(Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String, release.version)
        await XCTAssertThrowsErrorAsync { try await Updater.download(release, into: staging, expectedBundleID: "com.other.app") }
    }

    private func XCTAssertThrowsErrorAsync(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("expected error", file: file, line: line) } catch {}
    }
}

final class ColorOutputModeTests: XCTestCase {
    // As reported by SkyLight for a 4K TV on HDMI: 8-bit YCbCr 4:4:4 limited is active.
    let modes: [ColorOutputMode] = [
        .init(depth: 10, range: 0, eotf: 2, encoding: 3), .init(depth: 12, range: 0, eotf: 2, encoding: 2),
        .init(depth: 8, range: 0, eotf: 0, encoding: 1), .init(depth: 10, range: 0, eotf: 0, encoding: 3),
        .init(depth: 8, range: 1, eotf: 0, encoding: 0), .init(depth: 8, range: 0, eotf: 0, encoding: 0),
        .init(depth: 10, range: 1, eotf: 0, encoding: 0),
    ]

    func testLabelsDescribeEncodingRangeDepthAndHDR() {
        XCTAssertEqual(modes[4].label, "RGB · Full · 8비트")
        XCTAssertEqual(modes[2].label, "YCbCr 4:4:4 · Limited · 8비트")
        XCTAssertEqual(modes[0].label, "YCbCr 4:2:0 · Limited · 10비트 · HDR")
    }

    func testWatchdogArgumentRoundTrips() {
        for mode in modes { XCTAssertEqual(ColorOutputMode(argument: mode.argument), mode) }
        XCTAssertNil(ColorOutputMode(argument: "8,1,0"))
        XCTAssertNil(ColorOutputMode(argument: "8,x,0,0"))
    }

    func testRGBTargetKeepsDepthAndHDRStateWhenPossible() {
        let current = modes[2]
        XCTAssertEqual(ColorOutputMode.rgbTarget(fullRange: true, in: modes, current: current), modes[4])
        XCTAssertEqual(ColorOutputMode.rgbTarget(fullRange: false, in: modes, current: current), modes[5])
        // No 10-bit limited RGB: fall back to the deepest limited RGB mode.
        XCTAssertEqual(ColorOutputMode.rgbTarget(fullRange: false, in: modes, current: modes[6]), modes[5])
        // HDR is active and no HDR RGB mode exists, so there is nothing to pick.
        XCTAssertNil(ColorOutputMode.rgbTarget(fullRange: true, in: modes, current: modes[0]))
    }

    func testSortingPutsRGBFullFirst() {
        XCTAssertEqual(modes.filter { !$0.isHDR }.sorted().first, modes[6])
    }
}
