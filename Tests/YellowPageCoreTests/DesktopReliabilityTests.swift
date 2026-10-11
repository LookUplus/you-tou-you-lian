import Testing
import Foundation
import AppKit
@testable import YellowPageCore
@testable import YellowPageApp

@Suite(.serialized) final class DesktopReliabilityTests {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("yellowpage-reliability-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func workspace() -> DesktopWorkspace { DesktopWorkspace(mode: .demo, baseDirectory: root) }
    func plan(_ w: DesktopWorkspace) throws -> Plan { try w.scan(template: nil, container: "demo", since: .distantPast) }
    @Test func damagedHistoryDoesNotHideHealthyRecords() throws {
        let w = workspace(); let p = try plan(w)
        _ = try w.apply(plan: p, selected: [p.additions[0].sender], writer: "native")
        let broken = w.runsDirectory.appendingPathComponent("broken.journal.json")
        try Data("{broken".utf8).write(to: broken)
        #expect(try w.history().count == 1)
        #expect(w.historyWarnings.count == 1)
        #expect(try Data(contentsOf: broken) == Data("{broken".utf8))
        _ = try w.undo(path: #require(w.lastJournalPath))
        #expect(try plan(w).additions.count == 3)
    }
    @Test func unknownAndForeignRecordVersionsAreSkipped() throws {
        let w = workspace(); let p = try plan(w)
        var j = try w.apply(plan: p, selected: [p.additions[0].sender], writer: "native")
        j.version = 99
        try JSONFile.write(j, to: w.runsDirectory.appendingPathComponent("future.journal.json").path)
        j.version = 1; j.writer = "native"
        try JSONFile.write(j, to: w.runsDirectory.appendingPathComponent("real.journal.json").path)
        #expect(try w.history().count == 1); #expect(w.historyWarnings.count == 2)
    }
    @Test func unknownJournalStateIsNotReportedAsSuccess() throws {
        let w = workspace(); let p = try plan(w)
        var j = try w.apply(plan: p, selected: [p.additions[0].sender], writer: "native")
        j.entries[0].state = "unknown"
        try JSONFile.write(j, to: #require(w.lastJournalPath), overwrite: true)
        #expect(try w.history().isEmpty); #expect(w.historyWarnings.count == 1)
    }
    @Test func corruptedRecordCannotBeUndone() throws {
        let w = workspace(); let p = try plan(w)
        _ = try w.apply(plan: p, selected: [p.additions[0].sender], writer: "native")
        try Data("not JSON".utf8).write(to: URL(fileURLWithPath: #require(w.lastJournalPath)))
        #expect(throws: (any Error).self) { try w.undo(path: #require(w.lastJournalPath)) }
        #expect(try plan(w).additions.count == 2)
    }
    @Test func independentDemoSessionsDoNotBlockRealWrites() throws {
        let realLock = try RunLock()
        defer { withExtendedLifetime(realLock) {} }
        let w = workspace(); let p = try plan(w)
        _ = try w.apply(plan: p, selected: [p.additions[0].sender], writer: "native")
        #expect(try w.history().count == 1)
    }
    @Test func zipAndWrongFileTypesHaveActionableMessages() throws {
        let zip = root.appendingPathComponent("archive.zip")
        try Data("zip".utf8).write(to: zip)
        do { _ = try VCardCatalog.names(at: zip.path); Issue.record("ZIP should be rejected") }
        catch { #expect(String(describing: error).contains("解压")) }
        let yaml = root.appendingPathComponent("companies.yml")
        try Data("names".utf8).write(to: yaml)
        #expect(throws: (any Error).self) { try VCardCatalog.names(at: yaml.path) }
    }
    @Test func emptyAndDeletedTemplateDirectoriesFailBeforeScanning() throws {
        #expect(throws: (any Error).self) { try VCardCatalog.names(at: root.path) }
        #expect(throws: (any Error).self) { try VCardCatalog.names(at: root.appendingPathComponent("deleted.vcf").path) }
    }
    @Test func uppercaseAndNestedVcardsAreSupported() throws {
        let sub = root.appendingPathComponent("银行"); try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        let data = Data("BEGIN:VCARD\r\nVERSION:3.0\r\nFN:银行\r\nORG:银行;\r\nEND:VCARD\r\n".utf8)
        try data.write(to: sub.appendingPathComponent("银行.VCF"))
        #expect(try VCardCatalog.names(at: root.path) == ["银行"])
    }
    @Test func directoryNamedVcfIsIgnored() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("fake.vcf"), withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try VCardCatalog.names(at: root.path) }
    }
    @Test func missingOrganizationCannotMatchACompany() throws {
        let f = root.appendingPathComponent("individual.vcf")
        try Data("BEGIN:VCARD\r\nVERSION:3.0\r\nFN:姓名\r\nEND:VCARD\r\n".utf8).write(to: f)
        #expect(throws: (any Error).self) { try VCardCatalog.names(at: f.path) }
    }
    @Test func malformedDecisionCannotCrashOrWriteARecord() throws {
        let w = workspace(); var p = try plan(w)
        p.decisions[0].contactID = nil
        let repository = MemoryContacts([]); let file = root.appendingPathComponent("invalid.json")
        #expect(throws: (any Error).self) { try MutationEngine.apply(p.additions, plan: p, repository: repository, writer: "native", journalPath: file.path) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
    @Test func duplicateDecisionIsRejectedBeforeMutation() throws {
        let w = workspace(); var p = try plan(w); p.decisions.append(p.additions[0])
        let file = root.appendingPathComponent("invalid.json")
        #expect(throws: (any Error).self) { try MutationEngine.apply(p.additions, plan: p, repository: MemoryContacts([]), writer: "native", journalPath: file.path) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
    @Test func unwritableJournalLocationDoesNotModifyContact() throws {
        let w = workspace(); let p = try plan(w); let person = try #require(p.additions[0].before)
        let repo = MemoryContacts([person]); let path = root.appendingPathComponent("missing-dir/record.json").path
        #expect(throws: (any Error).self) { try MutationEngine.apply([p.additions[0]], plan: p, repository: repo, writer: "native", journalPath: path) }
        #expect(repo.records == [person])
    }
    @Test func lockContentionReturnsAnErrorWithoutWaiting() throws {
        let path = root.appendingPathComponent("test.lock").path
        let first = try RunLock(path: path); defer { withExtendedLifetime(first) {} }
        #expect(throws: (any Error).self) { try RunLock(path: path) }
    }
    @Test(arguments: ["name", "type", "container"]) func changedCompanyStopsUndoAndPreservesNumbers(_ change: String) throws {
        let w = workspace(); let p = try plan(w); let person = try #require(p.additions[0].before)
        let repo = MemoryContacts([person]); let path = root.appendingPathComponent("record.json").path
        _ = try MutationEngine.apply([p.additions[0]], plan: p, repository: repo, writer: "native", journalPath: path)
        switch change {
        case "name": repo.records[0].organization = "已改名"
        case "type": repo.records[0].isCompany = false
        default: repo.records[0].container = "other"
        }
        #expect(throws: (any Error).self) { try MutationEngine.undo(journalPath: path, repository: repo) }
        #expect(repo.records[0].phones.count == person.phones.count + 1)
    }
    @Test func recoveryHintsDoNotContainTerminalCommands() {
        let msg = DesktopError.message(Failure("系统错误 134092 prepared 条目"))
        #expect(msg.contains("操作记录")); #expect(!msg.contains("--writer"))
        #expect(DesktopError.message(Failure("脚本失败 -1743")).contains("自动化"))
        #expect(DesktopError.message(Failure("脚本超时 -1712")).contains("超时"))
        #expect(DesktopError.message(Failure("prepared 条目表示保存结果未确认")).contains("先查看"))
    }
    @Test func preferencesSurviveRestartAndCorruptionFallsBack() throws {
        let suite = "yellowpage-preferences-" + UUID().uuidString; let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var prefs = DesktopPreferences(); prefs.mode = "personal"; prefs.templatePath = "/example/archive"; prefs.accountID = "iCloud-account"
        prefs.save(to: defaults); #expect(DesktopPreferences.load(from: defaults) == prefs)
        defaults.set(Data("broken".utf8), forKey: "desktop.preferences.v1")
        #expect(DesktopPreferences.load(from: defaults).mode == "demo")
    }
    @Test func futureDateAndUnknownModeAreRepairedOnRestore() throws {
        let suite = "yellowpage-preferences-" + UUID().uuidString; let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var prefs = DesktopPreferences(); prefs.mode = "unknown"; prefs.since = Date.distantFuture; prefs.save(to: defaults)
        let restored = DesktopPreferences.load(from: defaults)
        #expect(restored.mode == "demo"); #expect(restored.since <= Date())
    }
}

@MainActor @Suite(.serialized) final class AppWorkflowTests {
    let defaults: UserDefaults
    let suite = "yellowpage-app-test-" + UUID().uuidString
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("yellowpage-app-test-" + UUID().uuidString)
    init() throws { defaults = try #require(UserDefaults(suiteName: suite)); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false) }
    deinit { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    func model() -> AppModel { AppModel(defaults: defaults, baseDirectory: root, restoreAccountsOnStart: false, readers: PreparationReaders(messages: { 0 }, authorization: { "未授权" })) }
    func finish(_ m: AppModel) async throws {
        let deadline = Date().addingTimeInterval(8)
        while m.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(!m.busy); #expect(!m.mutating)
    }
    @Test func firstLaunchScanAddUndoAndRescan() async throws {
        let m = model(); m.start(); try await finish(m)
        #expect(m.isDemo); #expect(m.canScan)
        m.scan(); try await finish(m); #expect(m.plan?.additions.count == 3); #expect(m.filter == "可添加")
        m.selected = ["10600000001"]; m.apply(); try await finish(m)
        #expect(m.page == .history); #expect(m.plan == nil); #expect(m.records.first?.added == 1)
        m.undo(try #require(m.records.first)); try await finish(m)
        m.scan(); try await finish(m); #expect(m.plan?.additions.count == 3)
    }
    @Test func noSelectionAndRepeatedClicksDoNotWriteTwice() async throws {
        let m = model(); m.start(); try await finish(m); m.scan(); try await finish(m)
        m.selected = []; m.apply(); #expect(!m.busy); #expect(m.records.isEmpty)
        m.selected = ["10600000001"]; m.apply(); m.apply(); m.changeMode(.personal); try await finish(m)
        #expect(m.isDemo); #expect(m.records.count == 1); #expect(m.records[0].added == 1)
    }
    @Test func failedAddUnlocksUIAndShowsRecords() async throws {
        let m = model(); m.start(); try await finish(m); m.scan(); try await finish(m)
        m.writer = "invalid"; m.apply(); try await finish(m)
        #expect(m.error != nil); #expect(m.page == .history); #expect(m.plan == nil); #expect(m.records.isEmpty)
        m.writer = "native"; m.scan(); try await finish(m); #expect(m.plan?.additions.count == 3)
    }
    @Test func restartRemembersSelectionButNeverRestoresAnApplyPlan() async throws {
        var prefs = DesktopPreferences(); prefs.mode = "personal"; prefs.templatePath = root.appendingPathComponent("moved.vcf").path; prefs.accountID = "old-account"; prefs.save(to: defaults)
        let m = model(); m.start(); try await finish(m)
        #expect(!m.isDemo); #expect(m.accountID == "old-account"); #expect(m.template != nil)
        #expect(!m.canScan); #expect(m.plan == nil); #expect(m.selected.isEmpty); #expect(m.templateStatus.contains("找不到"))
    }
    @Test func choosingWrongFileBlocksScanAndAllowsCorrection() async throws {
        let m = model(); m.start(); try await finish(m); m.changeMode(.personal); try await finish(m)
        let zip = root.appendingPathComponent("archive.zip"); try Data("zip".utf8).write(to: zip)
        m.selectTemplate(zip); try await finish(m); #expect(!m.canScan); #expect(m.error?.contains("解压") == true)
        let vcf = root.appendingPathComponent("bank.vcf")
        try Data("BEGIN:VCARD\r\nVERSION:3.0\r\nFN:银行\r\nORG:银行;\r\nEND:VCARD\r\n".utf8).write(to: vcf)
        m.selectTemplate(vcf); try await finish(m); #expect(m.error == nil); #expect(m.templateCount == 1)
        #expect(!m.canScan); #expect(m.preparationHint.contains("读取账户"))
    }
    @Test func staleAccountCannotEnableScanning() async throws {
        let m = model(); m.start(); try await finish(m); m.changeMode(.personal); try await finish(m)
        m.template = root.appendingPathComponent("bank.vcf"); m.templateCount = 1; m.accountID = "removed-account"; m.scan()
        #expect(!m.busy); #expect(m.plan == nil); #expect(m.notice.contains("读取账户"))
    }
    @Test func resetDemoRestoresInitialState() async throws {
        let m = model(); m.start(); try await finish(m); m.scan(); try await finish(m); m.apply(); try await finish(m)
        m.resetDemo(); try await finish(m); #expect(m.records.isEmpty); #expect(m.page == .prepare)
        m.scan(); try await finish(m); #expect(m.plan?.additions.count == 3)
    }
}

@Suite struct IconAppearanceTests {
    @Test(arguments: [NSAppearance.Name.aqua, .accessibilityHighContrastAqua]) func lightAppearanceSelectsLightAsset(_ name: NSAppearance.Name) throws {
        #expect(AppIconAppearance.assetName(for: try #require(NSAppearance(named: name))) == "AppIcon-light")
    }
    @Test(arguments: [NSAppearance.Name.darkAqua, .accessibilityHighContrastDarkAqua]) func darkAppearanceSelectsDarkAsset(_ name: NSAppearance.Name) throws {
        #expect(AppIconAppearance.assetName(for: try #require(NSAppearance(named: name))) == "AppIcon-dark")
    }
}
