import CoreGraphics
import Foundation
import XCTest
@testable import RingCore

final class MultiTypeSlotTests: XCTestCase {

    // MARK: - 1. v0.2.5 Configuration Backward Compatibility & Validation

    func testV025LegacyConfigurationDecodesLegacyAppAndDefaultsShowCenterLabelOnHoverToTrue() throws {
        let id0 = UUID()
        let id1 = UUID()
        let id6 = UUID()
        let legacyJSON = """
        {
          "version": 1,
          "visibleSlotCount": 4,
          "entranceDurationMilliseconds": 180,
          "hapticFeedbackEnabled": false,
          "slots": [
            {
              "id": "\(id0.uuidString)",
              "app": {
                "bundleIdentifier": "com.apple.Safari",
                "displayName": "Safari",
                "path": "/Applications/Safari.app"
              }
            },
            {
              "id": "\(id1.uuidString)",
              "app": null
            },
            {"id": "\(UUID().uuidString)"},
            {"id": "\(UUID().uuidString)"},
            {"id": "\(UUID().uuidString)"},
            {"id": "\(UUID().uuidString)"},
            {
              "id": "\(id6.uuidString)",
              "app": {
                "bundleIdentifier": "com.apple.Notes",
                "displayName": "Notes",
                "path": "/Applications/Notes.app"
              }
            },
            {"id": "\(UUID().uuidString)"}
          ]
        }
        """.data(using: .utf8)!

        let decoded = try LauncherConfiguration.decoded(from: legacyJSON)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.visibleSlotCount, 4)
        XCTAssertEqual(decoded.entranceDurationMilliseconds, 180)
        XCTAssertFalse(decoded.hapticFeedbackEnabled)
        XCTAssertTrue(decoded.showCenterLabelOnHover, "缺失 showCenterLabelOnHover 时默认应为 true")
        XCTAssertEqual(decoded.slots[0].id, id0)
        XCTAssertEqual(decoded.slots[0].action, .app(AppReference(bundleIdentifier: "com.apple.Safari",
                                                                   displayName: "Safari",
                                                                   path: "/Applications/Safari.app")))
        XCTAssertFalse(decoded.slots[1].isFilled)
        XCTAssertEqual(decoded.slots[6].id, id6)
        XCTAssertEqual(decoded.slots[6].displayName, "Notes", "隐藏尾部槽位必须完整保留")
    }

    func testShowCenterLabelOnHoverRoundTripAndInvalidTypeRejection() throws {
        var config = LauncherConfiguration.empty()
        config.showCenterLabelOnHover = false
        let encoded = try config.encoded()
        let decoded = try LauncherConfiguration.decoded(from: encoded)
        XCTAssertFalse(decoded.showCenterLabelOnHover)

        let badJSON = """
        {"version": 1, "showCenterLabelOnHover": "yes", "slots": []}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try LauncherConfiguration.decoded(from: badJSON))
    }

    func testValidationRejectsInvalidFieldsAcrossAllSlotActionTypes() {
        let invalidWebURL = Slot(action: .webURL(WebURLReference(urlString: "javascript:alert(1)", displayName: "Bad")))
        XCTAssertThrowsError(try LauncherConfiguration(slots: [invalidWebURL]).validate())

        let emptyWebName = Slot(action: .webURL(WebURLReference(urlString: "https://github.com", displayName: "   ")))
        XCTAssertThrowsError(try LauncherConfiguration(slots: [emptyWebName]).validate())

        let emptyBrowserPath = Slot(action: .webURL(WebURLReference(
            urlString: "https://github.com",
            displayName: "GitHub",
            preferredBrowser: AppReference(bundleIdentifier: "com.google.Chrome", displayName: "Chrome", path: "")
        )))
        XCTAssertThrowsError(try LauncherConfiguration(slots: [emptyBrowserPath]).validate())

        let emptyFilePath = Slot(action: .file(FileReference(path: "", displayName: "Folder", isDirectory: true)))
        XCTAssertThrowsError(try LauncherConfiguration(slots: [emptyFilePath]).validate())

        let emptyFileName = Slot(action: .file(FileReference(path: "/tmp", displayName: "  ", isDirectory: true)))
        XCTAssertThrowsError(try LauncherConfiguration(slots: [emptyFileName]).validate())
    }

    // MARK: - 2. WebURLValidator & HTML Metadata Parser

    func testWebURLValidatorAutoCompletesBareDomainsAndPaths() {
        XCTAssertEqual(WebURLValidator.validate("github.com"),
                       .valid(normalizedURLString: "https://github.com", isWebPage: true))
        XCTAssertEqual(WebURLValidator.validate("  github.com/1993yihuan/Ring  "),
                       .valid(normalizedURLString: "https://github.com/1993yihuan/Ring", isWebPage: true))
        XCTAssertEqual(WebURLValidator.validate("localhost:3000"),
                       .valid(normalizedURLString: "https://localhost:3000", isWebPage: true))
        XCTAssertEqual(WebURLValidator.validate("http://example.com/docs"),
                       .valid(normalizedURLString: "http://example.com/docs", isWebPage: true))
    }

    func testWebURLValidatorSupportsCustomDeepLinks() {
        XCTAssertEqual(WebURLValidator.validate("obsidian://open?vault=Notes"),
                       .valid(normalizedURLString: "obsidian://open?vault=Notes", isWebPage: false))
        XCTAssertEqual(WebURLValidator.validate("notion://www.notion.so/my-page"),
                       .valid(normalizedURLString: "notion://www.notion.so/my-page", isWebPage: false))
        XCTAssertEqual(WebURLValidator.validate("vscode://file/Users/dev/project"),
                       .valid(normalizedURLString: "vscode://file/Users/dev/project", isWebPage: false))
        XCTAssertEqual(WebURLValidator.validate("mailto:hello@example.com"),
                       .valid(normalizedURLString: "mailto:hello@example.com", isWebPage: false))
    }

    func testWebURLValidatorBlocksEmptyMalformedAndDangerousSchemes() {
        let blocked = [
            "",
            "   ",
            "hello",
            "not a valid url",
            "https://",
            "obsidian://",
            "mailto:",
            "javascript:alert(1)",
            "JAVASCRIPT:void(0)",
            "data:text/html,<script>alert(1)</script>",
            "vbscript:msgbox(1)",
            "file:///etc/passwd",
            "file:/Users/test"
        ]
        for input in blocked {
            if case .valid = WebURLValidator.validate(input) {
                XCTFail("Expected '\(input)' to be rejected")
            }
        }
    }

    func testWebURLDefaultDisplayNameExtraction() {
        XCTAssertEqual(WebURLValidator.defaultDisplayName(for: "https://github.com/1993yihuan/Ring",
                                                          pageTitle: "  1993yihuan/Ring  "),
                       "1993yihuan/Ring")
        XCTAssertEqual(WebURLValidator.defaultDisplayName(for: "https://www.github.com/1993yihuan/Ring",
                                                          pageTitle: "   "),
                       "github.com")
        XCTAssertEqual(WebURLValidator.defaultDisplayName(for: "github.com/docs"),
                       "github.com")
        XCTAssertEqual(WebURLValidator.defaultDisplayName(for: "obsidian://open?vault=Notes"),
                       "open")
        XCTAssertEqual(WebURLValidator.defaultDisplayName(for: "mailto:team@example.com"),
                       "team@example.com")
    }

    func testHTMLMetadataParserExtractsTitleAndPrioritizesIcons() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://example.com/docs/intro"))
        let html = """
        <html>
          <head>
            <title>Ring &amp; Docs &#8212; Home</title>
            <link rel="icon" sizes="16x16" href="/icons/16.png">
            <link rel="apple-touch-icon" sizes="180x180" href="/icons/apple-180.png">
            <link rel="shortcut icon" href="/icons/shortcut.ico">
          </head>
        </html>
        """
        let parsed = WebHTMLMetadataParser.parse(html: html, baseURL: baseURL)
        XCTAssertEqual(parsed.title, "Ring & Docs — Home")
        XCTAssertEqual(parsed.iconCandidates.map(\.absoluteString), [
            "https://example.com/icons/apple-180.png",
            "https://example.com/icons/16.png",
            "https://example.com/icons/shortcut.ico",
            "https://example.com/favicon.ico"
        ])
    }

    // MARK: - 3. RingCenter with showCenterLabel true / false Across All Action Types

    func testRingCenterWithShowCenterLabelTrueAndFalseAcrossAllSlotTypes() {
        let actions: [SlotAction] = [
            .app(AppReference(bundleIdentifier: "com.apple.Safari", displayName: "Safari", path: "/Applications/Safari.app")),
            .webURL(WebURLReference(urlString: "https://github.com", displayName: "GitHub")),
            .file(FileReference(path: "/Users/dev/Projects", displayName: "Projects", isDirectory: true)),
            .systemAction(.lockScreen)
        ]
        let names = actions.map(\.displayName) + [""]
        let filled = [true, true, true, true, false]

        for mode in [RingInputMode.angularClick, .holdToLaunch] {
            for (index, action) in actions.enumerated() {
                let decision = RingPointerDecision(slot: index, action: .launch(index))

                let shown = RingCenter.text(for: decision, names: names, filled: filled, mode: mode, showCenterLabel: true)
                XCTAssertEqual(shown.title, action.displayName, "\(mode) 开启开关时应显示槽位名称：\(action)")
                XCTAssertNil(shown.action)

                let hidden = RingCenter.text(for: decision, names: names, filled: filled, mode: mode, showCenterLabel: false)
                XCTAssertNil(hidden.title, "\(mode) 关闭开关时应留空：\(action)")
                XCTAssertNil(hidden.action)
            }

            let emptyDecision = RingPointerDecision(slot: 4, action: .cancel)
            for showCenterLabel in [true, false] {
                let emptyText = RingCenter.text(for: emptyDecision,
                                                names: names,
                                                filled: filled,
                                                mode: mode,
                                                showCenterLabel: showCenterLabel)
                XCTAssertEqual(emptyText.title, "空位")
                if mode == .angularClick {
                    XCTAssertEqual(emptyText.action, "点击取消")
                } else {
                    XCTAssertNil(emptyText.action)
                }
            }
        }
    }

    // MARK: - 4. Mixed Slot Types Operations (Swap, Remove, Visible Count, Haptics)

    func testMixedSlotTypesSwapRemoveVisibleCountAndHapticState() throws {
        let appAction: SlotAction = .app(AppReference(bundleIdentifier: "com.apple.Safari", displayName: "Safari", path: "/Applications/Safari.app"))
        let webAction: SlotAction = .webURL(WebURLReference(urlString: "https://github.com", displayName: "GitHub"))
        let fileAction: SlotAction = .file(FileReference(path: "/tmp/notes.md", displayName: "notes.md", isDirectory: false))
        let lockAction: SlotAction = .systemAction(.lockScreen)
        let hiddenWebAction: SlotAction = .webURL(WebURLReference(urlString: "https://linear.app", displayName: "Linear"))

        var slots = LauncherConfiguration.empty().slots
        slots[0].action = appAction
        slots[1].action = webAction
        slots[2].action = fileAction
        slots[3].action = lockAction
        slots[6].action = hiddenWebAction

        let config = LauncherConfiguration(slots: slots,
                                           visibleSlotCount: 4,
                                           entranceDurationMilliseconds: 150,
                                           hapticFeedbackEnabled: true,
                                           showCenterLabelOnHover: false)

        // Swap webURL (1) <-> lockScreen (3)
        let swapped = RingPreviewSlotSwap.swap(in: config, source: 1, destination: 3)
        XCTAssertEqual(swapped.slots[1].action, lockAction)
        XCTAssertEqual(swapped.slots[3].action, webAction)
        XCTAssertEqual(swapped.slots[6].action, hiddenWebAction)
        XCTAssertFalse(swapped.showCenterLabelOnHover)

        // Move file (2) -> empty slot? First clear slot 0 via SlotActionWriter
        let cleared = SlotActionWriter.apply(action: nil, toSlotID: swapped.slots[0].id, in: swapped)
        XCTAssertFalse(cleared.slots[0].isFilled)
        let moved = SlotReordering.moveSlot(in: cleared, from: 2, to: 0)
        XCTAssertEqual(moved.slots[0].action, fileAction)
        XCTAssertFalse(moved.slots[2].isFilled)
        XCTAssertEqual(moved.slots[6].action, hiddenWebAction)
        XCTAssertFalse(moved.showCenterLabelOnHover)

        // Lower visible count 4 -> 3, then raise to 7 -> hidden slot 6 is preserved
        var lowered = moved
        lowered.visibleSlotCount = 3
        let reloadedLowered = try LauncherConfiguration.decoded(from: try lowered.encoded())
        XCTAssertEqual(reloadedLowered.visibleSlots.count, 3)
        XCTAssertEqual(reloadedLowered.slots[3].action, webAction)
        XCTAssertEqual(reloadedLowered.slots[6].action, hiddenWebAction)

        // Haptic feedback triggers across mixed configured slots (file=0, lock=1, empty=2, web=3)
        var haptic = RingHapticFeedbackState()
        let visible4 = moved.visibleSlots
        XCTAssertTrue(haptic.handlePointerUpdate(decision: RingPointerDecision(slot: 0, action: .launch(0)),
                                                 slots: visible4,
                                                 isRingVisible: true,
                                                 isEnabled: true))
        XCTAssertTrue(haptic.handlePointerUpdate(decision: RingPointerDecision(slot: 1, action: .launch(1)),
                                                 slots: visible4,
                                                 isRingVisible: true,
                                                 isEnabled: true))
        XCTAssertFalse(haptic.handlePointerUpdate(decision: RingPointerDecision(slot: 2, action: .cancel),
                                                  slots: visible4,
                                                  isRingVisible: true,
                                                  isEnabled: true))
        XCTAssertTrue(haptic.handlePointerUpdate(decision: RingPointerDecision(slot: 3, action: .launch(3)),
                                                 slots: visible4,
                                                 isRingVisible: true,
                                                 isEnabled: true))
    }

    // MARK: - 5. Launcher Dispatch & Lock Screen Strategy Fallback (Mocked, Never Locks Real Host)

    private final class MockExecutor: AppLaunching, WebURLLaunching, FileLaunching, ScreenLocking {
        var openedApps: [AppReference] = []
        var openedWebURLs: [WebURLReference] = []
        var openedFiles: [FileReference] = []
        var sacCalls = 0
        var pmsetCalls = 0

        var sacResult = true
        var pmsetResult: String? = nil
        var nextError: String? = nil

        func openApp(_ reference: AppReference, completion: @escaping (String?) -> Void) {
            openedApps.append(reference)
            completion(nextError)
        }

        func openWebURL(_ reference: WebURLReference, completion: @escaping (String?) -> Void) {
            openedWebURLs.append(reference)
            completion(nextError)
        }

        func openFile(_ reference: FileReference, completion: @escaping (String?) -> Void) {
            openedFiles.append(reference)
            completion(nextError)
        }

        func lockWithPrivateFramework() -> Bool {
            sacCalls += 1
            return sacResult
        }

        func lockWithDisplaySleepFallback() -> String? {
            pmsetCalls += 1
            return pmsetResult
        }
    }

    func testDispatcherRoutesAllActionTypes() {
        let mock = MockExecutor()
        let dispatcher = SlotActionDispatcher(appLauncher: mock,
                                              webURLLauncher: mock,
                                              fileLauncher: mock,
                                              screenLocker: mock)

        let appRef = AppReference(bundleIdentifier: "com.apple.Safari", displayName: "Safari", path: "/Applications/Safari.app")
        let webRef = WebURLReference(urlString: "https://github.com", displayName: "GitHub")
        let fileRef = FileReference(path: "/Users/dev/Desktop", displayName: "Desktop", isDirectory: true)

        var errors: [String?] = []
        dispatcher.open(.app(appRef)) { errors.append($0) }
        dispatcher.open(.webURL(webRef)) { errors.append($0) }
        dispatcher.open(.file(fileRef)) { errors.append($0) }
        dispatcher.open(.systemAction(.lockScreen)) { errors.append($0) }

        XCTAssertEqual(mock.openedApps, [appRef])
        XCTAssertEqual(mock.openedWebURLs, [webRef])
        XCTAssertEqual(mock.openedFiles, [fileRef])
        XCTAssertEqual(mock.sacCalls, 1)
        XCTAssertEqual(mock.pmsetCalls, 0, "主锁屏策略成功时不应调用 pmset 回退")
        XCTAssertEqual(errors, [nil, nil, nil, nil])
    }

    func testLockScreenFallsBackToDisplaySleepWhenPrivateFrameworkUnavailable() {
        let mock = MockExecutor()
        mock.sacResult = false
        mock.pmsetResult = nil
        let dispatcher = SlotActionDispatcher(appLauncher: mock,
                                              webURLLauncher: mock,
                                              fileLauncher: mock,
                                              screenLocker: mock)

        var capturedError: String? = "sentinel"
        dispatcher.open(.systemAction(.lockScreen)) { capturedError = $0 }

        XCTAssertEqual(mock.sacCalls, 1)
        XCTAssertEqual(mock.pmsetCalls, 1)
        XCTAssertNil(capturedError)
    }

    func testLockScreenReportsClearErrorWhenBothPrimaryAndFallbackFail() {
        let mock = MockExecutor()
        mock.sacResult = false
        mock.pmsetResult = "pmset 退出码 1"
        let dispatcher = SlotActionDispatcher(appLauncher: mock,
                                              webURLLauncher: mock,
                                              fileLauncher: mock,
                                              screenLocker: mock)

        var capturedError: String?
        dispatcher.open(.systemAction(.lockScreen)) { capturedError = $0 }

        XCTAssertEqual(mock.sacCalls, 1)
        XCTAssertEqual(mock.pmsetCalls, 1)
        XCTAssertEqual(capturedError, "锁定屏幕失败：pmset 退出码 1")
    }

    // MARK: - 6. WebURLFormState Icon Ownership & Async Fetch Race Protection

    func testEditingWebURLAndChangingToAnotherDomainClearsOldCachedIconOnSave() {
        let initial = WebURLReference(urlString: "https://github.com",
                                      displayName: "GitHub",
                                      cachedIconFileName: "github-icon.png")
        var form = WebURLFormState(initialReference: initial)
        XCTAssertEqual(form.cachedIconFileName, "github-icon.png")
        XCTAssertEqual(form.cachedIconOwnerURL, "https://github.com")

        // Change URL from A to B and save immediately without waiting for B's fetch
        form.updateURLInput("linear.app")
        XCTAssertNil(form.cachedIconFileName, "更换网址后必须立即清空旧站点图标缓存文件名")
        XCTAssertNil(form.cachedIconOwnerURL)

        let saved = form.buildReference(preferredBrowser: nil)
        XCTAssertEqual(saved?.urlString, "https://linear.app")
        XCTAssertNil(saved?.cachedIconFileName, "保存新站点时绝不能持久化旧站点图标")
    }

    func testEditingWebURLAndRefetchingAfterSwitchingBackOrToNewDomainBindsMatchingIcon() {
        let initial = WebURLReference(urlString: "https://github.com",
                                      displayName: "GitHub",
                                      cachedIconFileName: "github-icon.png")
        var form = WebURLFormState(initialReference: initial)

        // 1. Switch A -> B -> A, then refetch A and verify icon binds cleanly
        form.updateURLInput("linear.app")
        XCTAssertNil(form.cachedIconFileName)
        form.updateURLInput("github.com")
        let fetchA = form.beginMetadataFetch(force: false)
        XCTAssertNotNil(fetchA)
        let appliedA = form.applyFetchedMetadata(generation: fetchA!.generation,
                                                 requestedURL: fetchA!.normalizedURL,
                                                 title: "GitHub · Build software",
                                                 cachedIconFileName: "github-refetched.png")
        XCTAssertTrue(appliedA)
        XCTAssertEqual(form.cachedIconFileName, "github-refetched.png")
        XCTAssertEqual(form.cachedIconOwnerURL, "https://github.com")
        // Manually edited/initial displayName must not be overwritten
        XCTAssertEqual(form.displayName, "GitHub")
        XCTAssertEqual(form.buildReference(preferredBrowser: nil)?.cachedIconFileName, "github-refetched.png")

        // 2. Switch to B and complete fetch for B
        form.updateURLInput("linear.app")
        let fetchB = form.beginMetadataFetch(force: false)
        XCTAssertNotNil(fetchB)
        let appliedB = form.applyFetchedMetadata(generation: fetchB!.generation,
                                                 requestedURL: fetchB!.normalizedURL,
                                                 title: "Linear",
                                                 cachedIconFileName: "linear-icon.png")
        XCTAssertTrue(appliedB)
        XCTAssertEqual(form.cachedIconFileName, "linear-icon.png")
        XCTAssertEqual(form.cachedIconOwnerURL, "https://linear.app")
        XCTAssertEqual(form.buildReference(preferredBrowser: nil)?.cachedIconFileName, "linear-icon.png")
    }

    func testOutOfOrderOrStaleMetadataFetchCompletionsAreIgnoredWithoutClearingNewerFetch() {
        var form = WebURLFormState()

        // Start fetch #1 for site A
        form.updateURLInput("github.com")
        let fetch1 = form.beginMetadataFetch(force: false)!
        XCTAssertTrue(form.isFetchingMetadata)

        // User edits URL to site B while fetch #1 is still in flight -> should request cancellation
        let shouldCancel1 = form.updateURLInput("notion.so")
        XCTAssertTrue(shouldCancel1)
        XCTAssertFalse(form.isFetchingMetadata)

        // Start fetch #2 for site B
        let fetch2 = form.beginMetadataFetch(force: false)!
        XCTAssertTrue(form.isFetchingMetadata)
        XCTAssertGreaterThan(fetch2.generation, fetch1.generation)

        // Stale fetch #1 arrives late (out-of-order) -> must be ignored & must NOT turn off fetch #2 loading state
        let staleApplied = form.applyFetchedMetadata(generation: fetch1.generation,
                                                     requestedURL: fetch1.normalizedURL,
                                                     title: "GitHub",
                                                     cachedIconFileName: "github-stale.png")
        XCTAssertFalse(staleApplied)
        XCTAssertTrue(form.isFetchingMetadata, "过期回调不得误关新任务的加载指示")
        XCTAssertNil(form.cachedIconFileName)
        XCTAssertEqual(form.displayName, "notion.so")

        // Stale failure for fetch #1 must also not clear fetch #2 loading state
        form.finishFailedFetch(generation: fetch1.generation, requestedURL: fetch1.normalizedURL)
        XCTAssertTrue(form.isFetchingMetadata)

        // Even a forged/reused generation with wrong URL must be rejected
        let wrongURLApplied = form.applyFetchedMetadata(generation: fetch2.generation,
                                                        requestedURL: "https://github.com",
                                                        title: "GitHub",
                                                        cachedIconFileName: "github-wrong.png")
        XCTAssertFalse(wrongURLApplied)
        XCTAssertTrue(form.isFetchingMetadata)

        // Valid fetch #2 completes cleanly
        let validApplied = form.applyFetchedMetadata(generation: fetch2.generation,
                                                     requestedURL: fetch2.normalizedURL,
                                                     title: "Notion – Your connected workspace",
                                                     cachedIconFileName: "notion-icon.png")
        XCTAssertTrue(validApplied)
        XCTAssertFalse(form.isFetchingMetadata)
        XCTAssertEqual(form.cachedIconFileName, "notion-icon.png")
        XCTAssertEqual(form.cachedIconOwnerURL, "https://notion.so")
        XCTAssertEqual(form.displayName, "Notion – Your connected workspace")
        XCTAssertEqual(form.buildReference(preferredBrowser: nil)?.cachedIconFileName, "notion-icon.png")
    }
}
