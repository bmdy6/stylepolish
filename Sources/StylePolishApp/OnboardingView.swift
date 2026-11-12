import SwiftUI
import StylePolishCore

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: SettingsStore
    var permission: () -> Void
    var finish: () -> Void
    var fixture = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            steps.padding(.bottom, 20)
            switch model.state.step {
            case .permission: authorization
            case .engine: engines
            case .trial: trial
            }
        }.padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 22)
            .frame(width: 560, height: 560).background(.white).foregroundColor(PolishTheme.ink)
            .tint(PolishTheme.indigo).environment(\.colorScheme, .light)
            .onAppear { if !fixture { model.startPolling() } }
    }
    private var steps: some View {
        HStack(spacing: 8) {
            step(1, "授权")
            Rectangle().fill(PolishTheme.line).frame(height: 1)
            step(2, "润色方式")
            Rectangle().fill(PolishTheme.line).frame(height: 1)
            step(3, "试一句")
        }.font(.system(size: 12))
    }
    private func step(_ number: Int, _ title: String) -> some View {
        let done = number < model.state.step.rawValue || (number == 1 && model.state.trusted)
        let active = number == model.state.step.rawValue
        return HStack(spacing: 6) {
            Text(done ? "✓" : String(number)).font(.system(size: 11, weight: .semibold))
                .frame(width: 20, height: 20).foregroundColor(done || active ? .white : PolishTheme.sub)
                .background(done ? PolishTheme.green : active ? PolishTheme.indigo : .white).clipShape(Circle())
                .overlay(Circle().stroke(done || active ? .clear : PolishTheme.line))
            Text(title).foregroundColor(active ? PolishTheme.ink : PolishTheme.sub).fixedSize()
        }.accessibilityLabel("第 \(number) 步，\(title)\(done ? "，已完成" : "")")
    }
    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 20, weight: .semibold))
            Text(subtitle).font(.system(size: 14)).foregroundColor(PolishTheme.sub).fixedSize(horizontal: false, vertical: true)
        }.padding(.bottom, 16)
    }
    private var authorization: some View {
        Group {
            heading("先让 StylePolish 能看到你打的字", "默认在微信里使用，其他 App 可以在设置里打开（未验证的可能写回失败）。只读取普通输入框，不读密码框。")
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("辅助功能权限").fontWeight(.semibold)
                    Text(model.state.trusted ? "已授权" : "等待授权…").font(.system(size: 12, weight: .semibold))
                        .foregroundColor(model.state.trusted ? PolishTheme.green : Color(red: 180/255, green: 83/255, blue: 9/255))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(model.state.trusted ? PolishTheme.green.opacity(0.1) : Color.orange.opacity(0.1)).clipShape(Capsule())
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. 点下面的「打开系统设置」")
                    Text("2. 在列表里打开 StylePolish 的开关")
                    Text("3. 回到这里，会自动继续")
                }.foregroundColor(PolishTheme.sub)
            }.font(.system(size: 13)).padding(15).frame(maxWidth: .infinity, alignment: .leading).box()
            Text("列表里已有旧的 StylePolish 但开关无效？选中它点「−」删掉，再点「+」重新添加。")
                .font(.system(size: 12)).foregroundColor(PolishTheme.sub).padding(15).frame(maxWidth: .infinity, alignment: .leading).box().padding(.top, 10)
            Spacer()
            HStack {
                Text("升级后失效是因为新版签名不同").font(.system(size: 12)).foregroundColor(PolishTheme.sub)
                Spacer()
                Button("打开系统设置", action: permission).buttonStyle(PolishButton(primary: true))
            }
        }
    }
    private var engines: some View {
        Group {
            heading("选一种润色方式", "随时可以在设置里换。")
            engineCard(.local, description: "挑硬伤：错别字、重复的字词、重复标点。不会改写句子。")
            engineCard(.invite, description: "不用自己申请 Key。文字会经过作者的服务器转发给模型，服务器不保存内容。")
            engineCard(.ai, description: "OpenAI 兼容的 Key，不限量，费用自己付。")
            Spacer(minLength: 16)
            HStack {
                Button("上一步") { model.state.step = .permission }.buttonStyle(PolishButton())
                Spacer()
                Button("下一步") { model.next() }.buttonStyle(PolishButton(primary: true))
                    .disabled(!model.canContinue)
            }
        }
    }
    private func engineCard(_ engine: PolishEngine, description: String) -> some View {
        let selected = model.state.engine == engine
        return HStack(alignment: .top, spacing: 12) {
            Button { model.state.engine = engine } label: {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").font(.system(size: 17)).foregroundColor(selected ? PolishTheme.indigo : PolishTheme.sub)
            }.buttonStyle(.plain).accessibilityLabel("选择" + engine.title).accessibilityAddTraits(selected ? .isSelected : [])
            VStack(alignment: .leading, spacing: 4) {
                Button { model.state.engine = engine } label: {
                    HStack {
                        Text(engine == .invite ? "我有邀请码" : engine == .ai ? "用自己的 Key" : engine.title).font(.system(size: 15, weight: .semibold))
                        if engine == .invite { Text("免费试用 AI 润色").font(.system(size: 11, weight: .semibold)).foregroundColor(PolishTheme.green) }
                        if engine == .local { Text("免费 · 不联网").font(.system(size: 11, weight: .semibold)).foregroundColor(PolishTheme.green).padding(.horizontal, 7).padding(.vertical, 2).background(PolishTheme.green.opacity(0.1)).cornerRadius(5) }
                    }
                }.buttonStyle(.plain)
                Text(description).font(.system(size: 13)).foregroundColor(PolishTheme.sub).fixedSize(horizontal: false, vertical: true)
                if engine == .invite && selected { InviteSetupView(settings: settings, invite: settings.invite, fixture: fixture).padding(.top, 6) }
                if engine == .ai && selected { KeySetupView(settings: settings, fixture: fixture).padding(.top, 6) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(13).background(selected ? PolishTheme.soft : .white).cornerRadius(11)
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(selected ? PolishTheme.indigo : PolishTheme.line, lineWidth: 1.5)).padding(.bottom, 10)
            .onTapGesture { model.state.engine = engine }
    }
    private var trial: some View {
        Group {
            heading("试一句", "下面这句故意写错了。点红色波浪线采纳，或按 ⌥ Enter 全部采纳。")
            TrialEditor(text: model.state.text, suggestions: model.state.pending, edited: model.edited, select: { model.selected = $0 }, acceptAll: model.acceptAll)
                .frame(height: 80).cornerRadius(10).overlay(RoundedRectangle(cornerRadius: 10).stroke(PolishTheme.line))
            if model.state.checking { Text("检查中…").font(.caption).foregroundColor(PolishTheme.sub).padding(.top, 10) }
            if !model.message.isEmpty { Text(model.message).font(.caption).foregroundColor(.orange).padding(.top, 8) }
            if let edit = model.state.pending.first(where: { $0.id == model.selected }) {
                TrialSuggestionCard(edit: edit, accept: { model.accept(edit.id) }, ignore: { model.ignore(edit.id) }).padding(.leading, 62).padding(.top, 10)
            }
            Spacer(minLength: 8)
            HStack(alignment: .bottom, spacing: 12) {
                Text("默认在微信里使用，其他 App 可以在设置里打开（未验证的可能写回失败）。菜单栏里可以随时暂停。")
                    .font(.system(size: 12)).foregroundColor(PolishTheme.sub).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("完成", action: finish).buttonStyle(PolishButton(primary: true)).disabled(!model.state.canFinish)
            }
        }
    }
}
private struct TrialSuggestionCard: View {
    let edit: Suggestion
    var accept: () -> Void
    var ignore: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(edit.kind.title).font(.system(size: 12)).foregroundColor(PolishTheme.sub)
            if !edit.canApply { Text(edit.why).font(.system(size: 14)).foregroundColor(PolishTheme.sub) }
            else { HStack { Text(edit.original).strikethrough().foregroundColor(.red); Text("→"); Text(edit.replacement).fontWeight(.semibold).foregroundColor(PolishTheme.green) }.font(.system(size: 15)) }
            HStack { Button("采纳", action: accept).buttonStyle(PolishButton(primary: true)).disabled(!edit.canApply); Button("忽略", action: ignore).buttonStyle(PolishButton()) }
        }.padding(13).frame(width: 250, alignment: .leading).background(.white).cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(PolishTheme.line)).shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }
}
extension View {
    fileprivate func box() -> some View { background(.white).cornerRadius(10).overlay(RoundedRectangle(cornerRadius: 10).stroke(PolishTheme.line)) }
}
