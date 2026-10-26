import AppKit
import SwiftUI

/// 搜索框保持固定原生字体与高度；placeholder 由外层 SwiftUI 固定绘制，不随 field editor 改变基线。
struct DockerSearchInput: NSViewRepresentable {
    @Environment(\.islandContentActive) private var contentActive
    @Binding var text: String
    @Binding var focused: Bool
    var label: String
    var redirectReadOnlyText = false
    var onSubmit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> DockerSearchTextField {
        let field = Self.makeField()
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    /// 更换 cell 后必须重新设置输入能力，否则 NSTextFieldCell 的默认只读状态会阻止聚焦。
    static func makeField() -> DockerSearchTextField {
        let field = DockerSearchTextField()
        field.cell = DockerSearchCell(textCell: "")
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        let base = NSFont.systemFont(ofSize: 11.5)
        field.font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: 11.5) ?? base
        field.textColor = NSColor(Theme.text)
        field.placeholderString = ""
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: DockerSearchTextField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = contentActive
        field.setAccessibilityLabel(label)
        field.redirectReadOnlyText = redirectReadOnlyText
        // 每秒刷新不重置原生选择、光标或输入法的 marked text。
        if field.stringValue != text, !((field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false) {
            field.stringValue = text
        }
        field.focusChanged = { value in
            DispatchQueue.main.async { context.coordinator.parent.focused = value }
        }
    }

    static func dismantleNSView(_ field: DockerSearchTextField, coordinator: Coordinator) {
        field.stopListening()
        field.focusChanged = nil
        field.delegate = nil
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DockerSearchInput
        init(_ parent: DockerSearchInput) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.focused = true }
        func controlTextDidEndEditing(_ notification: Notification) { parent.focused = false }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // 消费搜索回车以保留焦点；输入法仍在组合文字时交还原生编辑器确认候选字。
            guard commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText(),
                  let submit = parent.onSubmit else { return false }
            submit()
            return true
        }
    }
}

/// borderless 文本默认贴顶部；显示、选中和编辑共用居中矩形，避免输入后基线偏移。
final class DockerSearchCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var result = super.drawingRect(forBounds: rect)
        let height = min(result.height, cellSize.height)
        result.origin.y += (result.height - height) / 2
        result.size.height = height
        return result
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj,
                     delegate: delegate, start: selStart, length: selLength)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView, editor: textObj,
                   delegate: delegate, event: event)
    }
}

enum DockerSearchKeyRouting {
    @MainActor
    static func preservesTextFocus(_ responder: NSResponder?, redirectReadOnlyText: Bool) -> Bool {
        if let view = responder as? NSTextView { return view.isEditable || !redirectReadOnlyText }
        return responder is NSTextField
    }
    /// 仅普通文字触发搜索；快捷键、导航、菜单与其它文本编辑器继续走原事件链。
    static func accepts(characters: String?, modifiers: NSEvent.ModifierFlags, keyCode: UInt16,
                        hasTextFocus: Bool, menuTracking: Bool) -> Bool {
        guard !hasTextFocus, !menuTracking, modifiers.intersection([.command, .control]).isEmpty,
              ![36, 48, 51, 53, 76, 117].contains(keyCode), let characters else { return false }
        return characters.unicodeScalars.contains {
            !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
        }
    }
}

final class DockerSearchTextField: NSTextField {
    var focusChanged: ((Bool) -> Void)?
    var redirectReadOnlyText = false
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var menuDepth = 0

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 18) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopListening()
        guard window is IslandPanel else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.route(event)
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuDepth += 1 }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { self.menuDepth = max(0, self.menuDepth - 1) } }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.focusChanged?(false) }
        })
        // 列表打开时让非激活面板接收本窗口按键，无需监听或吞掉其它 App 的输入。
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window as? IslandPanel, window.isVisible, self.isEnabled else { return }
            window.makeKey()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChanged?(true) }
        return accepted
    }

    private func route(_ event: NSEvent) -> NSEvent? {
        guard isEnabled, let window, window.isKeyWindow, event.window === window else { return event }
        let responder = window.firstResponder
        // 日志文本可选中复制，但普通打字应进入搜索；其它可编辑输入框仍保留自己的输入。
        let textFocus = DockerSearchKeyRouting.preservesTextFocus(responder, redirectReadOnlyText: redirectReadOnlyText)
        guard DockerSearchKeyRouting.accepts(characters: event.characters?.isEmpty == false ? event.characters : event.charactersIgnoringModifiers,
                                             modifiers: event.modifierFlags, keyCode: event.keyCode,
                                             hasTextFocus: textFocus,
                                             menuTracking: menuDepth > 0),
              window.makeFirstResponder(self), let editor = currentEditor() else { return event }
        focusChanged?(true)
        // 转交完整原始事件，而非拼接 characters：首键、Option 死键和中文输入法均由原生编辑器处理。
        editor.keyDown(with: event)
        return nil
    }

    func stopListening() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        menuDepth = 0
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
