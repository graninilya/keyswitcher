import AppKit
import Sparkle

/// Sparkle читает SUFeedURL/SUPublicEDKey/SUEnableAutomaticChecks из Info.plist —
/// дополнительный делегат для нашего сценария не нужен.
final class UpdaterController {
    static let shared = UpdaterController()

    let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }
}
