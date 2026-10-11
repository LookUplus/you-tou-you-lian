import Testing
import Foundation
@testable import YellowPageCore

@Suite(.serialized) final class DesktopWorkspaceTests {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("yellowpage-desktop-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func demoPlan(_ workspace: DesktopWorkspace) throws -> Plan {
        try workspace.scan(template: nil, container: "demo", since: Date(timeIntervalSince1970: 0))
    }
    @Test func demoSupportsSelectionAndUndoWithoutReadingPersonalData() throws {
        let workspace = DesktopWorkspace(mode: .demo, baseDirectory: directory)
        #expect(try workspace.accounts().map(\.id) == ["demo"])
        let plan = try demoPlan(workspace)
        #expect(plan.additions.count == 3)
        let journal = try workspace.apply(plan: plan, selected: ["10600000001"], writer: "native")
        #expect(journal.writer == "demo")
        #expect(journal.entries.count == 1)
        #expect(journal.entries[0].added.map(\.value) == ["10600000001"])
        let after = try demoPlan(workspace)
        #expect(after.additions.count == 2)
        #expect(after.decisions.first { $0.sender == "10600000001" }?.status == .alreadySaved)
        let path = try #require(workspace.lastJournalPath)
        _ = try workspace.undo(path: path)
        #expect(try demoPlan(workspace).additions.count == 3)
        #expect(try workspace.history().first?.undone == true)
    }
    @Test func skippedNumbersCannotBeSelectedForApply() throws {
        let workspace = DesktopWorkspace(mode: .demo, baseDirectory: directory)
        let plan = try demoPlan(workspace)
        #expect(throws: (any Error).self) { try workspace.apply(plan: plan, selected: ["10600000005"], writer: "native") }
        #expect(try workspace.history().isEmpty)
        #expect(throws: (any Error).self) { try workspace.apply(plan: plan, selected: [], writer: "native") }
    }
    @Test func realWorkspaceRejectsDemoBeforeContactOrMessageAccess() throws {
        let demo = DesktopWorkspace(mode: .demo, baseDirectory: directory)
        let real = DesktopWorkspace(mode: .personal, baseDirectory: directory)
        let plan = try demoPlan(demo)
        #expect(throws: (any Error).self) { try real.apply(plan: plan, selected: ["10600000001"], writer: "native") }
        #expect(throws: (any Error).self) { try real.resetDemo() }
        #expect(try real.history().isEmpty)
    }
    @Test func resetRestoresFixturesAndRejectsOldSessionRecords() throws {
        let workspace = DesktopWorkspace(mode: .demo, baseDirectory: directory)
        let plan = try demoPlan(workspace)
        _ = try workspace.apply(plan: plan, selected: Set(plan.additions.map(\.sender)), writer: "contacts-app")
        let oldPath = try #require(workspace.lastJournalPath)
        #expect(try demoPlan(workspace).additions.isEmpty)
        try workspace.resetDemo()
        #expect(try workspace.history().isEmpty)
        #expect(try demoPlan(workspace).additions.count == 3)
        #expect(throws: (any Error).self) { try workspace.undo(path: oldPath) }
        let saved = try JSONFile.read(Journal.self, from: oldPath)
        #expect(saved.writer == "demo")
    }
    @Test func demoRejectsForeignJournalsAndRealPlans() throws {
        let workspace = DesktopWorkspace(mode: .demo, baseDirectory: directory)
        var plan = try demoPlan(workspace)
        plan.configuration.database = MessagesDatabase.defaultPath
        #expect(throws: (any Error).self) { try workspace.apply(plan: plan, selected: ["10600000001"], writer: "native") }
        #expect(throws: (any Error).self) { try workspace.undo(path: directory.appendingPathComponent("foreign.json").path) }
        #expect(try workspace.history().isEmpty)
    }
    @Test func repeatingApplyDoesNotDuplicateDemoNumbers() throws {
        let workspace = DesktopWorkspace(mode: .demo, baseDirectory: directory)
        let plan = try demoPlan(workspace)
        _ = try workspace.apply(plan: plan, selected: ["10600000001"], writer: "native")
        #expect(throws: (any Error).self) { try workspace.apply(plan: plan, selected: ["10600000001"], writer: "native") }
        #expect(try workspace.history().count == 1)
        #expect(try demoPlan(workspace).additions.count == 2)
    }
}
