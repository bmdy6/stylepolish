import SwiftUI
import AppKit
import StylePolishCore

enum InlinePalette {
    static let red = Color(red: 229/255, green: 72/255, blue: 77/255)
    static let amber = Color(red: 245/255, green: 158/255, blue: 11/255)
    static let green = Color(red: 26/255, green: 127/255, blue: 55/255)
    static let muted = Color(red: 138/255, green: 143/255, blue: 152/255)
}
struct SuggestionCard: View {
    let suggestion: Suggestion
    var accept: () -> Void
    var ignore: () -> Void
    var disable: () -> Void
    var sizeChanged: (() -> Void)? = nil
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(suggestion.kind.title).font(.system(size: 12)).foregroundColor(InlinePalette.muted)
                Spacer()
                Menu {
                    Button("这类不再提示", action: disable)
                    Button("为什么这样改") { expanded.toggle() }
                } label: { Text("···").foregroundColor(InlinePalette.muted) }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("更多建议选项")
            }.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            Button(action: accept) {
                VStack(alignment: .leading, spacing: 10) {
                    if suggestion.replacement.isEmpty {
                        Text(suggestion.original).strikethrough().foregroundColor(InlinePalette.red).font(.system(size: 18, weight: .medium))
                        Text("点击删除").font(.system(size: 12)).foregroundColor(InlinePalette.green)
                    } else {
                        Text(suggestion.replacement).font(.system(size: 18, weight: .semibold)).foregroundColor(InlinePalette.green)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 12).accessibilityLabel(suggestion.replacement.isEmpty ? "删除\(suggestion.original)" : "采纳\(suggestion.replacement)")
            if !suggestion.why.isEmpty || expanded {
                Text(suggestion.why.isEmpty ? "模型未提供原因，按文字差异生成建议" : suggestion.why)
                    .font(.system(size: 12)).foregroundColor(InlinePalette.muted).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14).padding(.bottom, 10)
            }
            Divider()
            Button(action: ignore) { Label("忽略", systemImage: "eye.slash").font(.system(size: 12)).foregroundColor(InlinePalette.muted).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 9)
        }.frame(width: 240).background(.white).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(red: 227/255, green: 229/255, blue: 233/255), lineWidth: 1))
            .padding(.bottom, 6)
            .overlay(alignment: .bottomLeading) { CardPointer().fill(.white).frame(width: 12, height: 7).offset(x: 28) }
            .environment(\.colorScheme, .light)
            .onChange(of: expanded) { _ in sizeChanged?() }
    }
}
struct CardPointer: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in path.move(to: CGPoint(x: 0, y: 0)); path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY)); path.addLine(to: CGPoint(x: rect.maxX, y: 0)); path.closeSubpath() }
    }
}
struct SuggestionList: View {
    let suggestions: [LocatedSuggestion]
    var accept: (UUID) -> Void
    var ignore: (UUID) -> Void
    var acceptAll: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(suggestions) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top) {
                                Text(item.edit.original).strikethrough().foregroundColor(InlinePalette.red)
                                Text("→")
                                Button(item.edit.replacement.isEmpty ? "删除" : item.edit.replacement) { accept(item.id) }.buttonStyle(.plain).foregroundColor(InlinePalette.green)
                            }
                            HStack { Text(item.edit.kind.title).foregroundColor(InlinePalette.muted); Spacer(); Button("采纳") { accept(item.id) }; Button("忽略") { ignore(item.id) } }.font(.system(size: 11))
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        Divider()
                    }
                }
            }.frame(maxHeight: 260)
            HStack { Text("⌥ Enter").font(.system(size: 11)).foregroundColor(InlinePalette.muted); Spacer(); Button("全部采纳", action: acceptAll) }.padding(12)
        }.frame(width: 280).font(.system(size: 13)).background(.white).clipShape(RoundedRectangle(cornerRadius: 12)).environment(\.colorScheme, .light)
    }
}

struct AutomaticPreviewBar: View {
    let preview: SuggestionPreview
    var width: CGFloat = 850
    private var textHeight: CGFloat {
        let text = preview.output
        let bounds = (text as NSString).boundingRect(with: NSSize(width: max(100, width - 250), height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 14)])
        return min(100, max(22, ceil(bounds.height) + 4))
    }
    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            ScrollView(.vertical) {
                diff.font(.system(size: 14)).lineSpacing(4).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: textHeight)
            Text("⌥Enter 全部采纳 · Esc 忽略").font(.system(size: 11)).foregroundColor(Color(white: 0.45)).fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color(white: 0.98))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.25)))
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .combine)
    }
    /// Shows the final sentence as normal text; rewritten runs are tinted, never struck through.
    private var diff: Text {
        preview.segments.reduce(Text("")) { result, part in
            result + Text(part.text).foregroundColor(part.changed ? InlinePalette.green : Color(white: 0.12))
        }
    }
}
