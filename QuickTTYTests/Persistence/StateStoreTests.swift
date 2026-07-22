import AppKit
import Foundation
import Testing

@testable import QuickTTY

@Suite(.serialized)
@MainActor
struct StateStoreTests {
    @Test
    func productionStateURLUsesOnlyTheQuickTTYApplicationSupportDirectory() {
        let applicationSupportURL = URL(
            filePath: "/fixture/Application Support",
            directoryHint: .isDirectory
        )

        #expect(
            StateStore.productionStateURL(applicationSupportURL: applicationSupportURL).path
                == "/fixture/Application Support/QuickTTY/state.json"
        )
    }

    @Test
    func versionOneFixtureRoundTripsStableFlattenedSchema() throws {
        let fixture = Data(Self.versionOneFixture.utf8)

        let decoded = try StateMigration.decode(fixture)
        let workspace = try #require(decoded.workspaceStore.workspaces.first)
        let tab = try #require(workspace.tabs.first)

        #expect(decoded.version == ApplicationState.currentVersion)
        #expect(decoded.workspaceStore.activeWorkspaceID == Self.workspaceID(1))
        #expect(workspace.activeTabID == Self.tabID(1))
        #expect(tab.activePaneID == Self.paneID(2))
        #expect(tab.root.leaves == [Self.paneID(1), Self.paneID(2)])
        #expect(tab.paneDescriptor(for: Self.paneID(1))?.cwd == "/tmp/existing")
        #expect(
            tab.paneDescriptor(for: Self.paneID(2))?.startupCommand
                == .custom("printf 'pending command'")
        )
        #expect(tab.isBroadcasting == false)
        #expect(
            decoded.normalWindowFrame
                == NormalWindowFrame(x: 12, y: 34, width: 900, height: 600)
        )

        let encoded = try makeEncoder().encode(decoded)
        let object = try jsonObject(encoded)

        #expect(
            Set(object.keys) == ["activeWorkspaceID", "normalWindowFrame", "version", "workspaces"])
        #expect(object["version"] as? Int == 1)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"_0\"") == false)
        #expect(try StateMigration.decode(encoded) == decoded)
    }

    @Test
    func savedTabOrderRoundTrips() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let first = TerminalTab(
            id: Self.tabID(201),
            title: "First",
            pane: TerminalPaneDescriptor(id: Self.paneID(201), cwd: fixture.homeURL.path)
        )
        let second = TerminalTab(
            id: Self.tabID(202),
            title: "Second",
            pane: TerminalPaneDescriptor(id: Self.paneID(202), cwd: fixture.homeURL.path)
        )
        let third = TerminalTab(
            id: Self.tabID(203),
            title: "Third",
            pane: TerminalPaneDescriptor(id: Self.paneID(203), cwd: fixture.homeURL.path)
        )
        let workspace = Workspace(
            id: Self.workspaceID(201),
            name: "Ordered",
            tabs: [first, second, third],
            activeTabID: second.id
        )
        var workspaceStore = try WorkspaceStore(
            workspaces: [workspace],
            activeWorkspaceID: workspace.id
        )
        let expectedOrder = [third.id, first.id, second.id]
        try workspaceStore.reorderTabs(expectedOrder, in: workspace.id)
        let store = try fixture.makeStore()

        try store.saveNow(ApplicationState(workspaceStore: workspaceStore))

        let restored = try store.load()
        #expect(
            restored.workspaceStore.workspace(id: workspace.id)?.tabs.map(\.id) == expectedOrder)
        #expect(restored.workspaceStore.workspace(id: workspace.id)?.activeTabID == second.id)
    }

    @Test
    func decodingIgnoresUnknownFieldsThroughoutVersionOneSnapshot() throws {
        var object = try jsonObject(Data(Self.versionOneFixture.utf8))
        object["futureTopLevel"] = true
        var workspaces = try #require(object["workspaces"] as? [[String: Any]])
        workspaces[0]["futureWorkspace"] = 1
        var tabs = try #require(workspaces[0]["tabs"] as? [[String: Any]])
        tabs[0]["futureTab"] = "ignored"
        tabs[0]["isBroadcasting"] = true
        var root = try #require(tabs[0]["root"] as? [String: Any])
        root["futureSplit"] = ["anything": true]
        tabs[0]["root"] = root
        var descriptors = try #require(tabs[0]["paneDescriptors"] as? [[String: Any]])
        descriptors[0]["futurePane"] = NSNull()
        var command = try #require(descriptors[1]["startupCommand"] as? [String: Any])
        command["futureCommand"] = 42
        descriptors[1]["startupCommand"] = command
        tabs[0]["paneDescriptors"] = descriptors
        workspaces[0]["tabs"] = tabs
        object["workspaces"] = workspaces
        var frame = try #require(object["normalWindowFrame"] as? [String: Any])
        frame["futureFrame"] = "ignored"
        object["normalWindowFrame"] = frame

        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try StateMigration.decode(data)

        #expect(decoded.workspaceStore.tab(id: Self.tabID(1))?.isBroadcasting == false)
        #expect(
            decoded.workspaceStore.tab(id: Self.tabID(1))?
                .paneDescriptor(for: Self.paneID(2))?.startupCommand
                == .custom("printf 'pending command'")
        )
        #expect(decoded.normalWindowFrame?.width == 900)
    }

    @Test
    func migrationRejectsMissingNullNonIntegerAndUnsupportedVersionsExplicitly() {
        expectMigrationError(.missingVersion, json: "{}")
        expectMigrationError(.nullVersion, json: #"{"version":null}"#)
        expectMigrationError(.nonIntegerVersion, json: #"{"version":1.5}"#)
        expectMigrationError(.nonIntegerVersion, json: #"{"version":"1"}"#)
        expectMigrationError(.unsupportedOlderVersion(0), json: #"{"version":0}"#)
        expectMigrationError(.unsupportedNewerVersion(2), json: #"{"version":2}"#)
    }

    @Test
    func normalWindowFrameRejectsInvalidGeometry() {
        #expect(NormalWindowFrame(x: 0, y: 0, width: 0, height: 100) == nil)
        #expect(NormalWindowFrame(x: 0, y: 0, width: 100, height: -1) == nil)
        #expect(NormalWindowFrame(x: .infinity, y: 0, width: 100, height: 100) == nil)
        #expect(NormalWindowFrame(x: 0, y: .nan, width: 100, height: 100) == nil)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                NormalWindowFrame.self,
                from: Data(#"{"x":0,"y":0,"width":0,"height":100}"#.utf8)
            )
        }
    }

    @Test
    func absentStateReturnsFreshDefaultWithoutCreatingFiles() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let store = try fixture.makeStore()

        let state = try store.load()

        #expect(state.version == ApplicationState.currentVersion)
        #expect(state.workspaceStore.workspaces.count == 1)
        #expect(state.workspaceStore.workspaces.first?.name == "Default")
        #expect(state.workspaceStore.workspaces.first?.tabs.isEmpty == true)
        #expect(state.normalWindowFrame == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.stateURL.path) == false)
    }

    @Test
    func saveUsesOneCrashDurableAtomicSequencePerWrite() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let recorder = StateStoreFileOperationRecorder()
        let store = try fixture.makeStore(fileOperations: recorder.operations)
        let first = try makeState(workspaceName: "First", frameX: 10)
        let latest = try makeState(workspaceName: "Latest", frameX: 20)
        let staleURL = fixture.directoryURL.appending(path: "state.json.tmp-abandoned")
        let unrelatedURL = fixture.directoryURL.appending(path: "state.json.tmp")
        try Data("stale".utf8).write(to: staleURL)
        try Data("unrelated".utf8).write(to: unrelatedURL)

        try store.saveNow(first)

        #expect(try StateMigration.decode(Data(contentsOf: fixture.stateURL)) == first)
        #expect(recorder.events == [.temporaryWrite, .fileSync, .move, .directorySync])
        #expect(recorder.temporaryWriteCount == 1)
        #expect(recorder.moveCount == 1)
        #expect(recorder.replaceCount == 0)
        #expect(recorder.fileSyncCount == 1)
        #expect(recorder.directorySyncCount == 1)
        #expect(FileManager.default.fileExists(atPath: staleURL.path) == false)
        #expect(try Data(contentsOf: unrelatedURL) == Data("unrelated".utf8))

        try store.saveNow(latest)

        let savedData = try Data(contentsOf: fixture.stateURL)
        #expect(try StateMigration.decode(savedData) == latest)
        #expect(String(decoding: savedData, as: UTF8.self).hasPrefix("{\n"))
        #expect(
            recorder.events == [
                .temporaryWrite, .fileSync, .move, .directorySync,
                .temporaryWrite, .fileSync, .replace, .directorySync,
            ])
        #expect(recorder.temporaryWriteCount == 2)
        #expect(recorder.moveCount == 1)
        #expect(recorder.replaceCount == 1)
        #expect(recorder.fileSyncCount == 2)
        #expect(recorder.directorySyncCount == 2)
        #expect(try ownTemporarySiblings(in: fixture).isEmpty)
    }

    @Test
    func loadRemovesOnlyOwnStaleTemporarySiblings() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let ownStaleURL = fixture.directoryURL.appending(path: "state.json.tmp-orphaned")
        let unrelatedURLs = [
            fixture.directoryURL.appending(path: "state.json.tmp"),
            fixture.directoryURL.appending(path: "state.json.other.tmp-file"),
            fixture.directoryURL.appending(path: "notes.tmp-orphaned"),
        ]
        try Data("own".utf8).write(to: ownStaleURL)
        for url in unrelatedURLs {
            try Data(url.lastPathComponent.utf8).write(to: url)
        }

        let state = try fixture.makeStore().load()

        #expect(state.workspaceStore.workspaces.first?.name == "Default")
        #expect(FileManager.default.fileExists(atPath: ownStaleURL.path) == false)
        for url in unrelatedURLs {
            #expect(try Data(contentsOf: url) == Data(url.lastPathComponent.utf8))
        }
    }

    @Test
    func staleTemporaryCleanupFailureIsTypedAndPreservesDestination() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let state = try makeState(workspaceName: "Preserved", frameX: 10)
        let destinationBytes = try makeEncoder().encode(state)
        try destinationBytes.write(to: fixture.stateURL)
        let staleURL = fixture.directoryURL.appending(path: "state.json.tmp-blocked")
        try Data("stale".utf8).write(to: staleURL)
        let recorder = StateStoreFileOperationRecorder()
        recorder.failNextRemoval = true
        let store = try fixture.makeStore(fileOperations: recorder.operations)

        do {
            _ = try store.load()
            Issue.record("Expected stale temporary cleanup failure")
        } catch let error as StateStoreError {
            guard case .staleTemporaryCleanupFailed(let path, _) = error else {
                Issue.record("Expected staleTemporaryCleanupFailed, got \(error)")
                return
            }
            #expect(
                URL(fileURLWithPath: path).resolvingSymlinksInPath()
                    == staleURL.resolvingSymlinksInPath()
            )
        }

        #expect(try Data(contentsOf: fixture.stateURL) == destinationBytes)
        #expect(try Data(contentsOf: staleURL) == Data("stale".utf8))
        #expect(recorder.events.isEmpty)
    }

    @Test
    func replacementFailurePreservesExactOldBytesAndRemovesTemporaryFile() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let recorder = StateStoreFileOperationRecorder()
        let store = try fixture.makeStore(fileOperations: recorder.operations)
        try store.saveNow(try makeState(workspaceName: "Old", frameX: 10))
        let oldBytes = try Data(contentsOf: fixture.stateURL)
        recorder.failNextReplacement = true

        do {
            try store.saveNow(try makeState(workspaceName: "New", frameX: 20))
            Issue.record("Expected replacement failure")
        } catch let error as StateStoreError {
            guard case .atomicReplaceFailed = error else {
                Issue.record("Expected atomicReplaceFailed, got \(error)")
                return
            }
        }

        #expect(try Data(contentsOf: fixture.stateURL) == oldBytes)
        #expect(try ownTemporarySiblings(in: fixture).isEmpty)
        #expect(recorder.temporaryWriteCount == 2)
        #expect(recorder.fileSyncCount == 2)
        #expect(recorder.moveCount == 1)
        #expect(recorder.replaceAttemptCount == 1)
        #expect(recorder.replaceCount == 0)
        #expect(recorder.directorySyncCount == 1)
    }

    @Test
    func corruptStateMovesExactBytesToDeterministicBackupAndReturnsDefault() throws {
        let fixture = try StoreFixture(backupSuffix: "20260714T120000Z")
        defer { fixture.remove() }
        let corruptBytes = Data([0xFF, 0x00, 0x7B, 0x7D])
        try corruptBytes.write(to: fixture.stateURL)
        let store = try fixture.makeStore()

        let state = try store.load()

        let backupURL = fixture.directoryURL.appending(path: "state.json.backup-20260714T120000Z")
        #expect(FileManager.default.fileExists(atPath: fixture.stateURL.path) == false)
        #expect(try Data(contentsOf: backupURL) == corruptBytes)
        #expect(state.workspaceStore.workspaces.first?.name == "Default")
    }

    @Test
    func unsupportedStateUsesTheSameSafeBackupPolicy() throws {
        let fixture = try StoreFixture(backupSuffix: "unsupported")
        defer { fixture.remove() }
        let bytes = Data(#"{"version":99,"workspaces":[]}"#.utf8)
        try bytes.write(to: fixture.stateURL)
        let store = try fixture.makeStore()

        let state = try store.load()

        let backupURL = fixture.directoryURL.appending(path: "state.json.backup-unsupported")
        #expect(FileManager.default.fileExists(atPath: fixture.stateURL.path) == false)
        #expect(try Data(contentsOf: backupURL) == bytes)
        #expect(state.workspaceStore.workspaces.first?.name == "Default")
    }

    @Test
    func missingNullAndInvalidVersionOneSnapshotsAreBackedUp() throws {
        let snapshots = [
            ("missing", Data("{}".utf8)),
            ("null", Data(#"{"version":null}"#.utf8)),
            ("invalid-v1", Data(#"{"version":1}"#.utf8)),
        ]

        for (suffix, bytes) in snapshots {
            let fixture = try StoreFixture(backupSuffix: suffix)
            defer { fixture.remove() }
            try bytes.write(to: fixture.stateURL)
            let state = try fixture.makeStore().load()
            let backupURL = fixture.directoryURL.appending(
                path: "state.json.backup-\(suffix)"
            )

            #expect(FileManager.default.fileExists(atPath: fixture.stateURL.path) == false)
            #expect(try Data(contentsOf: backupURL) == bytes)
            #expect(state.workspaceStore.workspaces.first?.name == "Default")
        }
    }

    @Test
    func failedBackupMoveThrowsAndPreservesOriginalData() throws {
        let fixture = try StoreFixture(backupSuffix: "collision")
        defer { fixture.remove() }
        let corruptBytes = Data("corrupt state".utf8)
        try corruptBytes.write(to: fixture.stateURL)
        let backupURL = fixture.directoryURL.appending(path: "state.json.backup-collision")
        try Data("existing backup".utf8).write(to: backupURL)
        let store = try fixture.makeStore()

        do {
            _ = try store.load()
            Issue.record("Expected backup failure")
        } catch let error as StateStoreError {
            guard case .backupFailed = error else {
                Issue.record("Expected backupFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected StateStoreError, got \(error)")
        }

        #expect(try Data(contentsOf: fixture.stateURL) == corruptBytes)
        #expect(try Data(contentsOf: backupURL) == Data("existing backup".utf8))
    }

    @Test
    func loadNormalizesInvalidCWDsWhilePreservingAbsoluteDirectoryAndModel() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let existingDirectory = fixture.directoryURL.appending(
            path: "existing",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: existingDirectory,
            withIntermediateDirectories: false
        )
        let fileURL = fixture.directoryURL.appending(path: "regular-file")
        try Data().write(to: fileURL)
        let missingURL = fixture.directoryURL.appending(path: "missing")
        let invalidPaths = [fileURL.path, missingURL.path, ".", "relative/path", ""]
        let state = try makeCWDState(
            existingDirectory: existingDirectory.path,
            invalidPaths: invalidPaths
        )
        let store = try fixture.makeStore()
        try store.saveNow(state)

        let loaded = try store.load()
        let tab = try #require(loaded.workspaceStore.tab(id: Self.tabID(1)))

        #expect(tab.root == state.workspaceStore.tab(id: Self.tabID(1))?.root)
        #expect(tab.activePaneID == Self.paneID(2))
        #expect(tab.paneDescriptor(for: Self.paneID(1))?.cwd == existingDirectory.path)
        for paneValue in 2...(invalidPaths.count + 1) {
            #expect(tab.paneDescriptor(for: Self.paneID(paneValue))?.cwd == fixture.homeURL.path)
        }
        #expect(
            tab.paneDescriptor(for: Self.paneID(2))?.startupCommand
                == .custom("printf 'still pending'")
        )
        #expect(tab.isBroadcasting == false)
    }

    @Test
    func initializerRejectsInvalidInjectedHomeDirectory() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let regularFileURL = fixture.directoryURL.appending(path: "not-home")
        try Data().write(to: regularFileURL)
        let invalidHomes = [
            URL(string: "file:")!,
            URL(string: "relative/home")!,
            regularFileURL,
            fixture.directoryURL.appending(path: "missing-home"),
        ]

        for invalidHome in invalidHomes {
            do {
                _ = try StateStore(
                    url: fixture.stateURL,
                    homeDirectoryURL: invalidHome
                )
                Issue.record("Expected invalid home rejection for \(invalidHome)")
            } catch let error as StateStoreError {
                guard case .invalidHomeDirectory(let path) = error else {
                    Issue.record("Expected invalidHomeDirectory, got \(error)")
                    continue
                }
                #expect(path == invalidHome.path)
            }
        }
    }

    @Test
    func debounceCoalescesRapidRatioFocusAndCWDWorkspaceSnapshots() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let scheduler = ManualStateStoreScheduler()
        let recorder = StateStoreFileOperationRecorder()
        let store = try fixture.makeStore(
            schedule: scheduler.schedule,
            fileOperations: recorder.operations
        )
        let firstPaneID = Self.paneID(91)
        let secondPaneID = Self.paneID(92)
        let ratioState = try makeRuntimeMutationState(
            ratio: 0.7,
            activePaneID: firstPaneID,
            workingDirectory: "/tmp/ratio"
        )
        let focusState = try makeRuntimeMutationState(
            ratio: 0.7,
            activePaneID: secondPaneID,
            workingDirectory: "/tmp/ratio"
        )
        let latestCWDState = try makeRuntimeMutationState(
            ratio: 0.7,
            activePaneID: secondPaneID,
            workingDirectory: "/tmp/latest"
        )

        store.scheduleSave(ratioState)
        store.scheduleSave(focusState)
        store.scheduleSave(latestCWDState)
        scheduler.runAllIncludingCanceled()

        #expect(try StateMigration.decode(Data(contentsOf: fixture.stateURL)) == latestCWDState)
        #expect(recorder.temporaryWriteCount == 1)
        #expect(recorder.events == [.temporaryWrite, .fileSync, .move, .directorySync])
    }

    @Test
    func manualDebounceCoalescesToOneLatestPhysicalWrite() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let scheduler = ManualStateStoreScheduler()
        let recorder = StateStoreFileOperationRecorder()
        let store = try fixture.makeStore(
            schedule: scheduler.schedule,
            fileOperations: recorder.operations
        )
        let first = try makeState(workspaceName: "First", frameX: 1)
        let second = try makeState(workspaceName: "Second", frameX: 2)
        let latest = try makeState(workspaceName: "Latest", frameX: 3)
        #expect(try makeEncoder().encode(first) != makeEncoder().encode(second))
        #expect(try makeEncoder().encode(second) != makeEncoder().encode(latest))

        store.scheduleSave(first)
        store.scheduleSave(second)
        store.scheduleSave(latest)

        #expect(scheduler.callbackCount == 3)
        #expect(scheduler.cancellationCount == 2)
        #expect(FileManager.default.fileExists(atPath: fixture.stateURL.path) == false)

        scheduler.runCanceledCallbacks()

        #expect(recorder.events.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.stateURL.path) == false)

        scheduler.runAllIncludingCanceled()

        #expect(try StateMigration.decode(Data(contentsOf: fixture.stateURL)) == latest)
        #expect(recorder.events == [.temporaryWrite, .fileSync, .move, .directorySync])
        #expect(recorder.temporaryWriteCount == 1)
        #expect(recorder.moveCount == 1)
        #expect(recorder.replaceCount == 0)
        #expect(recorder.fileSyncCount == 1)
        #expect(recorder.directorySyncCount == 1)
        let bytesAfterFirstRun = try Data(contentsOf: fixture.stateURL)

        scheduler.runAllIncludingCanceled()

        #expect(try Data(contentsOf: fixture.stateURL) == bytesAfterFirstRun)
        #expect(recorder.temporaryWriteCount == 1)
        #expect(recorder.events.count == 4)
    }

    @Test
    func flushWinsQueuedCallbackRaceWithOnePhysicalWrite() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let scheduler = ManualStateStoreScheduler()
        let recorder = StateStoreFileOperationRecorder()
        let store = try fixture.makeStore(
            schedule: scheduler.schedule,
            fileOperations: recorder.operations
        )
        let first = try makeState(workspaceName: "First", frameX: 1)
        let latest = try makeState(workspaceName: "Latest", frameX: 2)
        #expect(try makeEncoder().encode(first) != makeEncoder().encode(latest))

        store.scheduleSave(first)
        store.scheduleSave(latest)
        try store.flushPendingSave()

        let flushedBytes = try Data(contentsOf: fixture.stateURL)
        #expect(try StateMigration.decode(flushedBytes) == latest)
        #expect(scheduler.cancellationCount == 2)
        #expect(recorder.events == [.temporaryWrite, .fileSync, .move, .directorySync])

        scheduler.runAllIncludingCanceled()
        try store.flushPendingSave()

        #expect(try Data(contentsOf: fixture.stateURL) == flushedBytes)
        #expect(recorder.temporaryWriteCount == 1)
        #expect(recorder.moveCount == 1)
        #expect(recorder.replaceCount == 0)
        #expect(recorder.fileSyncCount == 1)
        #expect(recorder.directorySyncCount == 1)
    }

    @Test
    func deinitCancelsRetainedCallbackBeforeAnyPhysicalWrite() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let scheduler = ManualStateStoreScheduler()
        let recorder = StateStoreFileOperationRecorder()
        var store: StateStore? = try fixture.makeStore(
            schedule: scheduler.schedule,
            fileOperations: recorder.operations
        )
        let weakStore = WeakStateStoreReference(store)

        store?.scheduleSave(try makeState(workspaceName: "Pending", frameX: 1))
        store = nil

        #expect(weakStore.value == nil)
        #expect(scheduler.cancellationCount == 1)
        scheduler.runAllIncludingCanceled()
        #expect(recorder.events.isEmpty)
        #expect(recorder.temporaryWriteCount == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.stateURL.path) == false)
    }

    @Test
    func scheduledWriteFailureReportsTypedErrorDeterministically() throws {
        let fixture = try StoreFixture()
        defer { fixture.remove() }
        let blockingParent = fixture.directoryURL.appending(path: "not-a-directory")
        try Data("block directory creation".utf8).write(to: blockingParent)
        let scheduler = ManualStateStoreScheduler()
        var reportedErrors: [StateStoreError] = []
        let store = try StateStore(
            url: blockingParent.appending(path: "state.json"),
            homeDirectoryURL: fixture.homeURL,
            backupSuffix: { "unused" },
            schedule: scheduler.schedule,
            reportScheduledError: { reportedErrors.append($0) }
        )

        store.scheduleSave(try makeState(workspaceName: "Latest", frameX: 1))
        scheduler.runAllIncludingCanceled()

        #expect(reportedErrors.count == 1)
        guard case .createDirectoryFailed = reportedErrors.first else {
            Issue.record(
                "Expected createDirectoryFailed, got \(String(describing: reportedErrors.first))")
            return
        }
    }

    @Test
    func frameConversionRoundTripsValidGeometryAndRejectsInvalidRects() throws {
        let frame = try #require(NormalWindowFrame(x: 11, y: 22, width: 800, height: 500))

        let rect = WindowCoordinator.windowFrame(from: frame)

        #expect(rect == NSRect(x: 11, y: 22, width: 800, height: 500))
        #expect(WindowCoordinator.normalWindowFrame(from: rect) == frame)
        #expect(
            WindowCoordinator.normalWindowFrame(
                from: NSRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)
            ) == nil
        )
    }

    @Test
    func restoredTinyFrameExpandsToMinimumAndRemainsOnscreen() throws {
        let saved = try #require(NormalWindowFrame(x: 100, y: 120, width: 10, height: 10))
        let screen = NSRect(x: 0, y: 0, width: 1_200, height: 900)

        let restored = try #require(
            WindowCoordinator.restoredWindowFrame(
                from: saved,
                visibleScreenFrames: [screen]
            )
        )

        #expect(restored.size == NormalWindowController.minimumFrameSize)
        #expect(screen.contains(restored))
    }

    @Test
    func restoredFrameFullyInsideVisibleScreenIsUnchanged() throws {
        let saved = try #require(NormalWindowFrame(x: 100, y: 120, width: 800, height: 500))
        let screen = NSRect(x: 0, y: 0, width: 1_200, height: 900)

        let restored = WindowCoordinator.restoredWindowFrame(
            from: saved,
            visibleScreenFrames: [screen]
        )

        #expect(restored == WindowCoordinator.windowFrame(from: saved))
    }

    @Test
    func restoredFrameCapsMinimumToVerySmallVisibleScreen() throws {
        let saved = try #require(NormalWindowFrame(x: 10, y: 10, width: 10, height: 10))
        let screen = NSRect(x: 0, y: 0, width: 600, height: 400)

        let restored = WindowCoordinator.restoredWindowFrame(
            from: saved,
            visibleScreenFrames: [screen]
        )

        #expect(restored == screen)
    }

    @Test
    func restoredFramePartiallyOffscreenIsConstrainedInsideLargestIntersectionScreen() throws {
        let saved = try #require(NormalWindowFrame(x: -100, y: 650, width: 500, height: 300))
        let screens = [
            NSRect(x: -1_000, y: 0, width: 1_000, height: 800),
            NSRect(x: 0, y: 0, width: 1_000, height: 800),
        ]

        let restored = WindowCoordinator.restoredWindowFrame(
            from: saved,
            visibleScreenFrames: screens
        )

        #expect(restored == NSRect(x: 0, y: 328, width: 720, height: 472))
    }

    @Test
    func restoredFrameOnDisconnectedMonitorKeepsCenteredFallback() throws {
        let saved = try #require(NormalWindowFrame(x: 2_000, y: 100, width: 500, height: 400))
        let screen = NSRect(x: 0, y: 0, width: 1_000, height: 800)

        #expect(
            WindowCoordinator.restoredWindowFrame(
                from: saved,
                visibleScreenFrames: [screen]
            ) == nil
        )
        #expect(
            WindowCoordinator.restoredWindowFrame(
                from: saved,
                visibleScreenFrames: []
            ) == nil
        )
    }

    @Test
    func restoredOversizedFrameIsConstrainedToVisibleScreen() throws {
        let saved = try #require(NormalWindowFrame(x: -100, y: -100, width: 1_200, height: 900))
        let screen = NSRect(x: 0, y: 0, width: 1_000, height: 800)

        let restored = WindowCoordinator.restoredWindowFrame(
            from: saved,
            visibleScreenFrames: [screen]
        )

        #expect(restored == screen)
    }

    private static let versionOneFixture = #"""
        {
          "version": 1,
          "workspaces": [
            {
              "id": { "rawValue": "00000000-0000-0000-0000-000000002001" },
              "name": "Development",
              "tabs": [
                {
                  "id": { "rawValue": "00000000-0000-0000-0000-000000001001" },
                  "title": "Services",
                  "root": {
                    "kind": "split",
                    "id": "00000000-0000-0000-0000-000000000003",
                    "axis": "vertical",
                    "ratio": 0.37,
                    "first": {
                      "kind": "pane",
                      "paneID": { "rawValue": "00000000-0000-0000-0000-000000000001" }
                    },
                    "second": {
                      "kind": "pane",
                      "paneID": { "rawValue": "00000000-0000-0000-0000-000000000002" }
                    }
                  },
                  "paneDescriptors": [
                    {
                      "id": { "rawValue": "00000000-0000-0000-0000-000000000001" },
                      "cwd": "/tmp/existing",
                      "startupCommand": { "kind": "shell" }
                    },
                    {
                      "id": { "rawValue": "00000000-0000-0000-0000-000000000002" },
                      "cwd": "/tmp/missing",
                      "startupCommand": {
                        "kind": "custom",
                        "command": "printf 'pending command'"
                      }
                    }
                  ],
                  "activePaneID": {
                    "rawValue": "00000000-0000-0000-0000-000000000002"
                  },
                  "isBroadcasting": true
                }
              ],
              "activeTabID": {
                "rawValue": "00000000-0000-0000-0000-000000001001"
              }
            }
          ],
          "activeWorkspaceID": {
            "rawValue": "00000000-0000-0000-0000-000000002001"
          },
          "normalWindowFrame": {
            "x": 12,
            "y": 34,
            "width": 900,
            "height": 600
          }
        }
        """#

    private static func paneID(_ value: Int) -> PaneID {
        PaneID(rawValue: uuid(value))
    }

    private static func tabID(_ value: Int) -> TabID {
        TabID(rawValue: uuid(1_000 + value))
    }

    private static func workspaceID(_ value: Int) -> WorkspaceID {
        WorkspaceID(rawValue: uuid(2_000 + value))
    }

    private static func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    private func makeState(workspaceName: String, frameX: Double) throws -> ApplicationState {
        let workspaceID = Self.workspaceID(Int(frameX) + 10)
        let store = try WorkspaceStore(
            workspaces: [Workspace(id: workspaceID, name: workspaceName)],
            activeWorkspaceID: workspaceID
        )
        return ApplicationState(
            workspaceStore: store,
            normalWindowFrame: NormalWindowFrame(
                x: frameX,
                y: 20,
                width: 900,
                height: 600
            )
        )
    }

    private func makeRuntimeMutationState(
        ratio: Double,
        activePaneID: PaneID,
        workingDirectory: String
    ) throws -> ApplicationState {
        let firstPaneID = Self.paneID(91)
        let secondPaneID = Self.paneID(92)
        let tab = try TerminalTab(
            id: Self.tabID(91),
            title: "Runtime",
            root: .split(
                id: Self.uuid(91),
                axis: .horizontal,
                ratio: ratio,
                first: .pane(firstPaneID),
                second: .pane(secondPaneID)
            ),
            paneDescriptors: [
                TerminalPaneDescriptor(id: firstPaneID, cwd: "/tmp/first"),
                TerminalPaneDescriptor(id: secondPaneID, cwd: workingDirectory),
            ],
            activePaneID: activePaneID
        )
        let workspace = Workspace(
            id: Self.workspaceID(91),
            name: "Runtime",
            tabs: [tab],
            activeTabID: tab.id
        )
        return ApplicationState(
            workspaceStore: try WorkspaceStore(
                workspaces: [workspace],
                activeWorkspaceID: workspace.id
            )
        )
    }

    private func makeCWDState(
        existingDirectory: String,
        invalidPaths: [String]
    ) throws -> ApplicationState {
        let paneIDs = (1...(invalidPaths.count + 1)).map(Self.paneID)
        var root = SplitNode.pane(paneIDs[0])
        for (index, paneID) in paneIDs.dropFirst().enumerated() {
            root = .split(
                id: Self.uuid(10 + index),
                axis: index.isMultiple(of: 2) ? .horizontal : .vertical,
                ratio: 0.5,
                first: root,
                second: .pane(paneID)
            )
        }
        var paneDescriptors = [
            TerminalPaneDescriptor(id: paneIDs[0], cwd: existingDirectory)
        ]
        paneDescriptors.append(
            contentsOf: zip(paneIDs.dropFirst(), invalidPaths).enumerated().map {
                index, pair in
                TerminalPaneDescriptor(
                    id: pair.0,
                    cwd: pair.1,
                    startupCommand:
                        index == 0 ? .custom("printf 'still pending'") : .shell
                )
            })
        let tab = try TerminalTab(
            id: Self.tabID(1),
            title: "CWDs",
            root: root,
            paneDescriptors: paneDescriptors,
            activePaneID: paneIDs[1],
            isBroadcasting: true
        )
        let workspace = Workspace(
            id: Self.workspaceID(1),
            name: "Default",
            tabs: [tab],
            activeTabID: tab.id
        )
        return ApplicationState(
            workspaceStore: try WorkspaceStore(
                workspaces: [workspace],
                activeWorkspaceID: workspace.id
            )
        )
    }

    private func expectMigrationError(_ expected: StateMigrationError, json: String) {
        do {
            _ = try StateMigration.decode(Data(json.utf8))
            Issue.record("Expected migration error \(expected)")
        } catch let error as StateMigrationError {
            #expect(error == expected)
        } catch {
            Issue.record("Expected StateMigrationError, got \(error)")
        }
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func ownTemporarySiblings(in fixture: StoreFixture) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: fixture.directoryURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("state.json.tmp-") }
    }
}

@MainActor
private final class WeakStateStoreReference {
    weak var value: StateStore?

    init(_ value: StateStore?) {
        self.value = value
    }
}

@MainActor
private final class ManualStateStoreScheduler {
    private var callbacks: [@MainActor () -> Void] = []
    private var canceled: [Bool] = []
    private(set) var cancellationCount = 0

    var callbackCount: Int { callbacks.count }

    func schedule(_ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let index = callbacks.count
        callbacks.append(action)
        canceled.append(false)
        return { [weak self] in
            guard let self, !canceled[index] else { return }
            canceled[index] = true
            cancellationCount += 1
        }
    }

    func runCanceledCallbacks() {
        for (index, callback) in callbacks.enumerated() where canceled[index] {
            callback()
        }
    }

    func runAllIncludingCanceled() {
        for callback in callbacks {
            callback()
        }
    }
}

@MainActor
private final class StateStoreFileOperationRecorder {
    enum Event: Equatable {
        case temporaryWrite
        case fileSync
        case move
        case replace
        case directorySync
    }

    private enum InjectedError: Error {
        case replacement
        case removal
    }

    private let realOperations = StateStore.FileOperations.production()
    private(set) var events: [Event] = []
    private(set) var temporaryWriteCount = 0
    private(set) var fileSyncCount = 0
    private(set) var moveCount = 0
    private(set) var replaceAttemptCount = 0
    private(set) var replaceCount = 0
    private(set) var directorySyncCount = 0
    var failNextReplacement = false
    var failNextRemoval = false

    var operations: StateStore.FileOperations {
        StateStore.FileOperations(
            contentsOfDirectory: { [self] url in
                try realOperations.contentsOfDirectory(url)
            },
            removeItem: { [self] url in
                if failNextRemoval {
                    failNextRemoval = false
                    throw InjectedError.removal
                }
                try realOperations.removeItem(url)
            },
            writeTemporary: { [self] data, url in
                try realOperations.writeTemporary(data, url)
                temporaryWriteCount += 1
                events.append(.temporaryWrite)
            },
            synchronizeFile: { [self] url in
                try realOperations.synchronizeFile(url)
                fileSyncCount += 1
                events.append(.fileSync)
            },
            moveTemporary: { [self] sourceURL, destinationURL in
                try realOperations.moveTemporary(sourceURL, destinationURL)
                moveCount += 1
                events.append(.move)
            },
            replaceDestination: { [self] destinationURL, temporaryURL in
                replaceAttemptCount += 1
                if failNextReplacement {
                    failNextReplacement = false
                    throw InjectedError.replacement
                }
                try realOperations.replaceDestination(destinationURL, temporaryURL)
                replaceCount += 1
                events.append(.replace)
            },
            synchronizeDirectory: { [self] url in
                try realOperations.synchronizeDirectory(url)
                directorySyncCount += 1
                events.append(.directorySync)
            }
        )
    }
}

@MainActor
private struct StoreFixture {
    let directoryURL: URL
    let homeURL: URL
    let stateURL: URL
    let backupSuffix: String

    init(backupSuffix: String = "test-backup") throws {
        directoryURL = FileManager.default.temporaryDirectory.appending(
            path: "QuickTTY-StateStoreTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        homeURL = directoryURL.appending(path: "home", directoryHint: .isDirectory)
        stateURL = directoryURL.appending(path: "state.json")
        self.backupSuffix = backupSuffix
        try FileManager.default.createDirectory(
            at: homeURL,
            withIntermediateDirectories: true
        )
    }

    func makeStore(
        schedule: StateStore.Schedule? = nil,
        fileOperations: StateStore.FileOperations? = nil
    ) throws -> StateStore {
        try StateStore(
            url: stateURL,
            homeDirectoryURL: homeURL,
            backupSuffix: { backupSuffix },
            schedule: schedule,
            fileOperations: fileOperations
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
