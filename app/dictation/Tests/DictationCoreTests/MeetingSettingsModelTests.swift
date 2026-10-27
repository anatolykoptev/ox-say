import Foundation
import XCTest
@testable import DictationCore

/// The Settings page's values: loaded from the stores, diffed into changes, and saved the way each setting needs.
final class MeetingSettingsModelTests: XCTestCase {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "mw2-settings-\(UUID().uuidString)")! }
    private let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

    private func values(_ d: UserDefaults, daemon: MeetingRetention? = nil) -> MeetingSettingsValues {
        MeetingSettingsModel.load(defaults: d, daemonRetention: daemon, notesWriter: .ready, fullName: "Alex Morgan", home: home)
    }

    private func client(_ answer: String = "{}", status: Int = 200, record: ((URLRequest) -> Void)? = nil) -> StudioClient {
        StudioClient(baseURL: URL(string: "http://127.0.0.1:8094")!) { request in
            record?(request)
            return (Data(answer.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    // MARK: load

    func testFreshInstallLoadsTheDefaults() {
        let v = values(suite())
        XCTAssertFalse(v.enabled, "meetings are off until the user turns them on")
        XCTAssertTrue(v.autoStart)
        XCTAssertEqual(v.retention, .month)
        XCTAssertEqual(v.folderPath, "~/Documents/ox-say Meetings".replacingOccurrences(of: "~", with: "/Users/test"))
        XCTAssertEqual(v.yourName, "")
        XCTAssertEqual(v.yourNameFallback, "Alex Morgan")
        XCTAssertEqual(v.apps.map(\.id), CallPolicy.sources)
    }

    func testStoredValuesAreLoaded() {
        let d = suite()
        d.set(true, forKey: MeetingSettings.enabledKey)
        MeetingSettings.setAutoStart(false, d)
        MeetingSettings.setRetention(.quarter, d)
        MeetingSettings.setFolder(URL(fileURLWithPath: "/Volumes/Notes"), d)
        MeetingSettings.setDisplayName("Alex", d)
        CallPolicy.setMode(.never, for: "discord", d)
        let v = values(d)
        XCTAssertTrue(v.enabled)
        XCTAssertFalse(v.autoStart)
        XCTAssertEqual(v.retention, .quarter)
        XCTAssertEqual(v.folderPath, "/Volumes/Notes")
        XCTAssertEqual(v.yourName, "Alex")
        XCTAssertEqual(v.apps.first { $0.id == "discord" }?.mode, .never)
    }

    /// The daemon deletes the audio, so what it says wins over the app's copy of the pick.
    /// Mutation: MeetingSettingsModel.load, `daemonRetention ??` -> `retention(d)` only -> RED.
    func testTheDaemonsRetentionWinsOverTheLocalCopy() {
        let d = suite()
        MeetingSettings.setRetention(.week, d)
        XCTAssertEqual(values(d, daemon: .forever).retention, .forever)
        XCTAssertEqual(values(d, daemon: nil).retention, .week, "daemon unreachable: the last pick is shown")
    }

    // MARK: diff

    func testNothingChangedIsNoChange() {
        let v = values(suite())
        XCTAssertEqual(MeetingSettingsModel.changes(from: v, to: v), [])
    }

    func testEachEditedFieldIsOneChange() {
        let old = values(suite())
        var new = old
        new.enabled = true
        new.autoStart = false
        new.retention = .week
        new.yourName = "Alex"
        new.apps[new.apps.firstIndex { $0.id == "zoom" }!].mode = .never
        let changes = MeetingSettingsModel.changes(from: old, to: new)
        XCTAssertEqual(changes, [.enabled(true), .autoStart(false), .retention(.week), .name("Alex"), .mode(source: "zoom", mode: .never)])
    }

    // MARK: save

    func testEnablingAndAutoStartAndNameAndModeAreStored() async {
        let d = suite()
        let applier = MeetingSettingsApplier(defaults: d, client: client())
        let results = [await applier.apply(.enabled(true)), await applier.apply(.autoStart(false)), await applier.apply(.name("  Alex  ")),
                       await applier.apply(.mode(source: "slack", mode: .auto))]
        XCTAssertEqual(results.compactMap { $0 }, [])
        XCTAssertTrue(MeetingSettings.enabled(d))
        XCTAssertFalse(MeetingSettings.autoStart(d))
        XCTAssertEqual(MeetingSettings.displayName(d, fallback: "x"), "Alex")
        XCTAssertEqual(CallPolicy.mode(for: "slack", d), .auto)
    }

    /// The pick reaches the daemon (which deletes the audio) before the app remembers it.
    /// Mutation: MeetingSettingsApplier.apply, delete the `client.setMeetingRetention(days:` call -> RED.
    func testRetentionIsSentToTheDaemonThenStored() async throws {
        let d = suite()
        var seen: URLRequest?
        let failure = await MeetingSettingsApplier(defaults: d, client: client(record: { seen = $0 })).apply(.retention(.week))
        XCTAssertNil(failure)
        XCTAssertEqual(seen?.httpMethod, "PUT")
        XCTAssertEqual(seen?.url?.path, "/v1/meetings/settings")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(seen?.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["retention_days"] as? Int, 7)
        XCTAssertEqual(MeetingSettings.retention(d), .week)
    }

    /// A pick the daemon did not take is not remembered, and the user is told why.
    /// Mutation: MeetingSettingsApplier.apply, store the retention before the request -> RED.
    func testRetentionTheDaemonRefusedIsNotStoredAndIsSaid() async {
        let d = suite()
        MeetingSettings.setRetention(.month, d)
        let failure = await MeetingSettingsApplier(defaults: d, client: client(status: 500)).apply(.retention(.forever))
        XCTAssertNotNil(failure)
        XCTAssertEqual(MeetingSettings.retention(d), .month)
        let down = StudioClient(baseURL: URL(string: "http://127.0.0.1:8094")!) { _ in throw URLError(.cannotConnectToHost) }
        let unreachable = await MeetingSettingsApplier(defaults: d, client: down).apply(.retention(.forever), text: { $0.rawValue })
        XCTAssertEqual(unreachable, "settings.save_failed")
        XCTAssertEqual(MeetingSettings.retention(d), .month)
    }
}

/// The dictation sound pick.
final class DictationSettingsTests: XCTestCase {
    private func suite() -> UserDefaults { UserDefaults(suiteName: "mw2-dictation-\(UUID().uuidString)")! }

    /// Pause Music must survive the read-back: only `choose` marks it as a real pick. A direct write of the raw value
    /// is migrated to Lower All Sound on the next read.
    /// Mutation: DictationSettings.setSound, `SoundWhileDictatingSetting.choose(mode, in: defaults)` ->
    /// `defaults.set(mode.rawValue, forKey: SoundWhileDictatingSetting.defaultsKey)` -> RED.
    func testAPauseMusicPickSticks() {
        let d = suite()
        DictationSettings.setSound(.pauseMusic, d)
        XCTAssertEqual(SoundWhileDictatingSetting.mode(d), .pauseMusic)
        XCTAssertEqual(DictationSettings.sound(d), .pauseMusic)
        DictationSettings.setSound(.dontTouch, d)
        XCTAssertEqual(DictationSettings.sound(d), .dontTouch)
    }

    func testTheDefaultIsLowerAllSound() {
        XCTAssertEqual(DictationSettings.sound(suite()), .lowerAllSound)
    }

    func testTheHoldOrToggleModeIsTheStoredOne() {
        let d = suite()
        XCTAssertEqual(DictationSettings.mode(d), .hold)
        DictationSettings.setMode(.toggle, d)
        XCTAssertEqual(DictationSettings.mode(d), .toggle)
        XCTAssertEqual(d.string(forKey: DictationSettings.modeKey), "toggle")
    }
}

/// The permission rows.
final class PermissionModelTests: XCTestCase {
    private func state(_ items: [PermissionItem], _ id: String) -> PermissionState? { items.first { $0.id == id }?.state }

    func testTheFourPermissionsWithTheirPanes() {
        let items = PermissionModel.items(microphone: .authorized, accessibility: true, notifications: .authorized)
        XCTAssertEqual(items.map(\.id), ["mic", "audio", "ax", "notifications"])
        XCTAssertEqual(items.map(\.pane), [.microphone, .systemAudio, .accessibility, .notifications])
    }

    func testMicrophoneAndNotificationsFollowTheirStatus() {
        func at(_ mic: PermissionAuth, _ ax: Bool, _ n: PermissionAuth) -> [PermissionItem] {
            PermissionModel.items(microphone: mic, accessibility: ax, notifications: n)
        }
        XCTAssertEqual(state(at(.authorized, true, .authorized), "mic"), .allowed)
        XCTAssertEqual(state(at(.denied, true, .authorized), "mic"), .needsAttention)
        XCTAssertEqual(state(at(.notDetermined, true, .authorized), "mic"), .needsAttention)
        XCTAssertEqual(state(at(.authorized, false, .authorized), "ax"), .needsAttention)
        XCTAssertEqual(state(at(.authorized, true, .denied), "notifications"), .needsAttention)
        XCTAssertEqual(state(at(.authorized, true, .notDetermined), "notifications"), .needsAttention)
    }

    /// macOS gives no way to ask whether System Audio Recording is allowed without showing a prompt: the row says so
    /// and never claims "Allowed".
    /// Mutation: PermissionModel.items, make the audio row `.allowed` -> RED.
    func testSystemAudioIsNeverClaimedAllowed() {
        for mic in [PermissionAuth.authorized, .denied] {
            XCTAssertEqual(state(PermissionModel.items(microphone: mic, accessibility: true, notifications: .authorized), "audio"), .unknown)
        }
    }

    func testPanesOpenTheirOwnPage() {
        XCTAssertEqual(PermissionPane.systemAudio.settingsURL, SystemAudioGuard.settingsURL)
        XCTAssertTrue(PermissionPane.microphone.settingsURL.hasSuffix("Privacy_Microphone"))
        XCTAssertTrue(PermissionPane.accessibility.settingsURL.hasSuffix("Privacy_Accessibility"))
        XCTAssertEqual(PermissionPane.notifications.settingsURL, "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }
}
