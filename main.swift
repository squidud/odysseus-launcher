import Cocoa
import WebKit

// MARK: - Model Configuration Window

struct ModelEntry {
    var file: String
    var port: Int
    var ctx: Int
    var autoStart: Bool
    var args: String
    var mmproj: String?
    // Runtime
    var filePath: String = ""
    var fileSizeMB: Int = 0
    var cachedRunning: Bool = false  // precomputed on background thread

    var displayName: String {
        file.replacingOccurrences(of: ".gguf", with: "")
            .replacingOccurrences(of: "-Instruct", with: "")
            .replacingOccurrences(of: "-Instruct-", with: "-")
    }
    var sizeLabel: String {
        fileSizeMB > 0 ? "\(fileSizeMB / 1024) GB" : "—"
    }

    // Real-time socket check — call only from background or when result is immediately needed.
    var isRunning: Bool {
        guard port > 0 else { return false }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).byteSwapped
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    func toDictionary() -> [String: Any] {
        var d: [String: Any] = ["file": file, "port": port, "ctx": ctx, "autoStart": autoStart, "args": args]
        if let mp = mmproj { d["mmproj"] = mp }
        return d
    }
}

class ModelConfigWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    var window: NSWindow!
    var tableView: NSTableView!
    var memLabel: NSTextField!
    var models: [ModelEntry] = []
    let hfCache: String
    let configPath: String
    let launcherPath: String
    var childEnv: [String: String]

    init(hfCache: String, configPath: String, launcherPath: String, childEnv: [String: String]) {
        self.hfCache      = hfCache
        self.configPath   = configPath
        self.launcherPath = launcherPath
        self.childEnv     = childEnv
    }

    func show() {
        if window == nil { buildWindow() }
        refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Odysseus — Model Configuration"
        window.delegate = self
        window.center()

        let cv = window.contentView!

        // Header
        let header = NSTextField(labelWithString: "Local AI Models")
        header.font = .boldSystemFont(ofSize: 13)
        header.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(header)

        // Detect system RAM for display
        var ramBytes: UInt64 = 0
        var ramLen = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &ramBytes, &ramLen, nil, 0)
        let sysRAM = Int(ramBytes) / (1024 * 1024 * 1024)
        var ncpu: Int32 = 0
        var cpuLen = MemoryLayout<Int32>.size
        sysctlbyname("hw.ncpu", &ncpu, &cpuLen, nil, 0)
        let sysInfo = "System: \(sysRAM) GB RAM · \(ncpu) CPU · Apple Metal GPU"

        let sub = NSTextField(labelWithString: "Changes to Auto-start take effect on next app launch. Load/Unload act immediately.  \(sysInfo)")
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(sub)

        // Table
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        cv.addSubview(scroll)

        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate   = self
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true

        let cols: [(String, CGFloat)] = [
            ("Model", 230), ("Size", 60), ("Port", 55), ("Status", 75), ("Auto-start", 85), ("Action", 90)
        ]
        for (title, width) in cols {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
            col.title = title
            col.width = width
            col.minWidth = width * 0.7
            tableView.addTableColumn(col)
        }
        scroll.documentView = tableView

        // Memory label
        memLabel = NSTextField(labelWithString: "")
        memLabel.font = .systemFont(ofSize: 11)
        memLabel.textColor = .secondaryLabelColor
        memLabel.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(memLabel)

        // Bottom buttons
        let refreshBtn = NSButton(title: "↻ Refresh", target: self, action: #selector(refresh))
        refreshBtn.bezelStyle = .rounded
        refreshBtn.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(refreshBtn)

        let updateBtn = NSButton(title: "Check for Updates", target: self, action: #selector(checkForUpdates))
        updateBtn.bezelStyle = .rounded
        updateBtn.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(updateBtn)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: cv.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            sub.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            sub.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            sub.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: memLabel.topAnchor, constant: -10),
            memLabel.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -14),
            memLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            updateBtn.centerYAnchor.constraint(equalTo: memLabel.centerYAnchor),
            updateBtn.trailingAnchor.constraint(equalTo: refreshBtn.leadingAnchor, constant: -8),
            refreshBtn.centerYAnchor.constraint(equalTo: memLabel.centerYAnchor),
            refreshBtn.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -12),
        ])
    }

    var isRefreshing = false

    @objc func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = self.buildModels()
            DispatchQueue.main.async {
                self.models = loaded
                self.tableView?.reloadData()
                self.updateMemLabel()
                self.isRefreshing = false
            }
        }
    }

    private func buildModels() -> [ModelEntry] {
        // Load JSON config
        var configs: [[String: Any]] = []
        if let data = FileManager.default.contents(atPath: configPath),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            configs = arr
        }

        // Scan HF cache for actual files
        var found: [String: (path: String, sizeMB: Int)] = [:]
        let fm = FileManager.default
        if let enumerator = fm.enumerator(atPath: hfCache) {
            for case let name as String in enumerator {
                if name.hasSuffix(".gguf") && !name.hasSuffix(".incomplete") {
                    let full = "\(hfCache)/\(name)"
                    let fname = URL(fileURLWithPath: full).lastPathComponent
                    let size = (try? fm.attributesOfItem(atPath: full)[.size] as? Int) ?? 0
                    found[fname] = (full, size / 1024 / 1024)
                }
            }
        }

        var entries: [ModelEntry] = []
        var seenFiles = Set<String>()

        // Configured models first
        for cfg in configs {
            guard let file = cfg["file"] as? String else { continue }
            seenFiles.insert(file)
            var entry = ModelEntry(
                file:      file,
                port:      cfg["port"] as? Int ?? 0,
                ctx:       cfg["ctx"] as? Int ?? 8192,
                autoStart: cfg["autoStart"] as? Bool ?? false,
                args:      cfg["args"] as? String ?? "",
                mmproj:    cfg["mmproj"] as? String
            )
            if let info = found[file] {
                entry.filePath   = info.path
                entry.fileSizeMB = info.sizeMB
            }
            entry.cachedRunning = entry.isRunning  // compute on background thread
            entries.append(entry)
        }

        // Any downloaded-but-unconfigured models — add with autoStart=false
        var nextPort = 8093
        for (fname, info) in found.sorted(by: { $0.key < $1.key }) {
            guard !seenFiles.contains(fname), !fname.contains("mmproj") else { continue }
            var entry = ModelEntry(
                file: fname, port: nextPort, ctx: 8192, autoStart: false, args: "--jinja",
                filePath: info.path, fileSizeMB: info.sizeMB)
            entry.cachedRunning = entry.isRunning
            entries.append(entry)
            nextPort += 1
        }

        return entries
    }

    private func saveConfig() {
        let arr = models.map { $0.toDictionary() }
        if let data = try? JSONSerialization.data(withJSONObject: arr, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: configPath))
        }
    }

    private func updateMemLabel() {
        let runningMB = models.filter { $0.cachedRunning && $0.fileSizeMB > 0 }.reduce(0) { $0 + $1.fileSizeMB }
        memLabel.stringValue = runningMB > 0
            ? "Running: \(runningMB / 1024) GB on Metal"
            : "No models running"
    }

    @discardableResult
    private func shell(_ bin: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.environment = childEnv
        p.standardOutput = FileHandle.nullDevice
        p.standardError  = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    @objc func checkForUpdates() {
        let result = Process()
        result.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        result.arguments = ["-C", (configPath as NSString).deletingLastPathComponent, "fetch", "--dry-run"]
        result.environment = childEnv

        let pipe = Pipe()
        result.standardOutput = pipe
        result.standardError  = pipe
        try? result.run()
        result.waitUntilExit()
        // fetch output unused — we only care about the log diff below

        // Compare local HEAD to remote
        let log = Process()
        log.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        log.arguments = ["-C", (configPath as NSString).deletingLastPathComponent,
                         "log", "HEAD..origin/HEAD", "--oneline"]
        log.environment = childEnv
        let logPipe = Pipe()
        log.standardOutput = logPipe; log.standardError = logPipe
        try? log.run(); log.waitUntilExit()
        let commits = String(data: logPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        DispatchQueue.main.async {
            let alert = NSAlert()
            if commits.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                alert.messageText = "Odysseus is up to date"
                alert.informativeText = "You are running the latest version."
            } else {
                let lines = commits.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
                alert.messageText = "\(lines.count) update(s) available"
                alert.informativeText = lines.prefix(6).joined(separator: "\n")
                alert.addButton(withTitle: "Update Now")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    self.runUpdate()
                    return
                }
            }
            alert.runModal()
        }
    }

    private func runUpdate() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", (configPath as NSString).deletingLastPathComponent, "pull", "--ff-only"]
        p.environment = childEnv
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try? p.run(); p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = p.terminationStatus == 0 ? "Update complete" : "Update failed"
            alert.informativeText = out.isEmpty ? "Restart the app to apply changes." : out
            alert.runModal()
        }
    }

    @objc func toggleAutoStart(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < models.count else { return }
        models[row].autoStart = sender.state == .on
        saveConfig()
    }

    @objc func loadModel(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < models.count else { return }
        let entry = models[row]
        if entry.isRunning {  // real-time check for the action
            shell("/bin/zsh", ["-c", "lsof -ti :\(entry.port) -sTCP:LISTEN 2>/dev/null | xargs kill -TERM 2>/dev/null"])
        } else {
            shell("/opt/homebrew/bin/python3", [launcherPath, "start", String(entry.port)])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { models.count }

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = models[row]
        let id = tableColumn?.identifier.rawValue ?? ""

        switch id {
        case "Model":
            let tf = NSTextField(labelWithString: entry.filePath.isEmpty
                ? "\(entry.displayName) ⚠ not downloaded" : entry.displayName)
            tf.lineBreakMode = .byTruncatingTail
            tf.textColor = entry.filePath.isEmpty ? .secondaryLabelColor : .labelColor
            return tf

        case "Size":
            return NSTextField(labelWithString: entry.sizeLabel)

        case "Port":
            return NSTextField(labelWithString: entry.port > 0 ? ":\(entry.port)" : "—")

        case "Status":
            let running = entry.cachedRunning
            let dot = NSTextField(labelWithString: running ? "● Running" : "○ Stopped")
            dot.textColor = running ? .systemGreen : .secondaryLabelColor
            dot.font = .systemFont(ofSize: 11)
            return dot

        case "Auto-start":
            let cb = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleAutoStart(_:)))
            cb.state = entry.autoStart ? .on : .off
            cb.isEnabled = entry.port > 0
            return cb

        case "Action":
            guard entry.port > 0 else { return nil }
            let running = entry.cachedRunning
            let btn = NSButton(title: running ? "Unload" : "Load",
                               target: self, action: #selector(loadModel(_:)))
            btn.bezelStyle = .rounded
            btn.isEnabled = !entry.filePath.isEmpty || running
            return btn

        default:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 22 }
}

// MARK: - Main App

class OdysseusWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {

    var window: NSWindow!
    var webView: OdysseusWebView!
    var loadingView: NSView?
    var loadingLabel: NSTextField!
    var progressBar: NSProgressIndicator!
    var stageLabel: NSTextField!
    var retryButton: NSButton!
    var llamaProcess: Process?
    var isReconnecting = false
    var configWindow: ModelConfigWindow?
    var navFailCount = 0

    let odysseusDir = NSHomeDirectory() + "/odysseus"
    let colimaBin   = "/opt/homebrew/bin/colima"
    let dockerBin   = "/opt/homebrew/bin/docker"
    let targetURL   = URL(string: "http://127.0.0.1:7860")!

    let childEnv: [String: String] = {
        let info = ProcessInfo.processInfo.environment
        let home = info["HOME"] ?? NSHomeDirectory()
        return [
            "HOME":        home,
            "USER":        info["USER"] ?? "",
            "TMPDIR":      info["TMPDIR"] ?? "/tmp",
            "PATH":        "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "COLIMA_HOME": "\(home)/.colima",
            "DOCKER_HOST": "unix://\(home)/.colima/default/docker.sock",
        ]
    }()

    // MARK: Launch

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        buildWindow()
        buildWebView()
        showLoadingView(progress: 0, stage: "Checking services…")
        NSApp.activate(ignoringOtherApps: true)

        // Sleep/wake observer — reconnect when Mac wakes from sleep
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        DispatchQueue.global(qos: .userInitiated).async { self.startAndLoad() }
    }

    // MARK: Window

    func buildWindow() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w: CGFloat = min(1400, screen.width  * 0.88)
        let h: CGFloat = min(920,  screen.height * 0.88)
        window = NSWindow(
            contentRect: NSRect(x: screen.midX - w/2, y: screen.midY - h/2, width: w, height: h),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Odysseus"
        window.setFrameAutosaveName("OdysseusMainWindow")
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Loading overlay

    func showLoadingView(progress: Double, stage: String) {
        DispatchQueue.main.async {
            let cv = self.window.contentView!

            if self.loadingView == nil {
                let lv = NSView(frame: cv.bounds)
                lv.autoresizingMask = [.width, .height]

                // App icon
                let icon = NSImageView()
                icon.image = NSApp.applicationIconImage
                icon.imageScaling = .scaleProportionallyUpOrDown
                icon.translatesAutoresizingMaskIntoConstraints = false

                // Main status label
                let label = NSTextField(labelWithString: stage)
                label.translatesAutoresizingMaskIntoConstraints = false
                label.alignment = .center
                label.font = .systemFont(ofSize: 14, weight: .medium)
                self.loadingLabel = label

                // Determinate progress bar
                let bar = NSProgressIndicator()
                bar.style = .bar
                bar.isIndeterminate = false
                bar.minValue = 0
                bar.maxValue = 100
                bar.doubleValue = progress
                bar.translatesAutoresizingMaskIntoConstraints = false
                self.progressBar = bar

                // Small stage detail label below bar
                let stage2 = NSTextField(labelWithString: "")
                stage2.translatesAutoresizingMaskIntoConstraints = false
                stage2.alignment = .center
                stage2.font = .systemFont(ofSize: 11)
                stage2.textColor = .secondaryLabelColor
                self.stageLabel = stage2

                // Retry button
                let retry = NSButton(title: "Retry", target: self, action: #selector(self.retryLoad))
                retry.bezelStyle = .rounded
                retry.translatesAutoresizingMaskIntoConstraints = false
                retry.isHidden = true
                self.retryButton = retry

                [icon, label, bar, stage2, retry].forEach { lv.addSubview($0) }
                NSLayoutConstraint.activate([
                    icon.centerXAnchor.constraint(equalTo: lv.centerXAnchor),
                    icon.centerYAnchor.constraint(equalTo: lv.centerYAnchor, constant: -80),
                    icon.widthAnchor.constraint(equalToConstant: 72),
                    icon.heightAnchor.constraint(equalToConstant: 72),
                    label.centerXAnchor.constraint(equalTo: lv.centerXAnchor),
                    label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 18),
                    bar.centerXAnchor.constraint(equalTo: lv.centerXAnchor),
                    bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
                    bar.widthAnchor.constraint(equalToConstant: 280),
                    stage2.centerXAnchor.constraint(equalTo: lv.centerXAnchor),
                    stage2.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 8),
                    retry.centerXAnchor.constraint(equalTo: lv.centerXAnchor),
                    retry.topAnchor.constraint(equalTo: stage2.bottomAnchor, constant: 14),
                ])

                cv.addSubview(lv)
                self.loadingView = lv
            }

            self.loadingLabel.stringValue = stage
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                self.progressBar.animator().doubleValue = progress
            }
            self.retryButton.isHidden = true
        }
    }

    func setProgress(_ pct: Double, stage: String, detail: String = "") {
        DispatchQueue.main.async {
            self.loadingLabel.stringValue = stage
            self.stageLabel.stringValue = detail
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                self.progressBar.animator().doubleValue = pct
            }
        }
    }

    func hideLoadingView() {
        DispatchQueue.main.async {
            guard let lv = self.loadingView else { return }
            lv.removeFromSuperview()
            self.loadingView = nil
        }
    }

    @objc func retryLoad() {
        retryButton?.isHidden = true
        showLoadingView(progress: 0, stage: "Retrying…")
        DispatchQueue.global(qos: .userInitiated).async { self.startAndLoad() }
    }

    func showError(_ msg: String) {
        DispatchQueue.main.async {
            if self.loadingView == nil {
                self.showLoadingView(progress: 0, stage: msg)
            } else {
                self.loadingLabel.stringValue = msg
                self.progressBar.doubleValue = 0
            }
            self.retryButton?.isHidden = false
        }
    }

    // MARK: WebView

    func buildWebView() {
        let cfg = WKWebViewConfiguration()

        // Fix: CSS mask-image via var(--em) doesn't send cookies in WKWebView CSS context.
        // Strategy: fetch SVG as text → embed as data URL → set -webkit-mask directly on element.
        // Fallback: if fetch fails show raw Unicode emoji from aria-label (never invisible).
        let emojiFixJS = """
        (function() {
            var svgCache = {};  // url -> Promise<dataUrl|null>

            function applyMask(span, dataUrl) {
                var mask = "url(\\"" + dataUrl + "\\") center / contain no-repeat";
                span.style.webkitMask = mask;
                span.style.mask = mask;
                span.dataset.emFixed = '1';
            }

            function showFallback(span) {
                // Show raw Unicode emoji — always visible, never broken
                var label = span.getAttribute('aria-label') || '';
                if (label) {
                    span.textContent = label;
                    span.style.backgroundColor = 'transparent';
                    span.style.webkitMask = 'none';
                    span.style.mask = 'none';
                    span.style.display = 'inline';
                    span.style.width = 'auto';
                    span.style.height = 'auto';
                    span.style.verticalAlign = '-0.1em';
                }
                span.dataset.emFixed = '1';
            }

            function fixSpan(span) {
                if (span.dataset.emFixed) return;
                var raw = span.style.getPropertyValue('--em') || '';
                if (!raw) return;
                var m = raw.match(/url\\(['"]?(\\/api\\/emoji\\/[^'"\\)]+)['"]?\\)/);
                if (!m) return;
                span.dataset.emFixed = 'pending';

                var url = m[1];
                if (!svgCache[url]) {
                    svgCache[url] = fetch(url, { credentials: 'include' })
                        .then(function(r) {
                            if (!r.ok) return null;
                            return r.text();
                        })
                        .then(function(text) {
                            if (!text) return null;
                            try {
                                // Embed as data URL — no auth needed at render time
                                return 'data:image/svg+xml;base64,' + btoa(unescape(encodeURIComponent(text)));
                            } catch(e) { return null; }
                        })
                        .catch(function() { return null; });
                }

                svgCache[url].then(function(dataUrl) {
                    if (dataUrl) {
                        applyMask(span, dataUrl);
                    } else {
                        showFallback(span);
                    }
                });
            }

            function fixAll() {
                document.querySelectorAll('.emoji:not([data-em-fixed])').forEach(fixSpan);
            }

            var obs = new MutationObserver(function(mutations) {
                var needsFix = false;
                mutations.forEach(function(mut) {
                    if (mut.type === 'childList') {
                        mut.addedNodes.forEach(function(n) {
                            if (n.nodeType !== 1) return;
                            if (n.classList && n.classList.contains('emoji') && !n.dataset.emFixed) { fixSpan(n); }
                            else if (n.querySelectorAll) n.querySelectorAll('.emoji:not([data-em-fixed])').forEach(fixSpan);
                        });
                    }
                    if (mut.type === 'attributes' && mut.target.classList &&
                        mut.target.classList.contains('emoji') && !mut.target.dataset.emFixed) {
                        fixSpan(mut.target);
                    }
                });
            });
            obs.observe(document.documentElement, {
                childList: true, subtree: true,
                attributes: true, attributeFilter: ['style', 'data-em-fixed']
            });
            setInterval(fixAll, 300);
            fixAll();
        })();
        """
        cfg.userContentController.addUserScript(
            WKUserScript(source: emojiFixJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false))

        webView = OdysseusWebView(frame: window.contentView!.bounds, configuration: cfg)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.width, .height]
        webView.isHidden = true
        window.contentView!.addSubview(webView)
    }

    // MARK: Process helpers

    @discardableResult
    func shell(_ bin: String, _ args: [String], timeout: TimeInterval = 120) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.environment = childEnv
        p.standardOutput = FileHandle.nullDevice
        p.standardError  = FileHandle.nullDevice
        try? p.run()
        let deadline = Date(timeIntervalSinceNow: timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        if p.isRunning { p.terminate() }
        return p.terminationStatus
    }

    // Like shell() but captures stderr and returns it alongside the exit code.
    func shellCapture(_ bin: String, _ args: [String], timeout: TimeInterval = 120) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.environment = childEnv
        p.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardError = pipe
        try? p.run()
        let deadline = Date(timeIntervalSinceNow: timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        if p.isRunning { p.terminate() }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, output)
    }

    // Show a blocking NSAlert on the main thread (safe to call from background threads).
    // Returns true if the user chose Retry.
    func startupAlert(_ title: String, _ detail: String) -> Bool {
        var retry = false
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = detail.isEmpty
                ? "Check /tmp/odysseus-launch.log for details."
                : detail + "\n\nCheck /tmp/odysseus-launch.log for details."
            a.alertStyle = .critical
            a.addButton(withTitle: "Retry")
            a.addButton(withTitle: "Quit")
            retry = (a.runModal() == .alertFirstButtonReturn)
            sem.signal()
        }
        sem.wait()
        return retry
    }

    func log(_ msg: String) {
        let line = "\(Date()): \(msg)\n"
        if let data = line.data(using: .utf8),
           let fh = FileHandle(forWritingAtPath: "/tmp/odysseus-launch.log") {
            fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
        } else {
            try? line.write(toFile: "/tmp/odysseus-launch.log",
                            atomically: false, encoding: .utf8)
        }
    }

    func isReachable() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-s", "-o", "/dev/null", "-w", "%{http_code}",
                       "--max-time", "2", "--connect-timeout", "2",
                       "http://127.0.0.1:7860"]
        p.environment = childEnv
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError  = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let code = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                          encoding: .utf8) ?? "000"
        let ok = !code.isEmpty && code != "000"
        log("isReachable → curl HTTP \(code) → \(ok)")
        return ok
    }

    func colimaRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: colimaBin)
        p.arguments = ["status"]
        p.environment = childEnv
        p.standardOutput = FileHandle.nullDevice
        p.standardError  = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // Verify Docker socket is actually connectable, not just a stale file.
    // Colima's SSH port forwarding can die while the VM stays "running".
    func dockerConnectable() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: dockerBin)
        p.arguments = ["info"]
        p.environment = childEnv
        p.standardOutput = FileHandle.nullDevice
        p.standardError  = FileHandle.nullDevice
        try? p.run()
        let deadline = Date(timeIntervalSinceNow: 4)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if p.isRunning { p.terminate(); return false }
        return p.terminationStatus == 0
    }

    func waitForDocker(seconds: Int = 15) -> Bool {
        for _ in 0..<seconds {
            if dockerConnectable() { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    // MARK: Startup sequence

    // Detect system RAM in GB using sysctl
    var systemRAMGB: Int {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &len, nil, 0)
        return Int(size) / (1024 * 1024 * 1024)
    }

    // Detect logical CPU count
    var systemCPUCount: Int {
        var count: Int32 = 4
        var len = MemoryLayout<Int32>.size
        sysctlbyname("hw.ncpu", &count, &len, nil, 0)
        return Int(count)
    }

    // Write colima.yaml with system-appropriate values — only when VM doesn't exist yet.
    func configureColima() {
        // Colima stores its Lima instance at $COLIMA_HOME/_lima/colima.
        // Once that directory exists, the VM has been created — CPU/memory can't change.
        let limaColima = "\(NSHomeDirectory())/.colima/_lima/colima"
        if FileManager.default.fileExists(atPath: limaColima) { return }

        let yamlPath = "\(NSHomeDirectory())/.colima/default/colima.yaml"
        guard var yaml = try? String(contentsOfFile: yamlPath, encoding: .utf8) else { return }

        let ramGB  = systemRAMGB
        let ncpu   = systemCPUCount
        // Allocate ~50% of RAM (min 4 GB, max 20 GB) and ~75% of CPUs (min 2)
        let allocRAM = max(4, min(20, ramGB / 2))
        let allocCPU = max(2, ncpu * 3 / 4)

        yaml = yaml.replacingOccurrences(of: #"cpu: \d+"#,    with: "cpu: \(allocCPU)",    options: .regularExpression)
        yaml = yaml.replacingOccurrences(of: #"memory: \d+"#, with: "memory: \(allocRAM)", options: .regularExpression)
        try? yaml.write(toFile: yamlPath, atomically: true, encoding: .utf8)
    }

    func ensureOdysseus() -> Bool {
        let compose = "\(odysseusDir)/docker-compose.yml"
        if FileManager.default.fileExists(atPath: compose) { return true }
        setProgress(12, stage: "First launch — downloading Odysseus…", detail: "Cloning from GitHub, ~30 s")
        let rc = shell("/usr/bin/git",
            ["clone", "--depth=1", "https://github.com/pewdiepie-archdaemon/odysseus.git", odysseusDir],
            timeout: 180)
        if rc != 0 {
            showError("Failed to download Odysseus. Check your internet connection.")
            return false
        }
        // Copy bundled launcher scripts into odysseusDir
        let bundle = Bundle.main.resourcePath ?? ""
        let scripts = ["llama-server.sh", "llama-launcher.py", "json-proxy.py",
                       "image-server.py", "register-endpoints.py"]
        for s in scripts {
            let src = "\(bundle)/\(s)"
            let dst = "\(odysseusDir)/\(s)"
            if FileManager.default.fileExists(atPath: src) && !FileManager.default.fileExists(atPath: dst) {
                try? FileManager.default.copyItem(atPath: src, toPath: dst)
            }
        }
        return true
    }

    func startAndLoad() {
        log("startAndLoad begin")
        // Fast path: already up — still ensure local models are running
        setProgress(5, stage: "Checking services…")
        if isReachable() {
            log("fast path: Odysseus already up")
            startLlamaServer()
            setProgress(100, stage: "Ready")
            Thread.sleep(forTimeInterval: 0.2)
            DispatchQueue.main.async { self.revealWebView() }
            return
        }

        setProgress(10, stage: "Checking Odysseus installation…")
        if !ensureOdysseus() { log("ensureOdysseus failed"); return }

        setProgress(18, stage: "Checking Colima VM…")
        configureColima()
        log("colimaRunning: \(colimaRunning())")

        if !colimaRunning() {
            setProgress(22, stage: "Starting Colima VM…", detail: "This takes ~20 s on first launch")
            let rc = shell(colimaBin, ["start"], timeout: 180)
            log("colima start rc=\(rc)")
            if rc != 0 {
                showError("Failed to start Colima VM.")
                return
            }
        }

        // Wait for Docker socket to be genuinely connectable before running compose.
        setProgress(38, stage: "Waiting for Docker…")
        if !waitForDocker(seconds: 20) {
            log("Docker not connectable after 20s")
            showError("Docker did not start. Try relaunching.")
            return
        }
        log("Docker connectable")

        setProgress(40, stage: "Starting Docker containers…")
        let (composeRc, composeErr) = shellCapture(dockerBin,
            ["compose", "-f", "\(odysseusDir)/docker-compose.yml", "up", "-d"], timeout: 120)
        log("docker compose up rc=\(composeRc)")
        if composeRc != 0 {
            let trimmed = composeErr.trimmingCharacters(in: .whitespacesAndNewlines)
            log("compose stderr: \(trimmed)")
            if startupAlert("Docker containers failed to start",
                            trimmed.isEmpty ? "" : String(trimmed.suffix(400))) {
                startAndLoad()
            } else {
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return
        }

        setProgress(60, stage: "Starting local AI models…")
        startLlamaServer()
        log("llama server launched")

        // Wait for Odysseus — up to 3 minutes from cold start
        for i in 0..<180 {
            Thread.sleep(forTimeInterval: 1)
            if isReachable() {
                log("Odysseus ready after \(i)s")
                setProgress(100, stage: "Ready")
                Thread.sleep(forTimeInterval: 0.3)
                DispatchQueue.main.async { self.revealWebView() }
                return
            }
            let pct = 60.0 + Double(i) * (39.0 / 180.0)
            setProgress(pct, stage: "Waiting for Odysseus…", detail: "\(i)s elapsed")
        }
        log("timed out after 180s")
        if startupAlert("Odysseus did not start in time",
                        "The service took longer than 3 minutes. It may still be starting.") {
            startAndLoad()
        } else {
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func revealWebView() {
        hideLoadingView()
        webView.isHidden = false
        loadOdysseus()
    }

    // MARK: Sleep / wake

    @objc func systemDidWake() {
        guard !isReconnecting else { return }
        isReconnecting = true

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3) {
            defer { self.isReconnecting = false }

            // Quick check first — if still up, just reload
            if self.isReachable() {
                DispatchQueue.main.async {
                    self.webView.reload()
                }
                return
            }

            // Services need to come back up — show reconnecting overlay
            DispatchQueue.main.async {
                self.webView.isHidden = true
                self.showLoadingView(progress: 0, stage: "Reconnecting after sleep…")
            }
            self.startAndLoad()
        }
    }

    func loadOdysseus() {
        webView.load(URLRequest(url: targetURL))
    }

    // MARK: llama-server

    func startLlamaServer() {
        let script = "\(odysseusDir)/llama-server.sh"
        guard FileManager.default.fileExists(atPath: script) else { return }
        stopLlamaServer()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script]
        p.environment = childEnv
        p.standardOutput = FileHandle.nullDevice
        p.standardError  = FileHandle.nullDevice
        try? p.run()
        llamaProcess = p
    }

    func stopLlamaServer() {
        if let p = llamaProcess, p.isRunning {
            p.terminate()
            let deadline = Date(timeIntervalSinceNow: 3)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            if p.isRunning { p.interrupt() }
            llamaProcess = nil
        }
        shell("/bin/zsh", ["-c",
            "for port in 8085 8086 8087 8088 8089 8090 8091 8092; do " +
            "pids=$(lsof -ti :$port -sTCP:LISTEN 2>/dev/null); " +
            "[ -n \"$pids\" ] && kill -TERM $pids 2>/dev/null; done"
        ], timeout: 5)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navFailCount = 0
        hideLoadingView()
        self.webView.isHidden = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        navFailCount += 1
        log("nav fail #\(navFailCount): \(error.localizedDescription)")
        if navFailCount >= 5 {
            navFailCount = 0
            self.webView.isHidden = true
            showError("Lost connection to Odysseus.")
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.loadOdysseus() }
        }
    }

    func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        navFailCount += 1
        log("nav fail #\(navFailCount): \(error.localizedDescription)")
        if navFailCount >= 5 {
            navFailCount = 0
            self.webView.isHidden = true
            showError("Lost connection to Odysseus.")
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.loadOdysseus() }
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { webView.load(action.request) }
        return nil
    }

    // MARK: File upload

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.begin { result in completionHandler(result == .OK ? panel.urls : nil) }
    }

    // MARK: JS dialogs

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = "Odysseus"; a.informativeText = message
        a.addButton(withTitle: "OK"); a.runModal(); completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = "Odysseus"; a.informativeText = message
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let a = NSAlert(); a.messageText = prompt
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = defaultText ?? ""
        a.accessoryView = input
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = input
        completionHandler(a.runModal() == .alertFirstButtonReturn ? input.stringValue : nil)
    }

    // MARK: Downloads

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        decisionHandler(action.shouldPerformDownload ? .download : .allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = suggestedFilename
        panel.begin { result in completionHandler(result == .OK ? panel.url : nil) }
    }

    func downloadDidFinish(_ download: WKDownload) {}
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {}

    // MARK: Menu

    func buildMenu() {
        let menu = NSMenu()

        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "About Odysseus", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(NSMenuItem(title: "Hide Odysseus", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Configure Odysseus…", action: #selector(openConfig), keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Odysseus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let editItem = NSMenuItem(); menu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit"); editItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "Undo",       action: Selector(("undo:")),             keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo",       action: Selector(("redo:")),             keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut",        action: #selector(NSText.cut(_:)),       keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy",       action: #selector(NSText.copy(_:)),      keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste",      action: #selector(NSText.paste(_:)),     keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        let viewItem = NSMenuItem(); menu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View"); viewItem.submenu = viewMenu
        viewMenu.addItem(NSMenuItem(title: "Reload", action: #selector(reloadPage), keyEquivalent: "r"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f"))

        let winItem = NSMenuItem(); menu.addItem(winItem)
        let winMenu = NSMenu(title: "Window"); winItem.submenu = winMenu
        winMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        winMenu.addItem(NSMenuItem(title: "Zoom",     action: #selector(NSWindow.zoom(_:)),        keyEquivalent: ""))
        winMenu.addItem(.separator())
        winMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))

        NSApp.mainMenu = menu
        NSApp.windowsMenu = winMenu
    }

    @objc func reloadPage() { loadOdysseus() }

    @objc func openConfig() {
        if configWindow == nil {
            let home = childEnv["HOME"] ?? NSHomeDirectory()
            configWindow = ModelConfigWindow(
                hfCache:      "\(home)/odysseus/data/huggingface/hub",
                configPath:   "\(home)/odysseus/llama-config.json",
                launcherPath: "\(home)/odysseus/llama-launcher.py",
                childEnv:     childEnv
            )
        }
        configWindow?.show()
    }

    // MARK: Quit

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ note: Notification) {
        stopLlamaServer()
        shell(dockerBin, ["compose", "-f", "\(odysseusDir)/docker-compose.yml", "down"], timeout: 30)
        shell(colimaBin, ["stop"], timeout: 20)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
