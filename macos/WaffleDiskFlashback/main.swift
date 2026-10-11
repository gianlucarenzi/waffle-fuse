// Waffle DiskFlashback for macOS – menu bar app for the DrawBridge/Waffle
// floppy reader, the macOS counterpart of scripts/waffle-diskflashback.py.
//
//   * insert a disk  -> mounted under ~/Floppy/<volume> (FUSE-T) and shown in
//                       the Finder
//   * eject          -> menu "Eject" (or eject it in the Finder); pending
//                       changes are written, then "the disk can be removed"
//   * take it out    -> if it was still mounted it is unmounted automatically
//   * .adf/.img/.ima -> "Open With > Waffle DiskFlashback" mounts the image as
//                       a virtual disk
//
// States (as in the Linux daemon):
//   noPort    no DrawBridge found, polling for the serial port
//   waiting   port open, waiting for a disk (waffle-fuse --wait-disk)
//   mounting  waffle-fuse reading the disk
//   mounted   disk mounted
//   ejecting  unmount requested, waiting for pending writes
//   remove    disk unmounted (or unreadable): waiting for it to be taken out
//   busy      copying the disk to an image file / writing an image to it

import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Paths and constants

let waffleBin: String = {
    if let p = Bundle.main.path(forAuxiliaryExecutable: "waffle-fuse") { return p }
    return "/usr/local/bin/waffle-fuse"
}()
let fuseTLibrary = "/usr/local/lib/libfuse3.4.dylib"
let fuseTSite = URL(string: "https://www.fuse-t.org")!
let mountDir = (NSHomeDirectory() as NSString).appendingPathComponent("Floppy")
let floppyImageSizes: Set<UInt64> = [901120, 1802240, 737280, 1474560]

// waffle-fuse exit codes
let EXIT_OK: Int32 = 0, EXIT_PORT: Int32 = 2, EXIT_NODISK: Int32 = 3, EXIT_UNKNOWN_FMT: Int32 = 4
let EXIT_DRIVE: Int32 = 5, EXIT_FILESYSTEM: Int32 = 6, EXIT_REMOVED: Int32 = 7
let EXIT_REMOVED_DIRTY: Int32 = 8, EXIT_WRITE_ERROR: Int32 = 9

// MARK: - Log

/// ~/Library/Logs/WaffleDiskFlashback.log (Console.app shows it too)
let logPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/WaffleDiskFlashback.log")
let logQueue = DispatchQueue(label: "log")
private let logDateFormat: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func log(_ message: String) {
    let line = "\(logDateFormat.string(from: Date())) \(message)\n"
    logQueue.async {
        guard let data = line.data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: logPath) {
            h.seekToEndOfFile()
            h.write(data)
            h.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: data)
        }
    }
}

/// Start a new log, keeping the previous one as .old
func rotateLog() {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? fm.removeItem(atPath: logPath + ".old")
    try? fm.moveItem(atPath: logPath, toPath: logPath + ".old")
}

// MARK: - Helpers

/// 'WAFFLE event=mounted mountpoint=/x y' -> ["event": "mounted", "mountpoint": "/x y"]
func parseEvent(_ line: String) -> [String: String]? {
    guard line.hasPrefix("WAFFLE ") else { return nil }
    var fields: [String: String] = [:]
    var rest = Substring(line.dropFirst(7))
    while !rest.isEmpty {
        guard let eq = rest.firstIndex(of: "=") else { break }
        let key = String(rest[..<eq])
        rest = rest[rest.index(after: eq)...]
        if key == "volume" || key == "mountpoint" {   // always last: the value may contain anything
            fields[key] = String(rest)
            break
        }
        if let sp = rest.firstIndex(of: " ") {
            fields[key] = String(rest[..<sp])
            rest = rest[rest.index(after: sp)...]
        } else {
            fields[key] = String(rest)
            rest = ""
        }
    }
    return fields
}

/// Run a command and wait (at most 'timeout' seconds); returns its exit status, -1 on failure.
@discardableResult
func runSync(_ path: String, _ args: [String], timeout: TimeInterval = 60) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(50_000) }
    if p.isRunning { p.terminate(); p.waitUntilExit(); return -1 }
    return p.terminationStatus
}

func unmount(_ path: String) -> Bool {
    return runSync("/sbin/umount", [path], timeout: 30) == 0
}

/// Is 'path' a mountpoint (on another device than its parent directory)?
func isMountpoint(_ path: String) -> Bool {
    var st = stat(), parent = stat()
    return stat(path, &st) == 0 && stat(path + "/..", &parent) == 0 && st.st_dev != parent.st_dev
}

func candidatePorts() -> [String] {
    let prefixes = ["cu.usbserial", "cu.usbmodem", "cu.wchusbserial", "cu.SLAB_USBtoUART"]
    let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
    return names.filter { n in prefixes.contains { n.hasPrefix($0) } }.sorted().map { "/dev/" + $0 }
}

func openInFinder(_ path: String) {
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
}

func notify(_ title: String, _ message: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = message
    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request) { error in
        guard error != nil else { return }
        // Notifications not allowed for the app: fall back to AppleScript
        let script = "on run argv\ndisplay notification (item 2 of argv) with title (item 1 of argv)\nend run"
        runSync("/usr/bin/osascript", ["-e", script, title, message], timeout: 10)
    }
}

// MARK: - A waffle-fuse child process

/// waffle-fuse with its stdout events and exit delivered on the main queue, in order.
final class Proc {
    let process = Process()
    private(set) var stderrTail: [String] = []
    var cancelled = false
    private let onEvent: (([String: String]) -> Void)?
    private let onExit: ((Int32) -> Void)?

    init(_ args: [String], onEvent: (([String: String]) -> Void)? = nil, onExit: ((Int32) -> Void)? = nil) {
        self.onEvent = onEvent
        self.onExit = onExit
        process.executableURL = URL(fileURLWithPath: waffleBin)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let name = args.first ?? ""
        log("run: waffle-fuse \(args.joined(separator: " "))")
        do {
            try process.run()
        } catch {
            log("cannot run \(waffleBin): \(error.localizedDescription)")
            DispatchQueue.main.async { self.onExit?(127) }
            return
        }
        Thread.detachNewThread { [self] in
            Proc.readLines(err.fileHandleForReading) { line in
                log("  [\(name)] \(line)")
                DispatchQueue.main.async { self.stderrTail = Array((self.stderrTail + [line]).suffix(5)) }
            }
        }
        Thread.detachNewThread { [self] in
            Proc.readLines(out.fileHandleForReading) { line in
                guard let ev = parseEvent(line) else { return }
                if ev["event"] != "track" { log("  [\(name)] \(line)") }
                DispatchQueue.main.async { if !self.cancelled { self.onEvent?(ev) } }
            }
            self.process.waitUntilExit()
            let code = self.process.terminationReason == .exit
                ? self.process.terminationStatus : 128 + self.process.terminationStatus
            log("  [\(name)] exit \(code)")
            DispatchQueue.main.async { if !self.cancelled { self.onExit?(code) } }
        }
    }

    private static func readLines(_ handle: FileHandle, _ line: (String) -> Void) {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 10) {
                let data = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                line(String(decoding: data, as: UTF8.self))
            }
        }
    }

    /// Stop a waiting helper (never used on a mounted driver)
    func cancel() {
        cancelled = true
        if process.isRunning { process.terminate() }
    }

    /// Wait (off the main queue) until the process has exited, at most 'timeout' seconds
    func waitExit(timeout: TimeInterval, then done: @escaping () -> Void) {
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(timeout)
            while self.process.isRunning && Date() < deadline { usleep(100_000) }
            DispatchQueue.main.async(execute: done)
        }
    }
}

// MARK: - The daemon

enum State { case noPort, waiting, mounting, mounted, ejecting, remove, busy }

struct Job {
    enum Kind { case dump, write }
    let kind: Kind
    let path: String
    var full = false            // write: erase and rewrite every track
    var remount = false
    var tmp = ""                // dump: the copy goes to a temporary file first
    var tracks = 0
    var bad = 0
    var written: Int?
    var cancelled = false
}

/// An image opened as a virtual disk ("Open With")
final class VirtualDisk {
    let proc: Proc
    var mountpoint: String?
    init(proc: Proc) { self.proc = proc }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var state = State.noPort
    private var port: String?
    private var proc: Proc?             // current waffle-fuse child
    private var driver: Proc?           // the mounted waffle-fuse (subset of proc)
    private var mountpoint: String?
    private var info = ""
    private var tooltip = ""
    private var volume = ""             // volume name / label of the current disk
    private var fsKind = ""             // "amiga" or "fat"
    private var job: Job?
    private var jobWindow: NSWindow?
    private var jobBar: NSProgressIndicator?
    private var jobStatus: NSTextField?
    private var images: [String: VirtualDisk] = [:]   // real path -> virtual disk
    private var quitting = false
    private var sigterm: DispatchSourceSignal?

    // MARK: Startup / quit

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("Waffle DiskFlashback \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") started, driver \(waffleBin)")
        guard FileManager.default.fileExists(atPath: fuseTLibrary) else {
            log("FUSE-T not installed (\(fuseTLibrary) missing)")
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "FUSE-T is not installed"
            alert.informativeText = "Waffle DiskFlashback mounts floppies with FUSE-T, free for "
                + "non-commercial use. Install it from fuse-t.org, then start Waffle DiskFlashback again."
            alert.addButton(withTitle: "Open fuse-t.org")
            alert.addButton(withTitle: "Quit")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(fuseTSite) }
            NSApp.terminate(nil)
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // SIGTERM (kill, launchd): quit cleanly like the Quit menu item
        signal(SIGTERM, SIG_IGN)
        sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm?.setEventHandler { [weak self] in self?.quit() }
        sigterm?.resume()

        cleanupStaleMounts()
        findPort()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateNow }
        quit()
        return .terminateLater
    }

    /// Unmount cleanly so pending writes reach the disk, then exit
    private func quit() {
        if quitting { return }
        quitting = true
        var waits: [Proc] = []
        if let d = driver, let mp = mountpoint {
            _ = unmount(mp)
            waits.append(d)
        } else if let p = proc {
            p.cancel()
            if state == .busy { waits.append(p) }    // waffle-fuse stops between two tracks
        }
        for disk in images.values {
            if let mp = disk.mountpoint { _ = unmount(mp) } else { disk.proc.process.terminate() }
            waits.append(disk.proc)
        }
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(60)
            while waits.contains(where: { $0.process.isRunning }) && Date() < deadline { usleep(100_000) }
            DispatchQueue.main.async {
                if let tmp = self.job?.tmp, !tmp.isEmpty { try? FileManager.default.removeItem(atPath: tmp) }
                log("quit")
                logQueue.sync {}        // write the last log lines
                NSApp.reply(toApplicationShouldTerminate: true)
                exit(0)
            }
        }
    }

    /// Remove mountpoints left behind by a crashed driver
    private func cleanupStaleMounts() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: mountDir) else { return }
        for name in names {
            let path = (mountDir as NSString).appendingPathComponent(name)
            var st = stat()
            if stat(path, &st) != 0 { runSync("/sbin/umount", ["-f", path], timeout: 10) }
            rmdir(path)     // only succeeds for empty, unmounted directories
        }
    }

    // MARK: UI

    private func setState(_ s: State, _ tip: String, _ icon: String) {
        if s != state || tip != tooltip { log("state: \(tip)") }
        state = s
        tooltip = tip
        guard let button = statusItem?.button else { return }
        button.toolTip = tip
        if let image = Bundle.main.image(forResource: "tray-" + icon) {
            image.size = NSSize(width: 18, height: 18)
            button.image = image
        } else {
            button.title = "💾"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, _ action: Selector?, enabled: Bool = true) {
            let mi = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            mi.target = self
            menu.addItem(mi)
        }
        item(info.isEmpty ? (tooltip.isEmpty ? "Waffle" : tooltip) : info, nil)
        menu.addItem(.separator())
        item("Open", #selector(menuOpen), enabled: state == .mounted)
        item("Eject", #selector(menuEject), enabled: state == .mounted)
        item("Mount again", #selector(menuRemount), enabled: state == .remove)
        let diskIn = state == .mounted || state == .remove
        item("Copy disk to image file…", #selector(menuDump), enabled: diskIn)
        item("Write image to disk…", #selector(menuWrite), enabled: diskIn)
        menu.addItem(.separator())
        if #available(macOS 13.0, *) {
            let mi = NSMenuItem(title: "Start at login", action: #selector(menuLogin), keyEquivalent: "")
            mi.target = self
            mi.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(mi)
        }
        item("Quit", #selector(menuQuit))
    }

    @objc private func menuOpen() { if let mp = mountpoint { openInFinder(mp) } }
    @objc private func menuEject() { eject() }
    @objc private func menuRemount() { remount() }
    @objc private func menuDump() { dumpAsk() }
    @objc private func menuWrite() { writeAsk() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    @available(macOS 13.0, *)
    @objc private func menuLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            notify("Start at login", "Could not change it: \(error.localizedDescription)")
        }
    }

    // MARK: Port discovery

    private func findPort() {
        setState(.noPort, "Waffle: looking for the DrawBridge…", "idle")
        info = ""
        DispatchQueue.global().async {
            for candidate in candidatePorts() {
                let code = runSync(waffleBin, ["--probe", candidate], timeout: 20)
                if code == 0 || code == 1 {             // answered: it is a DrawBridge
                    DispatchQueue.main.async { self.portFound(candidate) }
                    return
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if self.state == .noPort && !self.quitting { self.findPort() }
            }
        }
    }

    private func portFound(_ p: String) {
        guard state == .noPort, !quitting else { return }
        port = p
        waitDisk()
    }

    // MARK: Waiting for a disk

    private func waitDisk() {
        guard let p = port, !quitting else { return }
        setState(.waiting, "Waffle: insert a disk (\((p as NSString).lastPathComponent))", "idle")
        info = ""
        proc = Proc(["--wait-disk", p], onExit: { [weak self] code in
            guard let self = self else { return }
            self.proc = nil
            if code == 0 {
                self.mount()
            } else {
                // Port gone or busy (e.g. WaffleCopyPRO is using it): look again later
                self.port = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if self.state == .waiting { self.findPort() }
                }
            }
        })
    }

    // MARK: Mounting

    private func mount() {
        guard let p = port, !quitting else { return }
        setState(.mounting, "Waffle: reading disk…", "mounting")
        let d = Proc([p, "--automount", mountDir, "-f"],
                     onEvent: { [weak self] ev in self?.driverEvent(ev) },
                     onExit: { [weak self] code in self?.driverExit(code) })
        proc = d
        driver = d
    }

    private func driverEvent(_ ev: [String: String]) {
        switch ev["event"] {
        case "detected":
            volume = ev["volume"] ?? ""
            fsKind = ev["format"] ?? ""
            let kind = fsKind == "amiga" ? "Amiga" : "PC"
            let ro = ev["readonly"] == "1" ? ", read-only" : ""
            info = "\(volume.isEmpty ? "unnamed" : volume) – \(kind) \(ev["fs"] ?? "") \(ev["density"] ?? "")\(ro)"
        case "mounted":
            mountpoint = ev["mountpoint"]
            setState(.mounted, "Waffle: \(info)", "mounted")
            notify("Disk inserted", info)
            if let mp = mountpoint { openInFinder(mp) }
        case "write-error":
            notify("Disk write error", "Some changes could not be written. Do not remove the disk; "
                + "check that it is not write-protected or damaged.")
        default:
            break
        }
    }

    private func driverExit(_ code: Int32) {
        let stderrTail = driver?.stderrTail ?? []
        proc = nil
        driver = nil
        mountpoint = nil
        if quitting { return }
        if code == EXIT_OK && job != nil {
            startJob()                      // unmounted to free the port for a disk job
        } else if code == EXIT_OK {
            notify("Disk ejected", "All changes written: the disk can be removed.")
            waitRemoval()
        } else if code == EXIT_REMOVED {
            notify("Disk removed", info.isEmpty ? "The disk was unmounted." : info)
            waitDisk()
        } else if code == EXIT_REMOVED_DIRTY {
            notify("Disk removed too early",
                   "The disk was taken out while changes were still being written: they are lost.")
            waitDisk()
        } else if code == EXIT_NODISK {
            waitDisk()
        } else if code == EXIT_PORT {
            port = nil
            findPort()
        } else {
            let messages: [Int32: String] = [
                EXIT_UNKNOWN_FMT: "Not a DOS disk: unformatted, NDOS (game) or copy-protected.",
                EXIT_DRIVE: "Cannot read track 0: the disk may be damaged.",
                EXIT_FILESYSTEM: "The filesystem on the disk is not valid.",
                EXIT_WRITE_ERROR: "Some changes could not be written to the disk.",
            ]
            let detail = messages[code] ?? (stderrTail.isEmpty ? "error \(code)" : stderrTail.joined(separator: " "))
            notify("Cannot use this disk", detail)
            info = detail
            waitRemoval()
        }
    }

    // MARK: Eject

    private func eject() {
        guard state == .mounted, let mp = mountpoint else { return }
        guard unmount(mp) else {
            notify("Disk in use", "Close the windows and programs that are using the disk, then eject again.")
            return
        }
        // waffle-fuse now writes any pending changes and exits (see driverExit)
        setState(.ejecting, "Waffle: writing changes, do not remove the disk…", "mounting")
    }

    // MARK: After eject: wait for the disk to be taken out

    private func waitRemoval() {
        guard let p = port, !quitting else { findPort(); return }
        setState(.remove, info.isEmpty ? "Waffle: remove the disk" : "Waffle: remove the disk (\(info))", "idle")
        proc = Proc(["--wait-removal", p], onExit: { [weak self] code in
            guard let self = self else { return }
            self.proc = nil
            if code == 0 {
                self.waitDisk()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if self.state == .remove { self.port = nil; self.findPort() }
                }
            }
        })
    }

    /// Stop a waiting helper (--wait-removal / --wait-disk) to free the port
    private func stopHelper(then done: @escaping () -> Void) {
        guard let p = proc, p !== driver else { done(); return }
        p.cancel()
        proc = nil
        p.waitExit(timeout: 5) {
            if p.process.isRunning { kill(p.process.processIdentifier, SIGKILL) }
            done()
        }
    }

    private func remount() {
        guard state == .remove else { return }
        stopHelper { self.mount() }
    }

    // MARK: Disk jobs: copy the disk to an image file / write an image to the disk

    private func startFolder() -> URL {
        let folder = (NSHomeDirectory() as NSString).appendingPathComponent("WaffleFolder")
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue {
            return URL(fileURLWithPath: folder)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    private func dumpAsk() {
        guard state == .mounted || state == .remove else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "Copy disk to image file"
        panel.prompt = "Copy"
        panel.directoryURL = startFolder()
        let ext = fsKind == "fat" ? "img" : "adf"
        panel.nameFieldStringValue = (volume.isEmpty ? (fsKind == "fat" ? "floppy" : "disk") : volume) + "." + ext
        panel.allowedContentTypes = ["adf", "img", "ima", "scp"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = false
        let label = NSTextField(wrappingLabelWithString:
            ".adf / .img: copy of the sectors (DOS and NDOS disks)\n.scp: raw magnetic flux, also for copy-protected disks")
        label.frame = NSRect(x: 0, y: 0, width: 420, height: 36)
        panel.accessoryView = label
        guard panel.runModal() == .OK, let url = panel.url else { return }
        queueJob(Job(kind: .dump, path: url.path))
    }

    private func writeAsk() {
        guard state == .mounted || state == .remove else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Write image to disk"
        panel.prompt = "Next"
        panel.allowedContentTypes = ["adf", "img", "ima"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        // Propose the image that is open as a virtual disk
        if let open = images.keys.first {
            panel.directoryURL = URL(fileURLWithPath: (open as NSString).deletingLastPathComponent)
        } else {
            panel.directoryURL = startFolder()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.resolvingSymlinksInPath().path
        let name = url.lastPathComponent
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? nil
        guard let s = size, floppyImageSizes.contains(s) else {
            notify("Cannot write image", "\(name) is not an 880K/1.76M ADF or a 720K/1.44M PC floppy image.")
            return
        }

        // Confirm: everything on the real disk is overwritten
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Write \(name) to \(volume.isEmpty ? "the disk in the drive" : volume)?"
        alert.informativeText = "Everything on the disk in the drive will be overwritten. "
            + "Only the tracks that differ are rewritten, each one verified."
        let full = NSButton(checkboxWithTitle: "Erase and rewrite every track (slower, like formatting)",
                            target: nil, action: nil)
        alert.accessoryView = full
        alert.addButton(withTitle: "Write")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var job = Job(kind: .write, path: path)
        job.full = full.state == .on

        // Close the image if it is open as a virtual disk, so every change is in the file
        if let disk = images[path], let mp = disk.mountpoint {
            guard unmount(mp) else {
                notify("Image in use", "Close the windows using the virtual disk \((mp as NSString).lastPathComponent), then try again.")
                return
            }
            disk.proc.waitExit(timeout: 30) { self.queueJob(job) }
            return
        }
        queueJob(job)
    }

    /// Free the port (unmount the real disk or stop the waiting helper), then run the job
    private func queueJob(_ newJob: Job) {
        guard state == .mounted || state == .remove else { return }    // the disk went away meanwhile
        var j = newJob
        // Remount afterwards: the same disk after a dump, the new content after a write
        j.remount = state == .mounted || j.kind == .write
        job = j
        if state == .mounted, let mp = mountpoint {
            guard unmount(mp) else {
                job = nil
                notify("Disk in use", "Close the windows and programs using the disk, then try again.")
                return
            }
            setState(.ejecting, "Waffle: writing pending changes first…", "mounting")
            // driverExit starts the job once the driver has released the port
        } else {
            stopHelper { self.startJob() }
        }
    }

    private func startJob() {
        guard var j = job, let p = port else { return }
        let name = (j.path as NSString).lastPathComponent
        j.tracks = 0
        var args: [String]
        if j.kind == .dump {
            setState(.busy, "Waffle: copying the disk to \(name)…", "mounting")
            showJobWindow("Copying disk", "Copying the disk to\n\(j.path)")
            // Into a temporary file: an existing file is only replaced by a finished copy
            let ext = (j.path as NSString).pathExtension
            j.tmp = j.path + ".part" + (ext.isEmpty ? "" : "." + ext)
            args = ["--dump", p, j.tmp]
        } else {
            setState(.busy, "Waffle: writing \(name) to the disk…", "mounting")
            showJobWindow("Writing image to disk", "Writing\n\(j.path)\nto the disk in the drive")
            args = ["--write-image", p, j.path, "--yes"] + (j.full ? ["--full"] : [])
        }
        job = j
        proc = Proc(args, onEvent: { [weak self] ev in self?.jobEvent(ev) },
                    onExit: { [weak self] code in self?.jobExit(code) })
    }

    private func showJobWindow(_ title: String, _ text: String) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 150),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.title = title
        win.level = .floating
        win.isReleasedWhenClosed = false
        let label = NSTextField(wrappingLabelWithString: text)
        label.frame = NSRect(x: 20, y: 86, width: 400, height: 48)
        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 60, width: 400, height: 20))
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 160
        let status = NSTextField(labelWithString: "")
        status.frame = NSRect(x: 20, y: 18, width: 300, height: 20)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(jobCancel))
        cancel.frame = NSRect(x: 330, y: 12, width: 90, height: 30)
        for v in [label, bar, status, cancel] { win.contentView?.addSubview(v) }
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        jobWindow = win
        jobBar = bar
        jobStatus = status
    }

    private func jobEvent(_ ev: [String: String]) {
        guard job != nil else { return }
        switch ev["event"] {
        case "track":
            job!.tracks += 1
            jobBar?.doubleValue = Double(min(job!.tracks, 160))
            let st = ev["status"] ?? ""
            jobStatus?.stringValue = "cylinder \(ev["cylinder"] ?? "")  head \(ev["head"] ?? "")"
                + (["unchanged", "failed", "bad"].contains(st) ? "  (\(st))" : "")
        case "dumped":
            job!.bad = Int(ev["bad"] ?? "0") ?? 0
        case "written":
            job!.written = Int(ev["tracks"] ?? "")
        default:
            break
        }
    }

    @objc private func jobCancel() {
        if let p = proc, job != nil, state == .busy {
            job!.cancelled = true
            p.process.terminate()           // waffle-fuse stops between two tracks
        }
    }

    private func jobExit(_ code: Int32) {
        guard let j = job else { return }
        job = nil
        let stderrTail = proc?.stderrTail ?? []
        proc = nil
        jobWindow?.orderOut(nil)
        jobWindow = nil
        let name = (j.path as NSString).lastPathComponent
        let fm = FileManager.default
        let lastError = stderrTail.last?.replacingOccurrences(of: "waffle-fuse: ", with: "") ?? "error \(code)"

        if j.kind == .dump {
            if fm.fileExists(atPath: j.tmp) && (code == EXIT_OK || code == EXIT_DRIVE) && !j.cancelled {
                _ = try? fm.removeItem(atPath: j.path)
                _ = try? fm.moveItem(atPath: j.tmp, toPath: j.path)
            } else {
                try? fm.removeItem(atPath: j.tmp)   // never leave a half-written image around
            }
            if j.cancelled {
                notify("Copy cancelled", name)
            } else if code == EXIT_OK {
                notify("Disk copied", j.path)
            } else if code == EXIT_DRIVE && j.bad > 0 {
                notify("Disk copied with errors", "\(j.path)\n\(j.bad) sectors could not be read (saved as zeros).")
            } else if code == EXIT_DRIVE && fm.fileExists(atPath: j.path) {
                notify("Disk copied with errors", "\(j.path)\nSome tracks had read problems.")
            } else {
                notify("Copy failed", "\(name): \(lastError)")
            }
        } else {
            if j.cancelled {
                notify("Write stopped", "The disk now holds part of the image only.")
            } else if code == EXIT_OK {
                notify("Image written", "\(name) written to the disk"
                    + (j.written.map { " (\($0) tracks rewritten and verified)." } ?? "."))
            } else {
                notify("Write failed", "\(name): \(lastError)")
            }
        }
        if quitting { return }
        if j.remount && code != EXIT_NODISK { mount() } else { waitRemoval() }
    }

    // MARK: Floppy images as virtual disks ("Open With")

    func application(_ application: NSApplication, open urls: [URL]) {
        log("open: \(urls.map { $0.path }.joined(separator: ", "))")
        for url in urls { openImage(url.resolvingSymlinksInPath().path) }
    }

    private func openImage(_ path: String) {
        if let disk = images[path] {
            if let mp = disk.mountpoint { openInFinder(mp) }   // already open: just show it
            return
        }
        let name = (path as NSString).lastPathComponent
        var disk: VirtualDisk!
        let p = Proc(["--image", path, "--automount", mountDir, "-f"],
                     onEvent: { ev in
                         if ev["event"] == "mounted", let mp = ev["mountpoint"] {
                             disk.mountpoint = mp
                             openInFinder(mp)
                         }
                     },
                     onExit: { [weak self] code in
                         self?.images[path] = nil
                         if code != EXIT_OK && disk.mountpoint == nil {
                             let reason: String
                             switch code {
                             case EXIT_UNKNOWN_FMT: reason = "Not an AmigaDOS or FAT image (NDOS game, copy-protected or not a floppy)."
                             case EXIT_FILESYSTEM: reason = "The filesystem in the image is not valid."
                             default: reason = disk.proc.stderrTail.last ?? "error \(code)"
                             }
                             notify("Cannot open \(name)", reason)
                         }
                     })
        disk = VirtualDisk(proc: p)
        images[path] = disk
    }
}

// MARK: - main

let app = NSApplication.shared
// One instance: a second launch (e.g. "Open With" while running) goes to the first
if let bundleID = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
    exit(0)
}
rotateLog()
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
