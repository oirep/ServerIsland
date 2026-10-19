import AppKit
import SwiftUI

/// 用同一等宽字体按可用宽度测量换行；编辑区只占 2–4 行，长脚本由原生滚动容器处理。
struct ActionCommandEditor: View {
    @Binding var text: String
    var placeholder: String
    @State private var width: CGFloat = 600

    private var height: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let line = ceil(font.ascender - font.descender + font.leading)
        let bounds = (text + " " as NSString).boundingRect(
            with: NSSize(width: max(40, width - 16), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return min(line * 4 + 12, max(line * 2 + 12, ceil(bounds.height) + 12))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder).foregroundStyle(.tertiary).padding(8).allowsHitTesting(false)
            }
            PlainScriptEditor(text: $text)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { width = proxy.size.width }
                .onChange(of: proxy.size.width) { _, value in width = value }
        })
        .accessibilityLabel(L("执行内容", "Script"))
    }
}

/// Shell 输入必须保持字符原样。仅关闭 SwiftUI 自动纠错不足以关闭 AppKit 的智能引号与破折号替换。
struct PlainScriptEditor: NSViewRepresentable {
    @Binding var text: String

    static func makeTextView() -> NSTextView {
        let view = ScriptTextView()
        view.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.drawsBackground = false
        view.textColor = .labelColor
        view.insertionPointColor = .labelColor
        view.textContainerInset = NSSize(width: 6, height: 4)
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 40)
        return view
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ScriptScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        let view = Self.makeTextView()
        view.string = text
        view.delegate = context.coordinator
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text {
            let selection = view.selectedRange()
            view.string = text
            view.setSelectedRange(NSRange(location: min(selection.location, text.utf16.count), length: 0))
            view.sizeToFit()
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainScriptEditor
        init(_ parent: PlainScriptEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { parent.text = view.string }
        }
    }
}

/// 跟随窗口宽度换行，文档高度由真实内容撑开，四行之外由滚动区域承接。
final class ScriptScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let view = documentView as? NSTextView else { return }
        let width = max(1, contentSize.width)
        if abs(view.frame.width - width) > 0.5 {
            view.setFrameSize(NSSize(width: width, height: view.frame.height))
            view.sizeToFit()
        }
    }
}

final class ScriptTextView: NSTextView {
    override func paste(_ sender: Any?) {
        // 统一按纯文本粘贴，避免富文本和系统替换改变引号、连字符或缩进。
        guard let value = NSPasteboard.general.string(forType: .string) else { return }
        insertText(value, replacementRange: selectedRange())
    }
}
