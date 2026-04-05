import Cocoa
import WebKit
import UniformTypeIdentifiers

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKDownloadDelegate, WKUIDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var serverProcess: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let resources = Bundle.main.resourcePath!
        let tmpDir = "/tmp/heic-hdr-converter"
        try? FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true)

        // — Start Python server ——————————————————————————
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["\(resources)/server/app.py"]
        proc.environment = ProcessInfo.processInfo.environment.merging([
            "HEIC_TMP_DIR": tmpDir,
            "HEIC_BINARY":  "\(resources)/heic-convert",
        ]) { _, new in new }
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice

        do {
            try proc.run()
            serverProcess = proc
        } catch {
            let a = NSAlert()
            a.messageText = "Failed to start conversion server"
            a.informativeText = error.localizedDescription
            a.runModal()
            NSApp.terminate(nil)
            return
        }

        // — Window ———————————————————————————————————————
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "HEIC HDR Converter"
        window.minSize = NSSize(width: 480, height: 520)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()

        // — WebView ——————————————————————————————————————
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.underPageBackgroundColor = NSColor(srgbRed: 0.078, green: 0.078, blue: 0.078, alpha: 1)
        window.contentView = webView

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // — Load page once server is up —————————————————
        DispatchQueue.global().async {
            for _ in 0..<60 {                       // up to 15 s
                if self.isServerReady() { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            DispatchQueue.main.async {
                self.webView.load(URLRequest(url: URL(string: "http://localhost:3939")!))
            }
        }
    }

    // Re-click Dock icon → bring window forward
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }

    // Close window → quit app
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Quit → stop server
    func applicationWillTerminate(_ notification: Notification) {
        serverProcess?.terminate()
        serverProcess?.waitUntilExit()
    }

    // MARK: - UI delegate (file picker for <input type="file">)

    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.tiff, .png, .jpeg]
        panel.beginSheetModal(for: window) { result in
            completionHandler(result == .OK ? panel.urls : nil)
        }
    }

    // MARK: - Navigation delegate (download triggers)

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
        } else if let url = navigationAction.request.url,
                  url.path.hasPrefix("/api/download/") {
            decisionHandler(.download, preferences)
        } else {
            decisionHandler(.allow, preferences)
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let url = navigationResponse.response.url,
           url.path.hasPrefix("/api/download/") {
            decisionHandler(.download)
        } else if navigationResponse.canShowMIMEType {
            decisionHandler(.allow)
        } else {
            decisionHandler(.download)
        }
    }

    func webView(_ webView: WKWebView,
                 navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView,
                 navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: - Download delegate (save panel)

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.allowedContentTypes = [.heic]
        panel.beginSheetModal(for: window) { result in
            completionHandler(result == .OK ? panel.url : nil)
        }
    }

    // MARK: - Helpers

    private func isServerReady() -> Bool {
        guard let url = URL(string: "http://localhost:3939/") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 0.5)
        req.httpMethod = "HEAD"
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            if let h = resp as? HTTPURLResponse, h.statusCode == 200 { ok = true }
            sem.signal()
        }.resume()
        sem.wait()
        return ok
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
