import SwiftUI
import AppKit
import YellowPageCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var model: AppModel?
    private var iconObservation: NSKeyValueObservation?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.mutating == true else { return .terminateNow }
        model?.notice = "正在保存或撤销号码，请等操作结束后再退出。"
        return .terminateCancel
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model?.mutating == true else { return true }
        model?.notice = "正在保存或撤销号码，请等操作结束后再关闭。"
        return false
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        iconObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { application, _ in
            let appearance = application.effectiveAppearance
            DispatchQueue.main.async { NSApp.applicationIconImage = AppIconAppearance.image(for: appearance) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct YellowPageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("有头有脸", id: "main") {
            MainView(model: model).frame(minWidth: 860, minHeight: 620)
                .onAppear { delegate.model = model; DispatchQueue.main.async { NSApp.windows.filter { $0.title == "有头有脸" }.forEach { $0.delegate = delegate } } }
                .environment(\.locale, Locale(identifier: "zh_CN"))
        }.defaultSize(width: 1120, height: 780)
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    Image(nsImage: AppIconAppearance.image(for: NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)!) ?? NSImage(size: NSSize(width: 36, height: 36))).resizable().frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("有头有脸").font(.title3.bold())
                        Text("中国黄页 · Mac 工具").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 16).padding(.top, 20)
                List(Page.allCases, selection: $model.page) { page in Label(page.rawValue, systemImage: page.symbol).tag(page) }
                    .listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 7) {
                    Label("在本机处理", systemImage: "lock.shield")
                    Text("短信与通讯录不上传\n0.3.4 图形试用版").font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }.navigationSplitViewColumnWidth(220)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Picker("数据来源", selection: Binding(get: { model.mode }, set: { model.changeMode($0) })) {
                        Text("演示数据").tag(WorkspaceMode.demo)
                        Text("自己的数据").tag(WorkspaceMode.personal)
                    }.pickerStyle(.segmented).frame(width: 255).disabled(model.busy || model.choosingTemplate)
                    Spacer()
                    if model.isDemo {
                        Button { model.confirmReset = true } label: { Label("重置演示", systemImage: "arrow.counterclockwise") }.disabled(model.busy || model.choosingTemplate)
                    }
                }.padding(22)
                if model.isDemo {
                    Label("演示模式 · 使用虚构号码和名片，不读取或修改真实短信、通讯录。", systemImage: "play.rectangle")
                        .font(.callout).foregroundStyle(.orange).padding(.horizontal, 22).padding(.bottom, 16)
                }
                Divider()
                Group {
                    switch model.page ?? .prepare {
                    case .prepare: prepare
                    case .review: review
                    case .history: history
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                HStack(spacing: 12) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.busy ? model.activity : model.notice).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    Spacer(minLength: 0)
                }.padding(18).frame(minHeight: 66)
            }
        }
        .tint(Color(red: 239/255, green: 131/255, blue: 84/255))
        .task { model.start() }
        .alert("确认添加号码", isPresented: $model.confirmAdd) {
            Button("取消", role: .cancel) {}
            Button(model.isDemo ? "模拟添加" : "添加到通讯录") { model.apply() }
        } message: {
            Text(model.isDemo
                 ? "将在虚构的演示名片中添加 \(model.selected.count) 个号码。真实通讯录不会改变。"
                 : "将向「\(model.targetName)」的已有名片添加 \(model.selected.count) 个号码。请确认已核对预览；原有名称、头像与号码保留，并生成撤销记录。")
        }
        .alert("撤销这次添加？", isPresented: Binding(get: { model.undoRecord != nil }, set: { if !$0 { model.undoRecord = nil } })) {
            Button("取消", role: .cancel) { model.undoRecord = nil }
            Button("撤销新增号码", role: .destructive) { if let record = model.undoRecord { model.undo(record) }; model.undoRecord = nil }
        } message: { Text("只移除这次新增且之后没有修改过的号码。保存结果不确定的条目需要人工核对。") }
        .alert("重置演示数据？", isPresented: $model.confirmReset) {
            Button("取消", role: .cancel) {}
            Button("重置演示") { model.resetDemo() }
        } message: { Text("虚构名片将回到初始状态，方便重新录制。自己的数据不受影响。") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshContactAuthorization() }
        .alert("本次操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("复制详情") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.errorDetails, forType: .string) }
            Button("知道了", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 27, weight: .bold))
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.bottom, 8)
    }

    var prepare: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heading("让短信号码，有头有脸。", "选择黄页与账户，先找出可以补充的号码。")
                if !model.isDemo {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("1  允许读取本机短信", systemImage: "message").font(.headline)
                            Text(model.messageAccess).font(.callout).foregroundStyle(model.messageState.isAvailable ? Color.green : Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("在系统设置中添加当前这份「有头有脸」App，打开完全磁盘访问开关，再退出并重新打开工具。这里会实际读取短信检查权限；系统开关已打开，不代表当前 App 一定能读取。").font(.callout).foregroundStyle(.secondary)
                            HStack {
                                Button("打开完全磁盘访问权限") { model.settings("Privacy_AllFiles") }
                                Button("检查短信访问") { model.checkMessages() }
                            }
                            DisclosureGroup("换了新版，开关已打开却仍然无法读取？") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("重新进入系统设置的完全磁盘访问页面，让列表刷新。如果仍无法读取，请移除对应的旧条目，再添加当前这份 App 并打开开关，退出并重开工具。只调整「有头有脸」的条目。")
                                    Button("在 Finder 中显示当前 App") { model.revealCurrentApp() }
                                    Text("短信还需同步到这台 Mac；第一次同步可能需要等待。").foregroundStyle(.secondary)
                                }.font(.callout).padding(.top, 8)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Label(model.isDemo ? "1  选择保存账户" : "2  授权联系人并选择账户", systemImage: "person.crop.circle").font(.headline)
                        if !model.isDemo {
                            Text(model.contactAccess).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("授权并读取账户") { model.loadAccounts() }
                                Button("打开联系人权限设置") { model.settings("Privacy_Contacts") }
                            }
                            Text("左边的按钮会发起系统授权，请允许完整访问联系人。设置入口只打开权限页面；以前拒绝或仅允许部分联系人时，用它调整后再读取账户。").font(.callout).foregroundStyle(.secondary)
                        }
                        Picker("账户", selection: $model.accountID) {
                            if model.accounts.isEmpty { Text("请先授权并读取账户").tag(model.accountID) }
                            ForEach(model.accounts) { Text($0.name + ($0.isDefault ? "（默认）" : "")).tag($0.id) }
                        }.onChange(of: model.accountID) { _ in model.invalidate() }
                        if !model.isDemo { Text("选择前面导入黄页的账户。需要同步到其他设备时，选用已开启同步的 iCloud 账户。").font(.callout).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Label(model.isDemo ? "2  选择黄页资料" : "3  选择黄页资料", systemImage: "folder.badge.person.crop").font(.headline)
                        if model.isDemo {
                            Text("已准备好示例银行、示例快递和示例出行等虚构资料。").foregroundStyle(.secondary)
                        } else {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.template?.lastPathComponent ?? "尚未选择 vCards 文件")
                                    Text(model.template == nil ? "支持 .vcf 文件和 archive 解压文件夹" : model.templateStatus).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("选择文件或文件夹…") { model.chooseTemplate() }
                            }
                            Text("请先把需要的企业名片导入「联系人」App。这里选择的文件仅用于核对公司名称。").font(.callout).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
                HStack {
                    Toggle("只整理指定日期以来出现的号码", isOn: $model.limitDate).toggleStyle(.checkbox).onChange(of: model.limitDate) { _ in model.invalidate() }
                    if model.limitDate { DatePicker("开始日期", selection: $model.since, in: ...Date(), displayedComponents: .date).labelsHidden().onChange(of: model.since) { _ in model.invalidate() } }
                }
                HStack {
                    Text(model.preparationHint)
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.isDemo ? "扫描演示数据" : "扫描短信") { model.scan() }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canScan)
                }
            }.padding(26).disabled(model.busy || model.choosingTemplate)
        }
    }

    var review: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("先看清号码，加给谁。", "核对企业名称和发件号码，再选择要添加的项目。")
            if let plan = model.plan {
                HStack(spacing: 14) {
                    metric("可添加", plan.additions.count, .orange)
                    metric("已保存", plan.decisions.filter { $0.status == .alreadySaved }.count, .green)
                    metric("已跳过", plan.decisions.filter { $0.status != .add && $0.status != .alreadySaved }.count, .secondary)
                }
                HStack {
                    Picker("显示", selection: $model.filter) { ForEach(["全部", "可添加", "已保存", "已跳过"], id: \.self) { Text($0) } }.pickerStyle(.segmented).frame(maxWidth: 370)
                    Spacer()
                    Button("全选可添加") { model.selected = Set(plan.additions.map(\.sender)) }
                    Button("清空选择") { model.selected = [] }
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.rows, id: \.sender) { row in
                            HStack(alignment: .center, spacing: 14) {
                                Toggle("选择 \(row.sender)", isOn: Binding(get: { model.selected.contains(row.sender) }, set: { value in
                                    if value { model.selected.insert(row.sender) } else { model.selected.remove(row.sender) }
                                })).labelsHidden().toggleStyle(.checkbox).disabled(row.status != .add)
                                Image(systemName: row.status == .add ? "person.crop.square" : "info.circle")
                                    .font(.title2).foregroundStyle(row.status == .add ? Color.orange : Color.secondary).frame(width: 32)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.contactName ?? (row.signatures.isEmpty ? "没有品牌签名" : row.signatures.joined(separator: " / "))).font(.headline)
                                    Text(row.sender).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                    Text(row.reason).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(row.status == .add ? "可添加" : row.status == .alreadySaved ? "已保存" : "已跳过")
                                    .font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
                                    .background((row.status == .add ? Color.orange : Color.secondary).opacity(0.1), in: Capsule())
                            }.padding(14)
                            Divider()
                        }
                    }
                }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                if model.rows.isEmpty { Text("此分类没有号码。").foregroundStyle(.secondary) }
                HStack {
                    if !model.isDemo {
                        Picker("保存方式", selection: $model.writer) {
                            Text("自动方式（推荐）").tag("automatic")
                            Text("标准方式").tag("native")
                            Text("通过「联系人」App（兼容）").tag("contacts-app")
                        }.frame(maxWidth: 330)
                    }
                    Spacer()
                    Button(model.isDemo ? "模拟添加 \(model.selected.count) 个号码" : "添加 \(model.selected.count) 个号码…") { model.confirmAdd = true }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.selected.isEmpty)
                }
                Text("仅匹配 106 号码与同名企业。品牌签名是匹配线索，保存名称不代表短信或链接可信。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                empty("还没有待核对的结果", "先扫描短信，或在添加后重新扫描查看结果。", "checklist")
                Button("返回准备资料") { model.page = .prepare }.buttonStyle(.borderedProminent)
            }
        }.padding(26).disabled(model.busy || model.choosingTemplate)
    }
    func metric(_ title: String, _ count: Int, _ color: Color) -> some View {
        HStack { Text("\(count)").font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(color); Text(title).foregroundStyle(.secondary); Spacer() }
            .padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
    func empty(_ title: String, _ subtitle: String, _ symbol: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 42)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    var history: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("每次添加，都有记录。", model.isDemo ? "这里显示本次演示会话的模拟操作，可以撤销后重新演示。" : "查看添加结果，或撤销某一次仍可核实的新增号码。")
            HStack {
                Button("刷新记录") { model.loadHistory() }
                Button("打开记录文件夹") { model.revealRecords() }.disabled(model.records.isEmpty && model.historyWarning.isEmpty)
                Spacer()
                Button("再次扫描") { model.page = .prepare }
            }
            if !model.historyWarning.isEmpty { Label(model.historyWarning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary) }
            if model.records.isEmpty { empty("还没有操作记录", "添加号码后，结果和撤销入口会出现在这里。", "clock.arrow.circlepath") }
            else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.records) { record in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(record.date.formatted(date: .abbreviated, time: .standard)).font(.headline)
                                    Spacer()
                                    Text(record.undone ? "已撤销" : record.added > 0 ? "\(record.added) 个号码已添加" : record.pending > 0 ? "保存待核对" : record.present > 0 ? "号码现已保存" : "未添加号码")
                                        .foregroundStyle(record.added > 0 ? Color.green : record.pending > 0 ? Color.orange : Color.secondary)
                                }
                                Text(record.names.isEmpty ? "没有完成名片保存" : record.names.joined(separator: "、")).foregroundStyle(.secondary)
                                if record.notApplied > 0 { Text("已核对：请求的号码目前不在这张名片中，可以重新扫描后继续。").font(.callout).foregroundStyle(.secondary) }
                                if record.present > 0 { Text("请求的号码目前已在名片中，无需再添加；这份旧记录不提供自动撤销。").font(.callout).foregroundStyle(.secondary) }
                                if record.pending > 0 { Label("\(record.pending) 张名片保存结果不确定，请核对后再继续。", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                                HStack {
                                    Button("查看记录文件") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.path)]) }
                                    Spacer()
                                    Button("撤销这次添加…") { model.undoRecord = record }.disabled(record.undone || record.added == 0)
                                }
                            }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
        }.padding(26).disabled(model.busy || model.choosingTemplate)
    }
}
