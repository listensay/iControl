import Foundation
import TestSupport
import IControlCore

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--check-native-askpass" {
    let helper = URL(fileURLWithPath: CommandLine.arguments[2])
    let passed = TestRunner.run([("native application / SSH askpass helper", {
        let broker = try AskpassServer(password: "fixture-only-askpass")
        defer { broker.stop() }
        var environment = ProcessInfo.processInfo.environment
        environment["ICONTROL_ASKPASS"] = "1"
        environment["ICONTROL_ASKPASS_SOCKET"] = broker.path
        environment["ICONTROL_ASKPASS_TOKEN"] = broker.token
        let result = try ProcessRunner.run(executable: helper, arguments: ["root@localhost's password:"], environment: environment, timeout: 5)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.outputText, "fixture-only-askpass\n")
        XCTAssertTrue(result.errorText.isEmpty)
    })])
    exit(passed ? 0 : 1)
}

let environment = EnvironmentTests(), mux = USBMuxTests(), forwarder = ForwarderTests()
let websocket = WebSocketTests(), process = ProcessAndCredentialTests(), install = InstallationScriptTests()
let fpsEngine = FPSEngineTests(), fpsDaemon = FPSDaemonTests()
let deviceCursor = FPSDeviceCursorTests()
let fpsLayout = FPSLayoutTests()
let fpsMapping = FPSMappingTests()
let fpsCustom = FPSCustomButtonTests()
let fpsSwipe = FPSSwipeAndMappingTests()
let fpsKeyboard = FPSKeyboardMovementTests()
let fpsCursor = FPSCursorTests()
let fpsLinks = FPSKeyLinkTests()
let checks: [(String, () throws -> Void)] = [
    ("WASD center dwell / smooth initial travel / rapid edges", fpsKeyboard.testCenterDownSurvivesRapidEdgesAndInitialTravelIsSmooth),
    ("WASD all diagonal releases / continuous native touch / retained fire aim look / mapped origins", fpsKeyboard.testAllDiagonalReleasesKeepOneNativeTouchAndOtherFingers),
    ("WASD independent axis offsets / linear add and release / tick rates", fpsKeyboard.testIndependentAxesAndLinearTravelAcrossTickRates),
    ("WASD rapid retarget / no snap / no obsolete trajectory backlog", fpsKeyboard.testRapidRetargetReplacesOldTravelWithoutSnapOrBacklog),
    ("WASD reversal / straight path / constant travel speed", fpsKeyboard.testReversalsTravelStraightAtBoundedSpeed),
    ("WASD stop / canceled anchor and travel / native up / capture release", fpsKeyboard.testStopDuringAnchorOrTravelAndCaptureReleaseCannotResume),
    ("WASD legacy recenter migration / geometry bindings links timing preserved", fpsKeyboard.testLegacyRecenterProfilesKeepLayoutAndUseContinuousWheel),
    ("WASD latest opposing key / fallback / repeat suppression", fpsKeyboard.testOppositeKeysPreferLatestAndRestoreHeldDirection),
    ("WASD preview / eight independent-axis targets / one native down move up", fpsKeyboard.testMovementPreviewReachesNativeDaemonWithOneFingerLifecycle),
    ("WASD all-up handoff / coalesced tick / continuous retarget", fpsKeyboard.testAllUpHandoffWithinTickRetargetsWithoutCenterOrLift),
    ("WASD partial diagonal release / short correction / no overshoot", fpsKeyboard.testReleaseDuringPartialDiagonalTravelReturnsWithoutOvershoot),
    ("WASD legacy analog option / independent mouse look / timing persistence", fpsKeyboard.testLegacyMouseJoystickCannotConsumeLookAndSettingsPersist),
    ("Esc mapping / retained capture movement pointer / native edges", fpsLinks.testEscapeMappingKeepsCaptureMovementAndPointer),
    ("linked holds / simultaneous native edges / shared owners", fpsLinks.testLinkedHoldsPressAndReleaseTogetherAndKeepOtherOwners),
    ("linked cursor / cycles / deduplication / repeat / retained actions", fpsLinks.testLinkedCursorTogglesOnceAndRetainsLinkedKeyboardActions),
    ("linked tap swipe / finish after release / retrigger", fpsLinks.testLinkedTapAndSwipeFinishAfterReleaseAndCanRetrigger),
    ("key links CRUD / legacy persistence / reserved keys / validation", fpsLinks.testKeyLinksCRUDLegacyPersistenceAndValidation),
    ("legacy daemon / upgrade required before capture", fpsSwipe.testLegacyDaemonRequiresUpgradeBeforeCapture),
    ("all mapping CRUD / deleted presets / undo / persistence", fpsSwipe.testAllMappingsCRUDAndLegacyPersistence),
    ("swipe four directions / continuous path / endpoint / held fingers / release", fpsSwipe.testSwipesEveryDirectionKeepHeldFingersAndFinishAtEndpoint),
    ("swipe persistence / validation / retrigger / calibration", fpsSwipe.testSwipePersistenceValidationRetriggerAndCalibration),
    ("device cursor / wire coordinates / reserved bytes / touch separation", deviceCursor.testCursorWireCoordinatesReservedBytesAndTouchSeparation),
    ("device cursor / native hover / rotation / hide / retained movement", deviceCursor.testNativeCursorHoverRotationHideAndRetainedMovement),
    ("device cursor / unavailable renderer / renderer crash / retained input", deviceCursor.testRendererFailureAndUnavailableCursorKeepTouchServiceWorking),
    ("device cursor / renderer watchdog / stopped parent", deviceCursor.testCursorWatchdogAndRendererParentStallHidePointer),
    ("device cursor / old touch daemon / Mac click mode compatibility", deviceCursor.testTouchOnlyDaemonKeepsMacClickModeWithoutCursorOpcode),
    ("cursor mode / retained keyboard / released look and mouse actions", fpsCursor.testCursorToggleRetainsKeyboardAndReleasesLookAndMouseBindings),
    ("cursor click drag / calibration / final endpoint / native down move up", fpsCursor.testPointerClickDragCalibrationFinalMoveAndNativeEdges),
    ("cursor coordinates / black bars / clamped drag / invalid geometry", fpsCursor.testViewportRejectsBlackBarsAndClampsDraggingAtEdges),
    ("cursor shortcut / legacy defaults / persistence / native key path", fpsCursor.testCursorShortcutLegacyDefaultsPersistenceAndCapturePath),
    ("native UIKit landscape orientation / swipe down move up", fpsSwipe.testNativeInterfaceOrientationEnumsAndSwipeEdges),
    ("architecture / correct package / mismatch", environment.testArchitectureChoosesRootlessOrRootfulAndRejectsMismatch),
    ("missing dependency blocks installation", environment.testMissingDependencyPreventsInstallation),
    ("loopback configuration / password limits", environment.testConfigurationLimitsServiceToUSBAndDisablesUnneededServices),
    ("credential and shell-argument validation", environment.testCredentialsRejectShellInjectionAndPasswordLineBreaks),
    ("fragmented usbmux frames / USB filtering", mux.testFragmentedDeviceListExcludesNetworkAndMalformedEntries),
    ("usbmux port byte order / raw stream", mux.testConnectUsesNetworkPortOrderAndReturnsRawStream),
    ("malformed usbmux frame lengths / tags", mux.testMalformedLengthAndWrongResponseTagAreRejected),
    ("unavailable service / unrelated protocol", mux.testRefusedServiceAndUnrelatedProtocolDoNotAppearReady),
    ("Lockdown framing / device information", mux.testLockdownBigEndianFramingReadsDeviceDetails),
    ("SSH banner deadline / port 44 fallback", mux.testSSHTricklingBannerHasTotalDeadlineAndFallsBackToPort44),
    ("occupied port preserves its owner", forwarder.testOccupiedPortIsPreservedAndFallbackPortWorks),
    ("2 MiB relay / backpressure / half-close", forwarder.testLargeBidirectionalRelayHandlesBackpressureAndHalfClose),
    ("idle relay cancellation / owner lifetime", forwarder.testStopCancelsAnIdleRelayAndReleasesItsOwner),
    ("descriptor cancellation / recycling", forwarder.testCancelDoesNotCloseAndRepeatedCloseDoesNotCloseRecycledDescriptor),
    ("WebSocket RFC handshake / origin", websocket.testRFCHandshakeAndOriginValidation),
    ("WebSocket masking / short and long lengths", websocket.testMaskedFramesHandleAllLengthFormsAndRejectUnmaskedFrames),
    ("WebSocket oversized / malformed frames", websocket.testOversizedAndFragmentedControlFramesAreRejectedWithoutReadingPayload),
    ("viewer token / directory traversal", websocket.testLocalServerRequiresTokenAndBlocksDirectoryTraversal),
    ("WebSocket bridge / fragments / ping / idle / stop", websocket.testBinaryBridgeFragmentationPingIdleAndStop),
    ("process pipes / 3 MiB upload", process.testLargeInputAndOutputAreDrainedConcurrently),
    ("process deadline / cancellation", process.testTimeoutAndCancellationTerminateOnlyTheOwnedProcess),
    ("native askpass / request authentication", process.testNativeAskpassRequiresTokenAndPasswordPrompt),
    ("package integrity / corruption", process.testPackageHashRejectsCorruptFiles),
    ("SSH trust reset preserves other devices", process.testTrustResetPreservesOtherDevices),
    ("remote scripts / POSIX syntax", process.testRemoteScriptsAreValidPOSIXShell),
    ("installation / backup / restore", install.testInstallationBacksUpConfigurationAndRestoreReturnsOriginal),
    ("installation failure / rollback", install.testFailedPackageInstallationRollsBackConfiguration),
    ("newer installed package is preserved", install.testExistingNewerVersionIsConfiguredWithoutDowngrade),
    ("restore failure / configuration preservation", install.testFailedRestoreKeepsCurrentConfigurationAndBackup),
    ("FPS installation / reinstall / original files", install.testFPSInstallReinstallAndRestoreOriginalFiles),
    ("FPS service start failure / both services rollback", install.testFPSStartFailureRollsBackBothServices),
    ("FPS fresh install failure / restore removes new daemon", install.testFPSFirstInstallFailureLeavesNoFilesAndRestoreRemovesNewDaemon),
    ("FPS restore failure / current video and input preserved", install.testFPSRestoreFailureKeepsCurrentVideoInputAndBackups),
    ("FPS transfer corruption / no video mutation", install.testFPSPayloadCorruptionStopsBeforeVideoMutation),
    ("FPS movement / anchor / diagonal / opposing keys", fpsEngine.testJoystickAnchoringDiagonalAndOppositeKeys),
    ("FPS simultaneous movement / look / fire / aim", fpsEngine.testSimultaneousMoveLookFireAndAim),
    ("FPS look rebase / narrow region / retained actions", fpsEngine.testLookRebasePreservesOtherContactsAndNarrowRegionProgresses),
    ("FPS taps / repeat / rapid retrigger", fpsEngine.testTapDurationRepeatSuppressionAndRapidRetrigger),
    ("FPS maximum contacts / stable action identifiers", fpsEngine.testContactLimitAndDeterministicActionIDs),
    ("FPS sensitivity / aspect / inverted look", fpsEngine.testMouseSensitivityAspectAndInversion),
    ("FPS profiles / calibration / persistence / invalid bindings", fpsEngine.testProfileValidationCalibrationAndPersistence),
    ("FPS layout / legacy marker sizes / custom size persistence", fpsLayout.testLegacySizesAndCustomSizePersistence),
    ("FPS layout / screen bounds / aspect / invalid geometry", fpsLayout.testGeometryClampsToScreenAndRejectsInvalidValues),
    ("FPS layout / grouped drag undo / cancelled drag / draft isolation", fpsLayout.testDragIsOneUndoStepAndCancelledDragIsDiscarded),
    ("FPS layout / reset undo / rejected bindings / redo branching", fpsLayout.testResetAndRejectedBindingPreserveUndoHistory),
    ("FPS layout / disabled action preview / edited input coordinates", fpsLayout.testPreviewShowsDisabledBindingsAndEditedPointsDriveInput),
    ("FPS calibration / old-profile compatibility / persistence", fpsMapping.testLegacyProfileAndCalibrationPersistence),
    ("FPS calibration / rotation / offsets / mirrors / bounds", fpsMapping.testCalibratedTouchPositionsAndBounds),
    ("FPS mouse / independent horizontal and vertical axis correction", fpsMapping.testMouseAxesCanBeCorrectedIndependentlyOfTouchPositions),
    ("FPS preset buttons / every selectable key / all action contacts", fpsMapping.testEverySelectableKeyAndEveryActionCanProduceAContact),
    ("FPS custom buttons / legacy profiles / save and reload", fpsCustom.testLegacyProfilesAndCustomButtonsSurviveReload),
    ("FPS custom buttons / add / delete / drag / undo / conflicts", fpsCustom.testAddDeleteDragUndoAndConflicts),
    ("FPS custom buttons / limits / independent available keys / invalid data", fpsCustom.testCustomValidationLimitsAndUnoccupiedKeys),
    ("FPS custom buttons / stable held fingers / preset ID collision", fpsCustom.testCustomAndPresetContactLeasesRemainStable),
    ("FPS custom buttons / every key / rapid taps / calibrated previews", fpsCustom.testTapRetriggerPreviewAndEveryCustomKey),
    ("FPS custom buttons / ten-finger limit / stable held buttons / waiting inputs", fpsCustom.testCustomContactLimitKeepsHeldButtonsAndAdmitsWaitingButtons),
    ("native FPS custom buttons / v1 compatibility / independent finger edges", fpsCustom.testNativeDaemonAcceptsCustomButtonsWithoutChangingProtocol),
    ("FPS wire / quantization / malformed frames / credentials", fpsEngine.testWireRoundTripAndMalformedPackets),
    ("native FPS authentication / one owner / rejected probes", fpsDaemon.testAuthenticationSingleOwnerAndUnauthenticatedProbes),
    ("native FPS fragments / rotation / independent finger edges", fpsDaemon.testFragmentedStateRotationAndIndependentFingerEdges),
    ("native FPS orientation change / release / reanchor", fpsDaemon.testOrientationChangeReleasesAndReanchors),
    ("native FPS calibrated tests / every action / released contacts", fpsDaemon.testCalibratedPreviewReachesEveryNativeActionAndReleases),
    ("native FPS watchdog / partial packet deadline", fpsDaemon.testWatchdogHasOneDeadlineForFragmentedHeaderAndBody),
    ("native FPS malformed contacts / reserved / replay", fpsDaemon.testMalformedContactsReservedBytesAndSequenceReleaseOwner),
    ("FPS USB link / heartbeat / release / lifetime", fpsDaemon.testSwiftLinkHeartbeatReleaseAndLifetime),
    ("FPS USB queue / one failure / all contacts released", fpsDaemon.testSwiftLinkFailureAndBoundedQueueRelease),
    ("native FPS shutdown / private token files", fpsDaemon.testShutdownReleasesAndInvalidTokenFilesAreRejected)
]
exit(TestRunner.run(checks) ? 0 : 1)
