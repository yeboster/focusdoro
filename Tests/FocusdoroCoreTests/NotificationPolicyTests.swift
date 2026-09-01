import Testing
@testable import FocusdoroCore

@Suite("Updater notification policy")
struct UpdateNotificationPolicyTests {
    @Test("Updater notification identifiers remain stable")
    func updateIdentifiers() {
        #expect(NotificationService.updateCategoryIdentifier == "FOCUSDORO_UPDATE")
        #expect(NotificationService.installUpdateActionIdentifier == "INSTALL_UPDATE")
    }

    @Test("Only install action routes updater")
    func updateActionRouting() {
        #expect(NotificationPolicy.isInstallUpdateAction("INSTALL_UPDATE"))
        #expect(!NotificationPolicy.isInstallUpdateAction("UNNotificationDefaultActionIdentifier"))
        #expect(!NotificationPolicy.isInstallUpdateAction("OTHER"))
    }
}
