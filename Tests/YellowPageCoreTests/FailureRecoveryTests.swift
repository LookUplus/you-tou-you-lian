import Testing
import Foundation
@testable import YellowPageCore

private final class InterruptedContacts: ContactRepository {
    var peopleList: [Person]
    var writeCount = 0
    var failureAt = 2
    var failAfterWrite = false
    init(_ people: [Person]) { peopleList = people }
    func people() throws -> [Person] { peopleList }
    func replacePhones(of expected: Person, with phones: [Phone]) throws -> Person {
        writeCount += 1
        guard let index = peopleList.firstIndex(of: expected) else { throw Failure("名片已变化") }
        if writeCount == failureAt && !failAfterWrite { throw Failure("保存前中断") }
        peopleList[index].phones = phones.map { $0.id.hasPrefix("new:") ? Phone(id: UUID().uuidString, label: $0.label, value: $0.value) : $0 }
        if writeCount == failureAt && failAfterWrite { throw Failure("写入后中断") }
        return peopleList[index]
    }
}

@Suite(.serialized) final class FailureRecoveryTests {
    let root: URL
    let people = [Person(id: "a", organization: "示例银行", phones: [Phone(id: "original-a", label: "客服", value: "95599")]),
                  Person(id: "b", organization: "示例快递", phones: [Phone(id: "original-b", label: "客服", value: "95338")])]
    init() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent("yellowpage-recovery-" + UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false) }
    deinit { try? FileManager.default.removeItem(at: root) }
    func plan() throws -> Plan {
        try Planner.make(observations: [Observation(sender: "10600000001", date: Date(), signature: "示例银行"), Observation(sender: "10600000002", date: Date(), signature: "示例快递")], people: people, config: ScanConfiguration(database: "fixture", since: .distantPast, container: "default", catalogNames: people.map(\.organization)))
    }
    @Test(arguments: [false, true]) func partialSavePreservesConfirmedAndUncertainRecords(_ afterWrite: Bool) throws {
        let p = try plan(); let repo = InterruptedContacts(people); repo.failAfterWrite = afterWrite
        let path = root.appendingPathComponent("partial.json").path
        #expect(throws: (any Error).self) { try MutationEngine.apply(p.additions, plan: p, repository: repo, writer: "native", journalPath: path) }
        let journal = try JSONFile.read(Journal.self, from: path)
        #expect(journal.entries.map(\.state) == ["applied", "prepared"])
        #expect(journal.failure != nil)
        #expect(repo.peopleList[0].phones.count == 2)
        #expect(repo.peopleList[1].phones.count == (afterWrite ? 2 : 1))
        repo.failureAt = -1
        _ = try MutationEngine.undo(journalPath: path, repository: repo)
        #expect(repo.peopleList[0].phones == people[0].phones)
        #expect(repo.peopleList[1].phones.count == (afterWrite ? 2 : 1))
        #expect(try JSONFile.read(Journal.self, from: path).entries.map(\.state) == ["undone", "prepared"])
    }
    @Test func failedUndoCanResumeAfterAConfirmedRemoval() throws {
        let p = try plan(); let repo = InterruptedContacts(people); repo.failureAt = -1
        let path = root.appendingPathComponent("undo.json").path
        _ = try MutationEngine.apply(p.additions, plan: p, repository: repo, writer: "native", journalPath: path)
        repo.failureAt = 4
        #expect(throws: (any Error).self) { try MutationEngine.undo(journalPath: path, repository: repo) }
        #expect(try JSONFile.read(Journal.self, from: path).entries.map(\.state) == ["undone", "applied"])
        repo.failureAt = -1
        _ = try MutationEngine.undo(journalPath: path, repository: repo)
        #expect(repo.peopleList == people)
        #expect(try JSONFile.read(Journal.self, from: path).entries.allSatisfy { $0.state == "undone" })
    }
    @Test func editedSecondContactPreventsAnyUndoBeforeFirstRemoval() throws {
        let p = try plan(); let repo = InterruptedContacts(people); repo.failureAt = -1
        let path = root.appendingPathComponent("undo.json").path
        _ = try MutationEngine.apply(p.additions, plan: p, repository: repo, writer: "native", journalPath: path)
        repo.peopleList[1].phones[1].label = "用户编辑过"
        let before = repo.peopleList
        #expect(throws: (any Error).self) { try MutationEngine.undo(journalPath: path, repository: repo) }
        #expect(repo.peopleList == before)
    }
    @Test func corruptedFileAlongsideValidTemplatesDoesNotProducePartialCatalog() throws {
        let good = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:示例银行\r\nORG:示例银行;\r\nEND:VCARD\r\n"
        try Data(good.utf8).write(to: root.appendingPathComponent("good.vcf"))
        try Data("corrupt".utf8).write(to: root.appendingPathComponent("broken.vcf"))
        #expect(throws: (any Error).self) { try VCardCatalog.names(at: root.path) }
    }
    @Test func scanDateStillChecksOlderMissingSignatureAndSpam() throws {
        let now = Date(); let config = ScanConfiguration(database: "fixture", since: now.addingTimeInterval(-100), container: "default", catalogNames: ["示例银行"])
        let current = Observation(sender: "10600000001", date: now, signature: "示例银行")
        let unsigned = Observation(sender: current.sender, date: now.addingTimeInterval(-10000), signature: nil)
        #expect(try Planner.make(observations: [current, unsigned], people: people, config: config).decisions[0].status == .unsigned)
        let oldSpam = Observation(sender: current.sender, date: now.addingTimeInterval(-10000), signature: "示例银行", flagged: true)
        #expect(try Planner.make(observations: [current, oldSpam], people: people, config: config).decisions[0].status == .flagged)
    }
    @Test func alreadyAddedSelectedNumberDoesNotPreventOtherNewNumbers() throws {
        let p = try plan(); var saved = people
        saved[0].phones.append(Phone(id: "manually-added", value: "10600000001"))
        let fresh = try Planner.make(observations: [Observation(sender: "10600000001", date: Date(), signature: "示例银行"), Observation(sender: "10600000002", date: Date(), signature: "示例快递")], people: saved, config: p.configuration)
        #expect(try Planner.validateForApply(p, refreshed: fresh, people: saved).map(\.sender) == ["10600000002"])
    }
}
