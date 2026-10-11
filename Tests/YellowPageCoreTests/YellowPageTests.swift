import Testing
import Foundation
import AppKit
import CSQLite
@testable import YellowPageCore

final class MemoryContacts: ContactRepository {
    var records: [Person]
    var failBefore = false
    var failAfter = false
    init(_ records: [Person]) { self.records = records }
    func people() throws -> [Person] { records }
    func replacePhones(of expected: Person, with phones: [Phone]) throws -> Person {
        guard !failBefore else { throw Failure("simulated before-save failure") }
        guard let i = records.firstIndex(where: { $0 == expected }) else { throw Failure("stale") }
        records[i].phones = phones.map { phone in
            phone.id.hasPrefix("new:") ? Phone(id: UUID().uuidString, label: phone.label, value: phone.value) : phone
        }
        if failAfter { throw Failure("simulated uncertain save") }
        return records[i]
    }
}

@Suite(.serialized)
final class YellowPageTests {
    var temporaryDirectories = [URL]()
    deinit { for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) } }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let bank = Person(id: "bank", organization: "示例银行", phones: [Phone(id: "service", label: "客服", value: "95599")])
    var config: ScanConfiguration { ScanConfiguration(database: "fixture", since: now.addingTimeInterval(-86400), container: "default", catalogNames: ["示例银行", "示例出行"]) }
    func observation(_ signature: String? = "示例银行", sender: String = "10600000001", date: Date? = nil) -> Observation {
        Observation(sender: sender, date: date ?? now, signature: signature)
    }
    func plan(_ observations: [Observation], people: [Person]? = nil, configuration: ScanConfiguration? = nil) throws -> Plan {
        try Planner.make(observations: observations, people: people ?? [bank], config: configuration ?? config, now: now)
    }
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yellowpage-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        temporaryDirectories.append(url)
        return url
    }
    @Test func testSignatureIsAnchoredAndHandlesWhitespace() {
        expectEqual(TextRules.signature("\u{FEFF} \n【示例银行】正文"), "示例银行")
        expectEqual(TextRules.signature("[Example Bank] notification"), "Example Bank")
        for bad in ["正文【示例银行】", "【123456】验证码", "【】", "【A\nB】", "【https://example.com】", "【未结束", "【A[B】"] { expectNil(TextRules.signature(bad), bad) }
    }
    @Test func testPhoneScopeAndCountryPrefix() {
        expectTrue(TextRules.isSender("+86 10600000001"))
        expectEqual(TextRules.phone("0086 10600000001"), "10600000001")
        for value in ["13800138000", "95599", "alice@example.com", "106短信123", "+1 10600000001", "+1 0600000001", "106+00000001", "106"] { expectFalse(TextRules.isSender(value), value) }
    }
    @Test func testMatchingIsExactNotSubstring() throws {
        expectEqual(try plan([observation("示例银行信用卡")]).decisions[0].status, .outsideCatalog)
        expectEqual(try plan([observation("示 例 银 行")]).decisions[0].status, .add)
    }
    @Test func testAllHistoryProtectsAgainstSharedSender() throws {
        let result = try plan([observation(), observation("示例出行", date: now.addingTimeInterval(-86400 * 400))])
        expectEqual(result.decisions[0].status, .conflictingSignatures)
    }
    @Test func testOutsidePeriodDoesNotProposeAddition() throws {
        expectEqual(try plan([observation(date: now.addingTimeInterval(-86400 * 2))]).decisions[0].status, .outsidePeriod)
    }
    @Test func testMissingSignatureAndDecodeFailureBlockSender() throws {
        expectEqual(try plan([observation(), observation(nil)]).decisions[0].status, .unsigned)
        var failed = observation(); failed.decodingFailed = true
        expectEqual(try plan([observation(), failed]).decisions[0].status, .decodingFailed)
    }
    @Test func testFlaggedMessageBlocksSender() throws {
        var flagged = observation(); flagged.flagged = true
        expectEqual(try plan([observation(), flagged]).decisions[0].status, .flagged)
    }
    @Test func testDuplicateCompanyAndOtherAccountAreNotMerged() throws {
        var duplicate = bank; duplicate.id = "bank-2"
        expectEqual(try plan([observation()], people: [bank, duplicate]).decisions[0].status, .ambiguousContact)
        duplicate.container = "other"
        expectEqual(try plan([observation()], people: [duplicate]).decisions[0].status, .unknownSignature)
    }
    @Test func testIndividualAndCustomCompaniesAreExcluded() throws {
        var person = bank; person.isCompany = false
        expectEqual(try plan([observation()], people: [person]).decisions[0].status, .unknownSignature)
        let custom = Person(id: "custom", organization: "自定义名片")
        expectEqual(try plan([observation("自定义名片")], people: [custom]).decisions[0].status, .outsideCatalog)
    }
    @Test func testNumberOwnershipIncludesEveryAccount() throws {
        let other = Person(id: "other", container: "other-account", organization: "另一张名片", isCompany: false, phones: [Phone(id: "phone", value: "+86 10600000001")])
        expectEqual(try plan([observation()], people: [bank, other]).decisions[0].status, .assignedElsewhere)
    }
    @Test func testAlreadySavedAndDuplicateMessages() throws {
        var saved = bank; saved.phones.append(Phone(id: "sms", value: "10600000001"))
        expectEqual(try plan([observation(), observation()], people: [saved]).decisions[0].status, .alreadySaved)
        expectEqual(try plan([observation(), observation()]).additions.count, 1)
    }
    @Test func testNewConflictInvalidatesPlan() throws {
        let original = try plan([observation()])
        let fresh = try plan([observation(), observation("示例出行")])
        expectThrows(try Planner.validateForApply(original, refreshed: fresh, people: [bank]))
    }
    @Test func testPhoneEditInvalidatesPlan() throws {
        let original = try plan([observation()])
        var changed = bank; changed.phones.append(Phone(id: "manual", value: "4000000000"))
        expectThrows(try Planner.validateForApply(original, refreshed: plan([observation()], people: [changed]), people: [changed]))
    }
    @Test func testRepeatedApplyIsIdempotent() throws {
        let original = try plan([observation()])
        var saved = bank; saved.phones.append(Phone(id: "sms", value: "10600000001"))
        expectTrue(try Planner.validateForApply(original, refreshed: plan([observation()], people: [saved]), people: [saved]).isEmpty)
    }
    @Test func testApplyAndUndoPreserveOriginalAndLaterNumbers() throws {
        let original = try plan([observation(), observation(sender: "10600000002")])
        let repository = MemoryContacts([bank])
        let file = try directory().appendingPathComponent("journal.json").path
        let journal = try MutationEngine.apply(original.additions, plan: original, repository: repository, writer: "native", journalPath: file)
        expectEqual(journal.entries.count, 1)
        expectEqual(journal.entries[0].state, "applied")
        expectEqual(repository.records[0].phones.count, 3)
        let later = Phone(id: "later", label: "后来手动添加", value: "4000000000")
        repository.records[0].phones.append(later)
        _ = try MutationEngine.undo(journalPath: file, repository: repository)
        expectEqual(repository.records[0].phones, bank.phones + [later])
        _ = try MutationEngine.undo(journalPath: file, repository: repository)
        expectEqual(repository.records[0].phones, bank.phones + [later])
        let attributes = try FileManager.default.attributesOfItem(atPath: file)
        expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    @Test func testUncertainSaveIsJournaledAndNeverAutomaticallyDeleted() throws {
        let original = try plan([observation()])
        let repository = MemoryContacts([bank]); repository.failAfter = true
        let file = try directory().appendingPathComponent("journal.json").path
        expectThrows(try MutationEngine.apply(original.additions, plan: original, repository: repository, writer: "native", journalPath: file))
        let journal = try JSONFile.read(Journal.self, from: file)
        expectEqual(journal.entries[0].state, "prepared")
        expectNotNil(journal.failure)
        repository.failAfter = false
        _ = try MutationEngine.undo(journalPath: file, repository: repository)
        expectEqual(repository.records[0].phones.count, 2)
    }
    @Test func testEditedAddedNumberStopsUndo() throws {
        let original = try plan([observation()])
        let repository = MemoryContacts([bank])
        let file = try directory().appendingPathComponent("journal.json").path
        _ = try MutationEngine.apply(original.additions, plan: original, repository: repository, writer: "native", journalPath: file)
        repository.records[0].phones[1].label = "我修改的标签"
        expectThrows(try MutationEngine.undo(journalPath: file, repository: repository))
        expectEqual(repository.records[0].phones.count, 2)
    }
    @Test func testChangedFieldIdentifierStopsUndo() throws {
        let original = try plan([observation()])
        let repository = MemoryContacts([bank])
        let file = try directory().appendingPathComponent("journal.json").path
        _ = try MutationEngine.apply(original.additions, plan: original, repository: repository, writer: "native", journalPath: file)
        repository.records[0].phones[1].id = "replacement"
        expectThrows(try MutationEngine.undo(journalPath: file, repository: repository))
    }
    @Test func testStaleContactCannotBeWritten() throws {
        let original = try plan([observation()])
        var changed = bank; changed.organization = "已改名"
        let repository = MemoryContacts([changed])
        let file = try directory().appendingPathComponent("journal.json").path
        expectThrows(try MutationEngine.apply(original.additions, plan: original, repository: repository, writer: "native", journalPath: file))
        expectEqual(repository.records, [changed])
    }
    @Test func testPlanRoundTripOmitsMessageBody() throws {
        let p = try plan([observation()])
        let file = try directory().appendingPathComponent("plan.json").path
        try JSONFile.write(p, to: file)
        let loaded = try JSONFile.read(Plan.self, from: file)
        expectEqual(loaded.decisions, p.decisions)
        expectFalse(String(decoding: try Data(contentsOf: URL(fileURLWithPath: file)), as: UTF8.self).contains("验证码"))
        expectThrows(try JSONFile.write(p, to: file))
    }
    @Test func testPublicAppleScriptCompilesWithoutRunning() throws {
        var unusual = bank; unusual.organization = "示例\"银行\\分行"
        let script = try unwrap(NSAppleScript(source: ContactsScript.replacementScript(unusual, phones: unusual.phones + [Phone(id: "new:1", value: "10600000001")])))
        var error: NSDictionary?
        expectTrue(script.compileAndReturnError(&error), "\(String(describing: error))")
    }
    @Test func testVCardCatalogOnlyReadsOrganizationNames() throws {
        let url = try directory().appendingPathComponent("example.vcf")
        let vcf = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:示例银行\r\nORG:示例银行\r\nX-ABShowAs:COMPANY\r\nTEL;TYPE=WORK:95599\r\nEND:VCARD\r\n"
        try Data(vcf.utf8).write(to: url)
        expectEqual(try VCardCatalog.names(at: url.path), ["示例银行"])
        expectEqual(try VCardCatalog.names(at: url.deletingLastPathComponent().path), ["示例银行"])
    }
    @Test func testDatabaseReadsOnlyReceivedActiveSMSAndIsReadOnly() throws {
        let url = try directory().appendingPathComponent("chat.db")
        var db: OpaquePointer?; expectEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let sql = """
        CREATE TABLE handle(id TEXT); INSERT INTO handle VALUES('10600000001'); INSERT INTO handle VALUES('13800138000');
        CREATE TABLE message(text TEXT, attributedBody BLOB, handle_id INTEGER, date INTEGER, is_from_me INTEGER, service TEXT, is_spam INTEGER, filter_action INTEGER, associated_message_type INTEGER, item_type INTEGER);
        CREATE TABLE chat_message_join(message_id INTEGER);
        INSERT INTO message VALUES('【示例银行】验证码：机密',NULL,1,700000000000000000,0,'SMS',0,0,0,0);
        INSERT INTO message VALUES('【私人号码】',NULL,2,700000000,0,'SMS',0,0,0,0);
        INSERT INTO message VALUES('【已发送】',NULL,1,700000000,1,'SMS',0,0,0,0);
        INSERT INTO message VALUES('【已删除】',NULL,1,700000000,0,'SMS',0,0,0,0);
        INSERT INTO message VALUES('【iMessage】',NULL,1,700000000,0,'iMessage',0,0,0,0);
        INSERT INTO message VALUES('【回应】',NULL,1,700000000,0,'SMS',0,0,2000,0);
        INSERT INTO chat_message_join VALUES(1),(2),(3),(5),(6);
        """
        expectEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: url)
        let rows = try MessagesDatabase.read(url.path)
        expectEqual(rows.count, 1)
        expectEqual(rows[0].signature, "示例银行")
        expectEqual(rows[0].date, Date(timeIntervalSinceReferenceDate: 700000000))
        expectEqual(try Data(contentsOf: url), before)
    }
    @Test func testAttributedBodyAndCorruptArchive() throws {
        let url = try directory().appendingPathComponent("chat.db")
        var db: OpaquePointer?; expectEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        expectEqual(sqlite3_exec(db, "CREATE TABLE handle(id TEXT); INSERT INTO handle VALUES('10600000001'); CREATE TABLE message(text TEXT,attributedBody BLOB,handle_id INTEGER,date INTEGER,is_from_me INTEGER,service TEXT); CREATE TABLE chat_message_join(message_id INTEGER); INSERT INTO chat_message_join VALUES(1),(2),(3);", nil, nil, nil), SQLITE_OK)
        let bodies = [try NSKeyedArchiver.archivedData(withRootObject: NSAttributedString(string: "【示例银行】隐藏正文"), requiringSecureCoding: true), NSArchiver.archivedData(withRootObject: NSAttributedString(string: "【示例出行】旧格式")), Data("broken archive".utf8)]
        for body in bodies {
            var stmt: OpaquePointer?
            expectEqual(sqlite3_prepare_v2(db, "INSERT INTO message VALUES(NULL,?,1,700000000,0,'SMS')", -1, &stmt, nil), SQLITE_OK)
            _ = body.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(body.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            expectEqual(sqlite3_step(stmt), SQLITE_DONE); sqlite3_finalize(stmt)
        }
        let rows = try MessagesDatabase.read(url.path)
        expectEqual(rows.map { $0.signature }, ["示例银行", "示例出行", nil])
        expectTrue(rows[2].decodingFailed)
    }
    @Test func testUnsupportedDatabaseAndMissingFileDoNotCreateAnything() throws {
        let url = try directory().appendingPathComponent("missing.db")
        expectThrows(try MessagesDatabase.read(url.path))
        expectFalse(FileManager.default.fileExists(atPath: url.path))
        var db: OpaquePointer?; sqlite3_open(url.path, &db); sqlite3_close(db)
        expectThrows(try MessagesDatabase.read(url.path))
    }
}

// Helpers keep errors and assertion locations visible in test output.
private func expectEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: @autoclosure () throws -> T, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    do { #expect(try actual() == expected(), Comment(rawValue: message), sourceLocation: sourceLocation) }
    catch { Issue.record(error, sourceLocation: sourceLocation) }
}
private func expectTrue(_ value: @autoclosure () throws -> Bool, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    do { #expect(try value(), Comment(rawValue: message), sourceLocation: sourceLocation) }
    catch { Issue.record(error, sourceLocation: sourceLocation) }
}
private func expectFalse(_ value: @autoclosure () throws -> Bool, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    do { #expect(try !value(), Comment(rawValue: message), sourceLocation: sourceLocation) }
    catch { Issue.record(error, sourceLocation: sourceLocation) }
}
private func expectNil<T>(_ value: @autoclosure () throws -> T?, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    do { #expect(try value() == nil, Comment(rawValue: message), sourceLocation: sourceLocation) }
    catch { Issue.record(error, sourceLocation: sourceLocation) }
}
private func expectNotNil<T>(_ value: @autoclosure () throws -> T?, sourceLocation: SourceLocation = #_sourceLocation) {
    do { #expect(try value() != nil, sourceLocation: sourceLocation) }
    catch { Issue.record(error, sourceLocation: sourceLocation) }
}
private func expectThrows<T>(_ value: @autoclosure () throws -> T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(throws: (any Error).self, sourceLocation: sourceLocation) { _ = try value() }
}
private func unwrap<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
    try #require(value, sourceLocation: sourceLocation)
}
