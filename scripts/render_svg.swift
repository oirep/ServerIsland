// 用 WebKit 把 SVG 渲染成透明背景 PNG（系统自带，无需安装其他工具）。
//   swift scripts/render_svg.swift <in.svg> <out.png> <像素尺寸>
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 4, let size = Int(args[3]) else {
    print("usage: render_svg.swift in.svg out.png size"); exit(1)
}
let svg = try String(contentsOfFile: args[1], encoding: .utf8)
let out = args[2]

final class Renderer: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let size: Int
    init(size: Int) {
        self.size = size
        // 以 1x 逻辑像素渲染，snapshot 再按目标像素输出。
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        web.setValue(false, forKey: "drawsBackground")
        super.init()
        web.navigationDelegate = self
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = NSRect(x: 0, y: 0, width: size, height: size)
        cfg.snapshotWidth = NSNumber(value: Double(size) / Double(NSScreen.main?.backingScaleFactor ?? 2))
        webView.takeSnapshot(with: cfg) { image, error in
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                print("snapshot failed: \(String(describing: error))"); exit(1)
            }
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = NSSize(width: self.size, height: self.size)
            let png = rep.representation(using: .png, properties: [:])!
            try! png.write(to: URL(fileURLWithPath: out))
            print("wrote \(out) (\(cg.width)x\(cg.height))")
            exit(0)
        }
    }
}

let app = NSApplication.shared
let r = Renderer(size: size)
let html = """
<html><head><style>html,body{margin:0;background:transparent;overflow:hidden}
svg{width:\(size)px;height:\(size)px;display:block}</style></head><body>\(svg)</body></html>
"""
r.web.loadHTMLString(html, baseURL: nil)
app.run()
