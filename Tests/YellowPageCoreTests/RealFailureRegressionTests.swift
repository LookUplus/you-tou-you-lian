import Foundation
import AppKit
import Testing
@testable import YellowPageCore

@Suite(.serialized) final class RealFailureRegressionTests {
    let root:URL
    init() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("yellowpage-real-regression-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)}
    deinit {try? FileManager.default.removeItem(at:root)}
    func uncertain() throws -> (String,Person) {
        let person=Person(id:"brand",organization:"示例品牌",phones:[Phone(id:"blank",label:"",value:"4000000000")])
        let path=root.appendingPathComponent("record.json").path
        let journal=Journal(createdAt:Date(),writer:"contacts-app",planDigest:"fixture",entries:[JournalEntry(before:person,requested:["10600000001"],added:[],state:"prepared")],failure:"simulated failure")
        try JSONFile.write(journal,to:path);return (path,person)
    }
    @Test(arguments:[nil, ""]) func blankLabelsDoNotCompareAgainstLocalizedDisplayTitle(_ label:String?) throws {
        let person=Person(id:"id",organization:"企业",phones:[Phone(id:"blank",label:label,value:"4000000000"),Phone(id:"sms",label:"短信",value:"10600000001")])
        let script=ContactsScript.replacementScript(person,phones:person.phones+[Phone(id:"new:1",value:"10600000002")])
        #expect(script.contains("号码内容已变化"))
        #expect(script.contains("号码标识不一致"))
        #expect(script.components(separatedBy:"if label of item 1").count-1==1)
        #expect(script.contains("is not \"短信\""))
        let compiled=try #require(NSAppleScript(source:script));var error:NSDictionary?
        #expect(compiled.compileAndReturnError(&error))
    }
    @Test func scriptPermissionHintOnlyAppearsForPermissionError() {
        #expect(!ContactsScript.scriptErrorMessage(number:-2700,message:"号码标签已变化").contains("自动化"))
        #expect(ContactsScript.scriptErrorMessage(number:-1743,message:"Not authorized").contains("自动化"))
    }
    @Test(arguments:[26,27]) func automaticModeAvoidsKnownNativeFailure(_ major:Int) {
        #expect(ContactsGateway.resolvedWriter("automatic",systemMajor:major)=="contacts-app")
        #expect(ContactsGateway.resolvedWriter("native",systemMajor:major)=="native")
    }
    @Test func oldSystemsAndExplicitCompatibleModeRemainAvailable() {
        #expect(ContactsGateway.resolvedWriter("automatic",systemMajor:13)=="native")
        #expect(ContactsGateway.resolvedWriter("contacts-app",systemMajor:13)=="contacts-app")
    }
    @Test func unchangedFailedSaveBecomesConfirmedNotAdded() throws {
        let(path,person)=try uncertain()
        let result=try MutationEngine.reconcile(journalPath:path,people:[person])
        #expect(result.entries[0].state=="notApplied")
        #expect(result.failure != nil)
        let repo=MemoryContacts([person]);_ = try MutationEngine.undo(journalPath:path,repository:repo)
        #expect(repo.records==[person])
    }
    @Test func numberAddedLaterNeverAcquiresUndoOwnership() throws {
        let(path,person)=try uncertain();var changed=person
        changed.phones.append(Phone(id:"later-manual",label:"其他",value:"10600000001"))
        let result=try MutationEngine.reconcile(journalPath:path,people:[changed])
        #expect(result.entries[0].state=="verifiedPresent")
        #expect(result.entries[0].added.isEmpty)
        let repo=MemoryContacts([changed]);_ = try MutationEngine.undo(journalPath:path,repository:repo)
        #expect(repo.records==[changed])
    }
    @Test func editedContactRemainsUncertain() throws {
        let(path,person)=try uncertain();var changed=person;changed.phones[0].value="4000000001"
        #expect(try MutationEngine.reconcile(journalPath:path,people:[changed]).entries[0].state=="prepared")
    }
    @Test func movedContactRemainsUncertain() throws {
        let(path,person)=try uncertain();var changed=person;changed.container="other"
        #expect(try MutationEngine.reconcile(journalPath:path,people:[changed]).entries[0].state=="prepared")
    }
    @Test func partialPresenceRemainsUncertain() throws {
        let(path,person)=try uncertain();var journal=try JSONFile.read(Journal.self,from:path)
        journal.entries[0].requested.append("10600000002");try JSONFile.write(journal,to:path,overwrite:true)
        var changed=person;changed.phones.append(Phone(id:"later",value:"10600000001"))
        #expect(try MutationEngine.reconcile(journalPath:path,people:[changed]).entries[0].state=="prepared")
    }
    @Test func laterAddsAndRemovalsRefreshObservedStatusWithoutUndoOwnership() throws {
        let(path,person)=try uncertain()
        #expect(try MutationEngine.reconcile(journalPath:path,people:[person]).entries[0].state=="notApplied")
        var added=person;added.phones.append(Phone(id:"manual",value:"10600000001"))
        #expect(try MutationEngine.reconcile(journalPath:path,people:[added]).entries[0].state=="verifiedPresent")
        let removed=try MutationEngine.reconcile(journalPath:path,people:[person])
        #expect(removed.entries[0].state=="notApplied")
        #expect(removed.entries[0].added.isEmpty)
    }
    @Test func missingOrChangedCardInvalidatesPreviouslyObservedStatus() throws {
        let(path,person)=try uncertain()
        _ = try MutationEngine.reconcile(journalPath:path,people:[person])
        #expect(try MutationEngine.reconcile(journalPath:path,people:[]).entries[0].state=="prepared")
    }

}
