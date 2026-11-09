import XCTest
@testable import PodSwitchCore

@MainActor
final class CoordinatorTests: XCTestCase {

    // MARK: - Fakes

    final class FakeMonitor: AudioMonitoring {
        weak var delegate: AudioMonitorDelegate?
        private(set) var started = false
        private(set) var stopped = false

        func start() { started = true }
        func stop() { stopped = true }

        /// Drive an event as if CoreAudio reported it.
        func emit(_ event: SwitchEvent) {
            delegate?.audioMonitor(self, didEmit: event)
        }
    }

    /// Records connect attempts without performing a real connection.
    final class FakeBluetooth: BluetoothConnecting, @unchecked Sendable {
        var paired = true
        var active = false
        private(set) var connectCount = 0

        func isActiveOutput(deviceId: String) -> Bool { active }
        func isPaired(deviceId: String) -> Bool { paired }
        func connect(deviceId: String) {
            connectCount += 1
        }
    }

    final class FakeNotifier: Notifying {
        private(set) var promptCount = 0

        func showSwitchPrompt() { promptCount += 1 }
    }

    final class FakeSettings: SettingsStore, PeerSettingsProviding {
        var config: Config
        var peerSettings: PeerSettings
        init(_ config: Config, peerSettings: PeerSettings = PeerSettings()) {
            self.config = config
            self.peerSettings = peerSettings
        }
    }

    actor FakePeer: PeerSwitching {
        private(set) var releaseCount = 0
        func releasePeer(host: String, port: UInt16) async -> Bool {
            releaseCount += 1
            return true
        }
        func checkPeer(host: String, port: UInt16) async -> Bool { true }
    }

    private func makeConfig(
        enabled: Bool = true,
        mode: Mode = .steal,
        target: String? = "aa-bb-cc-dd-ee-ff"
    ) -> Config {
        Config(
            enabled: enabled,
            mode: mode,
            enabledCategories: [.media],
            targetDeviceId: target
        )
    }

    private func makeCoordinator(
        config: Config,
        bluetooth: FakeBluetooth
    ) -> (Coordinator, FakeMonitor, FakeNotifier, FakeSettings) {
        let monitor = FakeMonitor()
        let notifier = FakeNotifier()
        let settings = FakeSettings(config)
        let coordinator = Coordinator(
            monitor: monitor,
            bluetooth: bluetooth,
            notifier: notifier,
            settings: settings
        )
        return (coordinator, monitor, notifier, settings)
    }

    // MARK: - Lifecycle

    func testStartAndStopForwardToMonitor() {
        let (coordinator, monitor, _, _) = makeCoordinator(
            config: makeConfig(),
            bluetooth: FakeBluetooth()
        )
        coordinator.start()
        coordinator.stop()
        XCTAssertTrue(monitor.started)
        XCTAssertTrue(monitor.stopped)
    }

    func testInitWiresDelegate() {
        let bt = FakeBluetooth()
        let (coordinator, monitor, _, _) = makeCoordinator(config: makeConfig(), bluetooth: bt)
        withExtendedLifetime(coordinator) {
            XCTAssertNotNil(monitor.delegate)
        }
    }

    // MARK: - Connect dispatch

    func testStealAudioStartedConnects() {
        let bt = FakeBluetooth()
        bt.paired = true
        bt.active = false
        let (coordinator, monitor, notifier, _) = makeCoordinator(config: makeConfig(mode: .steal), bluetooth: bt)
        withExtendedLifetime(coordinator) {
            monitor.emit(.audioStarted(.media))
        }
        XCTAssertEqual(bt.connectCount, 1)
        XCTAssertEqual(notifier.promptCount, 0)
    }

    func testAlreadyActiveDoesNotConnect() {
        let bt = FakeBluetooth()
        bt.active = true
        let (coordinator, monitor, notifier, _) = makeCoordinator(config: makeConfig(mode: .steal), bluetooth: bt)
        withExtendedLifetime(coordinator) {
            monitor.emit(.audioStarted(.media))
        }
        XCTAssertEqual(bt.connectCount, 0)
        XCTAssertEqual(notifier.promptCount, 0)
    }

    func testNotPairedDoesNotConnectOnAudioStarted() {
        let bt = FakeBluetooth()
        bt.paired = false
        let (coordinator, monitor, notifier, _) = makeCoordinator(config: makeConfig(mode: .steal), bluetooth: bt)
        withExtendedLifetime(coordinator) {
            monitor.emit(.audioStarted(.media))
        }
        XCTAssertEqual(bt.connectCount, 0)
    }

    func testPeerModeOverridesAskAndSwitchesWithoutPrompt() async {
        let bt = FakeBluetooth()
        let monitor = FakeMonitor()
        let notifier = FakeNotifier()
        let settings = FakeSettings(
            makeConfig(mode: .ask),
            peerSettings: PeerSettings(enabled: true, host: "windows-pc.example.ts.net")
        )
        let peer = FakePeer()
        let coordinator = Coordinator(
            monitor: monitor,
            bluetooth: bt,
            peer: peer,
            notifier: notifier,
            settings: settings
        )

        monitor.emit(.audioStarted(.media))
        try? await Task.sleep(for: .milliseconds(50))

        let releaseCount = await peer.releaseCount
        XCTAssertEqual(releaseCount, 1)
        XCTAssertEqual(bt.connectCount, 1)
        XCTAssertEqual(notifier.promptCount, 0)
        XCTAssertFalse(coordinator.notificationPending)
    }

    // MARK: - Notify dispatch & pending stacking

    func testAskAudioStartedNotifiesAndSetsPending() {
        let bt = FakeBluetooth()
        let (coordinator, monitor, notifier, _) = makeCoordinator(config: makeConfig(mode: .ask), bluetooth: bt)
        monitor.emit(.audioStarted(.media))
        XCTAssertEqual(notifier.promptCount, 1)
        XCTAssertTrue(coordinator.notificationPending)
    }

    func testAskSecondAudioStartedDoesNotStackNotifications() {
        let bt = FakeBluetooth()
        let (coordinator, monitor, notifier, _) = makeCoordinator(config: makeConfig(mode: .ask), bluetooth: bt)
        withExtendedLifetime(coordinator) {
            monitor.emit(.audioStarted(.media))
            monitor.emit(.audioStarted(.media))
        }
        XCTAssertEqual(notifier.promptCount, 1)
    }

    func testSuccessfulConnectClearsPending() {
        let bt = FakeBluetooth()
        let (coordinator, monitor, _, _) = makeCoordinator(config: makeConfig(mode: .ask), bluetooth: bt)
        monitor.emit(.audioStarted(.media))
        XCTAssertTrue(coordinator.notificationPending)
        coordinator.handle(.userAcceptedSwitch)
        XCTAssertEqual(bt.connectCount, 1)
        XCTAssertFalse(coordinator.notificationPending)
    }

    func testNotifyAgainAfterPendingCleared() {
        let bt = FakeBluetooth()
        let (coordinator, monitor, notifier, _) = makeCoordinator(config: makeConfig(mode: .ask), bluetooth: bt)
        monitor.emit(.audioStarted(.media))
        coordinator.handle(.userAcceptedSwitch)
        monitor.emit(.audioStarted(.media))
        XCTAssertEqual(notifier.promptCount, 2)
    }

    // MARK: - UserAcceptedSwitch

    func testUserAcceptedNotPairedDoesNotConnect() {
        let bt = FakeBluetooth()
        let (coordinator, monitor, _, _) = makeCoordinator(config: makeConfig(mode: .ask), bluetooth: bt)
        monitor.emit(.audioStarted(.media))
        XCTAssertTrue(coordinator.notificationPending)
        bt.paired = false
        coordinator.handle(.userAcceptedSwitch)
        XCTAssertEqual(bt.connectCount, 0)
        XCTAssertTrue(coordinator.notificationPending)
    }

    func testUserAcceptedAlreadyActiveDoesNothing() {
        let bt = FakeBluetooth()
        bt.active = true
        let coordinator = Coordinator(
            monitor: FakeMonitor(),
            bluetooth: bt,
            notifier: FakeNotifier(),
            settings: FakeSettings(makeConfig(mode: .ask))
        )
        coordinator.handle(.userAcceptedSwitch)
        XCTAssertEqual(bt.connectCount, 0)
    }

    func testUserAcceptedPairedNotActiveConnectsAndClearsPending() {
        let bt = FakeBluetooth()
        let (coordinator, monitor, _, _) = makeCoordinator(config: makeConfig(mode: .ask), bluetooth: bt)
        monitor.emit(.audioStarted(.media))
        XCTAssertTrue(coordinator.notificationPending)
        coordinator.handle(.userAcceptedSwitch)
        XCTAssertEqual(bt.connectCount, 1)
        XCTAssertFalse(coordinator.notificationPending)
    }

    // MARK: - None dispatch

    func testDisabledEmitsNothing() {
        let bt = FakeBluetooth()
        let (coordinator, monitor, notifier, _) = makeCoordinator(
            config: makeConfig(enabled: false, mode: .steal),
            bluetooth: bt
        )
        withExtendedLifetime(coordinator) {
            monitor.emit(.audioStarted(.media))
        }
        XCTAssertEqual(bt.connectCount, 0)
        XCTAssertEqual(notifier.promptCount, 0)
    }

    func testNilTargetEmitsNothing() {
        let bt = FakeBluetooth()
        let (coordinator, monitor, notifier, _) = makeCoordinator(
            config: makeConfig(mode: .steal, target: nil),
            bluetooth: bt
        )
        withExtendedLifetime(coordinator) {
            monitor.emit(.audioStarted(.media))
        }
        XCTAssertEqual(bt.connectCount, 0)
        XCTAssertEqual(notifier.promptCount, 0)
    }

    func testAudioStoppedEmitsNothing() {
        let bt = FakeBluetooth()
        let (coordinator, monitor, notifier, _) = makeCoordinator(config: makeConfig(mode: .ask), bluetooth: bt)
        monitor.emit(.audioStarted(.media))
        let pendingBefore = coordinator.notificationPending
        monitor.emit(.audioStopped)
        XCTAssertEqual(bt.connectCount, 0)
        XCTAssertEqual(coordinator.notificationPending, pendingBefore)
    }
}
