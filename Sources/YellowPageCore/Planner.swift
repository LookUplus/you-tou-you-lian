import Foundation

public enum Planner {
    public static func make(observations:[Observation], people:[Person], config:ScanConfiguration, now:Date=Date()) throws -> Plan {
        let targets=people.filter{$0.container==config.container && $0.isCompany && !$0.organization.isEmpty}
        let byName=Dictionary(grouping:targets,by:{TextRules.name($0.organization)})
        let catalog=config.catalogNames.map{Set($0.map(TextRules.name))}
        var owners=[String:Set<String>]()
        for p in people { for n in p.phones {owners[TextRules.phone(n.value),default:[]].insert(p.id)} }
        let groups=Dictionary(grouping:observations.filter{TextRules.isSender($0.sender)},by:{TextRules.phone($0.sender)})
        var decisions=[Decision]()
        for sender in groups.keys.sorted() {
            let rows=groups[sender]!,signatures=Set(rows.compactMap{$0.signature}).sorted()
            var d=Decision(sender:sender,signatures:signatures,messageCount:rows.count,lastDate:rows.map{$0.date}.max()!,status:.add,reason:"")
            if !rows.contains(where:{$0.date>=config.since && $0.date<=now.addingTimeInterval(86400)}) { d.status = .outsidePeriod;d.reason="时间范围内没有收到此号码的短信" }
            else if rows.contains(where:{$0.decodingFailed}) {d.status = .decodingFailed;d.reason="存在无法读取正文的短信，无法排除共用号码"}
            else if rows.contains(where:{$0.signature == nil}) {d.status = .unsigned;d.reason="存在未以有效【签名】开头的短信"}
            else if rows.contains(where:{$0.flagged}) {d.status = .flagged;d.reason="本机曾将此号码的短信标记为垃圾信息，需人工核对"}
            else {
                let names=Set(signatures.map(TextRules.name))
                if names.count != 1 {d.status = .conflictingSignatures;d.reason="同一号码对应多个品牌，跳过"}
                else if let n=names.first {
                    if let catalog,!catalog.contains(n) {d.status = .outsideCatalog;d.reason="未命中指定 vCards 模板"}
                    else {
                        let matches=byName[n] ?? []
                        if matches.isEmpty {d.status = .unknownSignature;d.reason="目标账户中没有同名公司联系人；请先导入对应的 vCards 名片"}
                        else if matches.count != 1 {d.status = .ambiguousContact;d.reason="目标账户存在多张同名公司名片，先合并或调整名称"}
                        else {
                            let p=matches[0];d.contactID=p.id;d.contactName=p.organization
                            let assigned=owners[sender] ?? []
                            if !assigned.subtracting([p.id]).isEmpty {d.status = .assignedElsewhere;d.reason="号码已在其他名片或账户中，跳过"}
                            else if assigned.contains(p.id) {d.status = .alreadySaved;d.reason="已经保存，不重复添加"}
                            else {d.before=p;d.reason="签名完全匹配"}
                        }
                    }
                }
            }
            decisions.append(d)
        }
        return Plan(createdAt:now,configuration:config,decisions:decisions,scannedMessages:observations.count)
    }
    public static func validateForApply(_ plan:Plan, refreshed:Plan, people:[Person]) throws -> [Decision] {
        guard plan.version==1 else {throw Failure("不支持的计划版本，请重新 scan。")}
        guard Set(plan.additions.map{$0.sender}).count==plan.additions.count else {throw Failure("计划中有重复号码。")}
        var result=[Decision]()
        for item in plan.additions {
            guard TextRules.isSender(item.sender),item.sender==TextRules.phone(item.sender),let id=item.contactID,
                  let old=item.before,old.id==id,old.container==plan.configuration.container,
                  let current=people.first(where:{$0.id==id}),current.organization==item.contactName,current.isCompany,
                  current.container==old.container else {throw Failure("联系人或计划已变化，请重新 scan：\(item.sender)")}
            guard let fresh=refreshed.decisions.first(where:{$0.sender==item.sender}),fresh.contactID==id else {throw Failure("号码归属已变化，请重新 scan：\(item.sender)")}
            if fresh.status == .alreadySaved {continue}
            guard fresh.status == .add,Set(current.phones)==Set(old.phones) else {throw Failure("短信或联系人已变化，请重新 scan：\(item.sender)（\(fresh.reason)）")}
            result.append(fresh)
        }
        return result
    }
}
