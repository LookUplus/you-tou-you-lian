import Foundation
import Testing
@testable import YellowPageCore

@Suite final class EmptyLabelNormalizationTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("yellowpage-label-normalization-" + UUID().uuidString)
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false) }
    deinit { try? FileManager.default.removeItem(at: root) }
    var person: Person { Person(id: "brand", organization: "示例航空", phones: [Phone(id: "old", label: nil, value: "4000000000")]) }
    var journalPath: String { root.appendingPathComponent("record.json").path }
    func plan() throws -> Plan {
        try Planner.make(observations: [Observation(sender: "10600000001", date: Date(), signature: "示例航空")], people: [person],
                         config: ScanConfiguration(database: "fixture", since: .distantPast, container: "default", catalogNames: ["示例航空"]))
    }
    @Test func saveAndUndoSucceedWhenSystemNormalizesOriginalEmptyLabel() throws {
        let plan = try plan(); let repo = NormalizingContacts([person])
        let applied = try MutationEngine.apply(plan.additions, plan: plan, repository: repo, writer: "contacts-app", journalPath: journalPath)
        #expect(applied.entries[0].state == "applied")
        #expect(applied.entries[0].before.phones[0].label == nil)
        #expect(repo.records[0].phones[0].label == "")
        let undone = try MutationEngine.undo(journalPath: journalPath, repository: repo)
        #expect(undone.entries[0].state == "undone")
        #expect(repo.records == [person])
        #expect(repo.records[0].phones[0].id == "old")
    }
    @Test func actualExistingLabelEditStillStopsPostSaveVerification() throws {
        let plan = try plan(); let repo = NormalizingContacts([person]); repo.replacementLabel = "后来编辑"
        #expect(throws: Failure.self) {
            try MutationEngine.apply(plan.additions, plan: plan, repository: repo, writer: "contacts-app", journalPath: journalPath)
        }
        #expect(try JSONFile.read(Journal.self, from: journalPath).entries[0].state == "prepared")
    }
    @Test func oldFalseFailureBecomesPresentWithoutAcquiringUndoRights() throws {
        let entry = JournalEntry(before: person, requested: ["10600000001"], added: [], state: "prepared")
        try JSONFile.write(Journal(createdAt: Date(), writer: "contacts-app", planDigest: "fixture", entries: [entry]), to: journalPath)
        var current = person; current.phones[0].label = ""
        current.phones.append(Phone(id: "saved", value: "10600000001"))
        let result = try MutationEngine.reconcile(journalPath: journalPath, people: [current])
        #expect(result.entries[0].state == "verifiedPresent")
        #expect(result.entries[0].added.isEmpty)
        let repo = MemoryContacts([current]); _ = try MutationEngine.undo(journalPath: journalPath, repository: repo)
        #expect(repo.records == [current])
    }
    @Test func hashEqualityOnlyTreatsNilAndEmptyLabelsAsEquivalent() {
        let nilLabel = Phone(id: "same", label: nil, value: "95555")
        let emptyLabel = Phone(id: "same", label: "", value: "95555")
        #expect(Set([nilLabel, emptyLabel]).count == 1)
        for different in [Phone(id: "other", label: nil, value: "95555"), Phone(id: "same", label: nil, value: "95556"),
                          Phone(id: "same", label: "电话", value: "95555"), Phone(id: "same", label: " ", value: "95555")] {
            #expect(nilLabel != different)
        }
    }
    @Test func codingRetainsBothOriginalRawRepresentations() throws {
        let nilLabel = Phone(id: "nil", label: nil, value: "95555")
        let emptyLabel = Phone(id: "empty", label: "", value: "95555")
        let decoded = try JSONDecoder().decode([Phone].self, from: JSONEncoder().encode([nilLabel, emptyLabel]))
        #expect(decoded[0].label == nil); #expect(decoded[1].label == "")
    }
}

private final class NormalizingContacts: ContactRepository {
    var records: [Person]
    var replacementLabel = ""
    init(_ records: [Person]) { self.records = records }
    func people() throws -> [Person] { records }
    func replacePhones(of expected: Person, with phones: [Phone]) throws -> Person {
        guard let index = records.firstIndex(of: expected) else { throw Failure("stale") }
        records[index].phones = phones.map {
            if $0.id.hasPrefix("new:") { return Phone(id: UUID().uuidString, label: $0.label, value: $0.value) }
            var field = $0; if field.label == nil { field.label = replacementLabel }; return field
        }
        return records[index]
    }
}
