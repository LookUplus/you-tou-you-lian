import Testing
import Foundation
@testable import YellowPageCore
@testable import YellowPageApp

private final class AccessFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var readable = false
    private var permitted = false
    private var reads = 0
    func configure(messages: Bool, contacts: Bool) { lock.lock(); defer { lock.unlock() }; readable = messages; permitted = contacts }
    func messages() throws -> Int {
        lock.lock(); defer { lock.unlock() }; reads += 1
        if !readable { throw MessagesAccessError(kind: .permission, path: "/private-test/chat.db") }
        return 0 // No matching SMS is still a valid permission check.
    }
    func accounts() throws -> [WorkspaceAccount] {
        lock.lock(); defer { lock.unlock() }
        if !permitted { throw Failure("请允许完整访问联系人。") }
        return [WorkspaceAccount(id: "test-account", name: "测试账户", isDefault: true)]
    }
    func authorization() -> String { lock.lock(); defer { lock.unlock() }; return permitted ? "完整访问" : "未允许" }
    var messageReads: Int { lock.lock(); defer { lock.unlock() }; return reads }
    var readers: PreparationReaders { PreparationReaders(messages: { try self.messages() }, accounts: { try self.accounts() }, authorization: { self.authorization() }) }
}

@MainActor @Suite(.serialized) final class PreparationPermissionTests {
    let suite = "yellowpage-permission-test-" + UUID().uuidString
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("yellowpage-permission-test-" + UUID().uuidString)
    let defaults: UserDefaults
    private let access = AccessFixture()
    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let file = root.appendingPathComponent("bank.vcf")
        try Data("BEGIN:VCARD\r\nVERSION:3.0\r\nFN:测试银行\r\nORG:测试银行;\r\nEND:VCARD\r\n".utf8).write(to: file)
        var prefs = DesktopPreferences(); prefs.mode = "personal"; prefs.templatePath = file.path; prefs.accountID = "test-account"; prefs.save(to: defaults)
    }
    deinit { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    func model() -> AppModel { AppModel(defaults: defaults, baseDirectory: root, readers: access.readers) }
    func finish(_ m: AppModel) async throws {
        let deadline = Date().addingTimeInterval(8)
        while m.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(!m.busy)
    }
    @Test func missingAccessBlocksScanAndRetryWithZeroSMSUnlocksIt() async throws {
        access.configure(messages: false, contacts: true)
        let m = model(); m.start(); try await finish(m)
        #expect(!m.canScan); #expect(!m.messageState.isAvailable); #expect(m.accounts.count == 1)
        #expect(m.error == nil); #expect(m.messageAccess.contains("目前无法读取"))
        access.configure(messages: true, contacts: true); m.checkMessages(); try await finish(m)
        #expect(m.messageState == .available(0)); #expect(m.canScan)
    }
    @Test func failedCheckNeverKeepsEarlierSuccess() async throws {
        access.configure(messages: true, contacts: true)
        let m = model(); m.start(); try await finish(m); #expect(m.canScan)
        access.configure(messages: false, contacts: true); m.checkMessages(); try await finish(m)
        #expect(!m.messageState.isAvailable); #expect(!m.canScan); #expect(m.plan == nil); #expect(m.selected.isEmpty)
    }
    @Test func restartRestoresChoicesButMustReadAccessAgain() async throws {
        access.configure(messages: true, contacts: true)
        let m = model(); m.start(); try await finish(m); #expect(m.canScan)
        access.configure(messages: false, contacts: true)
        let restarted = model(); #expect(!restarted.messageState.isAvailable); #expect(!restarted.canScan)
        restarted.start(); try await finish(restarted)
        #expect(restarted.template == m.template); #expect(restarted.accountID == m.accountID)
        #expect(!restarted.canScan); #expect(access.messageReads == 2)
    }
    @Test func openingSettingsInvalidatesCheckedAccessUntilRechecked() async throws {
        access.configure(messages: true, contacts: true)
        let m = model(); m.start(); try await finish(m); #expect(m.canScan)
        // Exercise the state boundary used by Settings without opening or changing the user's Settings.
        m.invalidateMessageAccess(); #expect(!m.canScan); #expect(m.messageState == .unchecked)
        m.checkMessages(); try await finish(m); #expect(m.canScan)
        m.invalidateContactAccess(); #expect(m.accounts.isEmpty); #expect(!m.canScan)
        m.loadAccounts(); try await finish(m); #expect(m.canScan)
    }
    @Test func contactDenialClearsCachedAccountsAndAllowsRecovery() async throws {
        access.configure(messages: true, contacts: true)
        let m = model(); m.start(); try await finish(m); #expect(m.canScan)
        access.configure(messages: true, contacts: false); m.loadAccounts(); try await finish(m)
        #expect(m.accounts.isEmpty); #expect(!m.contactState.isAvailable); #expect(!m.canScan)
        #expect(m.contactAccess.contains("完整访问"))
        access.configure(messages: true, contacts: true); m.loadAccounts(); try await finish(m); #expect(m.canScan)
    }
    @Test func contactRevocationWhileAppIsInactiveBlocksScanOnReturn() async throws {
        access.configure(messages: true, contacts: true)
        let m = model(); m.start(); try await finish(m); #expect(m.canScan)
        access.configure(messages: true, contacts: false); m.refreshContactAuthorization()
        #expect(m.accounts.isEmpty); #expect(!m.canScan); #expect(m.contactAccess.contains("权限已变化"))
    }
    @Test func scanPreflightDetectsRevokedMessagesWithoutStartingPersonalScan() async throws {
        access.configure(messages: true, contacts: true)
        let m = model(); m.start(); try await finish(m)
        access.configure(messages: false, contacts: true); m.scan(); try await finish(m)
        #expect(m.page == .prepare); #expect(m.plan == nil); #expect(!m.canScan)
        #expect(m.notice.contains("暂时无法读取"))
    }
    @Test func demoNeverCallsPersonalPermissionReaders() async throws {
        let m = model(); m.changeMode(.demo); try await finish(m)
        #expect(m.isDemo); #expect(m.canScan); #expect(access.messageReads == 0)
        m.scan(); try await finish(m); #expect(m.plan?.additions.count == 3)
    }
    @Test func missingDatabaseDoesNotClaimFullDiskAccessIsRequired() throws {
        do { _ = try MessagesDatabase.read(root.appendingPathComponent("missing.db").path); Issue.record("Expected missing database error") }
        catch let error as MessagesAccessError {
            #expect(error.kind == .missingDatabase)
            #expect(DesktopError.message(error).contains("同步"))
            #expect(!DesktopError.message(error).contains("完全磁盘"))
            #expect(!DesktopError.message(error).contains(root.path))
        }
    }
}
