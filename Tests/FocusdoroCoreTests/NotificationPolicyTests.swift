import Testing
@testable import FocusdoroCore

@Suite("Updater notification policy")
struct UpdateNotificationPolicyTests {
    @Test("Updater notification identifiers remain stable")
    func updateIdentifiers() {
        #expect(NotificationService.updateCategoryIdentifier == "FOCUSDORO_UPDATE")
        #expect(NotificationService.installUpdateActionIdentifier == "INSTALL_UPDATE")
    }

    @Test("Update notification modes use accurate copy")
    func updateNotificationCopy() {
        #expect(NotificationPolicy.updateAvailableBody(automaticInstallEnabled: false) == "An update is available to review and install.")
        #expect(NotificationPolicy.updateAvailableBody(automaticInstallEnabled: true) == "Automatic installation is starting.")
    }

    @Test("Only install action routes updater")
    func updateActionRouting() {
        #expect(NotificationPolicy.isInstallUpdateAction("INSTALL_UPDATE"))
        #expect(!NotificationPolicy.isInstallUpdateAction("UNNotificationDefaultActionIdentifier"))
        #expect(!NotificationPolicy.isInstallUpdateAction("OTHER"))
    }
}
