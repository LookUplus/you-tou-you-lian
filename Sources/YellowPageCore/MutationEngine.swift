import Foundation
import Darwin

public struct JournalEntry: Codable {
    public var before: Person
    public var requested: [String]
    public var added: [Phone]
    public var state: String
}
public struct Journal: Codable {
    public var version = 1
    public var createdAt: Date
    public var writer: String
    public var planDigest: String
    public var entries: [JournalEntry]
    public var failure: String?
}

public enum MutationEngine {
    @discardableResult public static func apply(_ decisions: [Decision], plan: Plan, repository: ContactRepository,
                                               writer: String, journalPath: String) throws -> Journal {
        guard plan.version == 1, !decisions.isEmpty,
              Set(decisions.map(\.sender)).count == decisions.count,
              decisions.allSatisfy({ row in
                  row.status == .add && TextRules.isSender(row.sender) && row.sender == TextRules.phone(row.sender)
                  && row.contactID != nil && row.before?.id == row.contactID
                  && row.before?.container == plan.configuration.container
                  && row.before?.organization == row.contactName && row.before?.isCompany == true
              }) else { throw Failure("添加清单无效，请重新扫描；未修改任何联系人。") }
        var journal = Journal(createdAt: Date(), writer: writer, planDigest: try JSONFile.digest(plan), entries: [])
        try JSONFile.write(journal, to: journalPath)
        let groups = Dictionary(grouping: decisions, by: { $0.contactID! })
        for id in groups.keys.sorted() {
            let rows = groups[id]!
            guard let before = rows.first?.before, rows.allSatisfy({ $0.before == before }),
                  let current = try repository.people().first(where: { $0.id == id }), current == before else {
                throw Failure("写入前名片已变化；已完成的操作记录在 \(journalPath)。")
            }
            // Check other cards again to catch changes between the scan and this write.
            let otherNumbers = Set(try repository.people().filter { $0.id != id }.flatMap { $0.phones }.map { TextRules.phone($0.value) })
            guard rows.allSatisfy({ !otherNumbers.contains($0.sender) }) else { throw Failure("号码已被保存到其他名片，停止写入。操作记录：\(journalPath)") }
            let additions = rows.map { Phone(id: "new:" + UUID().uuidString, value: $0.sender) }
            journal.entries.append(JournalEntry(before: before, requested: rows.map { $0.sender }, added: [], state: "prepared"))
            try JSONFile.write(journal, to: journalPath, overwrite: true)
            let index = journal.entries.count - 1
            do {
                let after = try repository.replacePhones(of: before, with: before.phones + additions)
                let added = after.phones.filter { phone in !before.phones.contains(where: { $0.id == phone.id }) }
                guard after.id == before.id, after.organization == before.organization, after.container == before.container,
                      after.isCompany == before.isCompany, Set(before.phones).isSubset(of: Set(after.phones)),
                      added.count == additions.count, Set(added.map { $0.value }) == Set(rows.map { $0.sender }),
                      added.allSatisfy({ $0.label == "短信" }) else { throw Failure("保存后的号码与计划不一致，已停止；请人工检查这张名片。") }
                journal.entries[index].added = added
                journal.entries[index].state = "applied"
                try JSONFile.write(journal, to: journalPath, overwrite: true)
            } catch {
                journal.failure = String(describing: error)
                // A write may have reached the system before throwing. Never automatically retry or delete an uncertain entry.
                try? JSONFile.write(journal, to: journalPath, overwrite: true)
                throw Failure("\(error)\n操作记录：\(journalPath)。prepared 条目表示保存结果未确认，需要人工核对；不要重复执行旧计划。")
            }
        }
        return journal
    }

    /// Resolve only observable facts. A number found later is never attributed to this
    /// uncertain write, so it cannot acquire automatic undo permission retroactively.
    @discardableResult public static func reconcile(journalPath: String, people: [Person]) throws -> Journal {
        var journal = try JSONFile.read(Journal.self, from: journalPath)
        guard journal.version == 1 else { throw Failure("不支持此操作记录版本。") }
        var changed = false
        for index in journal.entries.indices where ["prepared", "notApplied", "verifiedPresent"].contains(journal.entries[index].state) {
            let entry = journal.entries[index]
            guard !entry.requested.isEmpty, entry.added.isEmpty else { continue }
            var state = "prepared"
            if let current = people.first(where: { $0.id == entry.before.id }),
               current.container == entry.before.container, current.organization == entry.before.organization,
               current.isCompany == entry.before.isCompany {
                let values = Set(current.phones.map { TextRules.phone($0.value) })
                if current == entry.before && entry.requested.allSatisfy({ !values.contains(TextRules.phone($0)) }) {
                    state = "notApplied"
                } else if Set(entry.before.phones).isSubset(of: Set(current.phones)) && entry.requested.allSatisfy({ values.contains(TextRules.phone($0)) }) {
                    state = "verifiedPresent"
                }
            }
            if state != entry.state { journal.entries[index].state = state; changed = true }
        }
        if changed { try JSONFile.write(journal, to: journalPath, overwrite: true) }
        return journal
    }

    @discardableResult public static func undo(journalPath: String, repository: ContactRepository) throws -> Journal {
        var journal = try JSONFile.read(Journal.self, from: journalPath)
        guard journal.version == 1 else { throw Failure("不支持此操作记录版本。") }
        let current = try repository.people()
        // Preflight all entries before the first removal.
        for entry in journal.entries where entry.state == "applied" {
            _ = try undoTarget(entry, people: current)
        }
        for index in journal.entries.indices where journal.entries[index].state == "applied" {
            let entry = journal.entries[index]
            let (person, remaining) = try undoTarget(entry, people: repository.people())
            if person.phones != remaining {
                let after = try repository.replacePhones(of: person, with: remaining)
                guard Set(after.phones) == Set(remaining) else { throw Failure("撤销后的号码未通过核对，已停止。") }
            }
            journal.entries[index].state = "undone"
            try JSONFile.write(journal, to: journalPath, overwrite: true)
        }
        return journal
    }
    private static func undoTarget(_ entry: JournalEntry, people: [Person]) throws -> (Person, [Phone]) {
        guard let person = people.first(where: { $0.id == entry.before.id }), person.container == entry.before.container,
              person.organization == entry.before.organization, person.isCompany == entry.before.isCompany else { throw Failure("名片已删除、移动或改名，撤销已停止：\(entry.before.organization)") }
        guard !entry.added.isEmpty, Set(entry.added.map { $0.value }) == Set(entry.requested),
              entry.added.allSatisfy({ added in !entry.before.phones.contains(where: { $0.id == added.id || TextRules.phone($0.value) == TextRules.phone(added.value) }) }) else { throw Failure("操作记录不完整，无法自动撤销。") }
        for added in entry.added {
            if let field = person.phones.first(where: { $0.id == added.id }) {
                guard field == added else { throw Failure("新增号码后来被编辑，保留该号码并停止撤销：\(person.organization)") }
            } else if person.phones.contains(where: { TextRules.phone($0.value) == TextRules.phone(added.value) }) {
                throw Failure("号码仍存在，但字段标识变化，无法确认归属：\(person.organization)。请人工处理。")
            }
        }
        let ids = Set(entry.added.map { $0.id })
        return (person, person.phones.filter { !ids.contains($0.id) })
    }
}

/// Serializes this tool's writes. Other apps can still edit Contacts concurrently.
public final class RunLock {
    private let descriptor: Int32
    public init(path: String? = nil) throws {
        let path = path ?? (NSTemporaryDirectory() + "yellowpage-\(getuid()).lock")
        descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Failure("无法创建运行锁。") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); throw Failure("另一个 yellowpage 正在写入，请等它完成。")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
