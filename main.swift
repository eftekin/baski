// baski: menu bar print progress for a Bambu Lab printer, with a camera popover.
// printers are found via their ssdp broadcast (udp 2021), status comes from local mqtt (8883),
// video comes from Bambu Studio's cameratools/bambu_source and is decoded with VideoToolbox.

import AppKit
import AVFoundation
import CryptoKit
import Network
import SwiftUI

let studioDir = NSHomeDirectory() + "/Library/Application Support/BambuStudio"
let defaults = UserDefaults.standard
let debug = ProcessInfo.processInfo.environment["BASKI_DEBUG"] != nil

func log(_ s: String) { if debug { FileHandle.standardError.write(Data("[baski] \(s)\n".utf8)) } }

// MARK: printers

struct Printer: Hashable {
    var serial: String
    var ip: String
    var name: String
    var model: String

    static let models = ["BL-P001": "X1 Carbon", "BL-P002": "X1", "C13": "X1E", "C11": "P1P", "C12": "P1S",
                         "N1": "A1 mini", "N2S": "A1", "N7": "P2S", "O1D": "H2D", "O1S": "H2S"]
    var modelName: String { Printer.models[model] ?? model }
}

func studioAccessCodes() -> [String: String] {
    guard let d = FileManager.default.contents(atPath: studioDir + "/BambuStudio.conf"),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return j["access_code"] as? [String: String] ?? [:]
}

func accessCode(_ serial: String) -> String? {
    defaults.string(forKey: "code.\(serial)") ?? studioAccessCodes()[serial]
}

/// listens for the NOTIFY packets Bambu printers broadcast on udp 2021
final class Discovery {
    var onFound: ((Printer) -> Void)?

    func start() {
        Thread.detachNewThread { [weak self] in
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(2021).bigEndian
            addr.sin_addr.s_addr = INADDR_ANY
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard ok == 0 else { log("ssdp bind failed"); return }
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = recv(fd, &buf, buf.count, 0)
                guard n > 0, let text = String(bytes: buf[0 ..< n], encoding: .utf8),
                      text.contains("bambulab-com:device:3dprinter") else { continue }
                var h: [String: String] = [:]
                for line in text.split(separator: "\r\n") {
                    guard let c = line.firstIndex(of: ":") else { continue }
                    h[line[..<c].lowercased()] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
                }
                guard let ip = h["location"], let sn = h["usn"] else { continue }
                let p = Printer(serial: sn, ip: ip, name: h["devname.bambu.com"] ?? sn,
                                model: h["devmodel.bambu.com"] ?? "")
                DispatchQueue.main.async { self?.onFound?(p) }
            }
        }
    }
}

// MARK: minimal mqtt 3.1.1 client (qos 0 only)

final class MQTT {
    var onReport: (([String: Any]) -> Void)?
    var onState: ((Bool) -> Void)?
    var onCertChanged: (() -> Void)?
    private var target: (ip: String, serial: String)?
    private var conn: NWConnection?
    private var buf = Data()
    private var ping: Timer?
    private var retryTimer: Timer?
    private var lastRx = Date()
    private let q = DispatchQueue(label: "mqtt")

    func connect(ip: String, serial: String) {
        target = (ip, serial)
        retryTimer?.invalidate()
        q.async { self.open() }
    }

    private func open() {
        conn?.stateUpdateHandler = nil
        conn?.cancel()
        guard let (ip, serial) = target, let code = accessCode(serial) else { return }
        let tls = NWProtocolTLS.Options()
        // the printer's certificate is self-signed: remember it on first use and refuse a different one later
        let pinKey = "cert.\(serial)"
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, done in
            let t = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let cert = (SecTrustCopyCertificateChain(t) as? [SecCertificate])?.first else { done(false); return }
            let fp = SHA256.hash(data: SecCertificateCopyData(cert) as Data).map { String(format: "%02x", $0) }.joined()
            guard let pinned = defaults.string(forKey: pinKey) else { defaults.set(fp, forKey: pinKey); done(true); return }
            if pinned != fp {
                log("mqtt: printer certificate changed, refusing (Add Printer resets it)")
                DispatchQueue.main.async { self.onCertChanged?() }
            }
            done(pinned == fp)
        }, q)
        let c = NWConnection(host: .init(ip), port: 8883, using: NWParameters(tls: tls))
        conn = c
        buf = Data()
        c.stateUpdateHandler = { [weak self, weak c] st in
            guard let self, let c, c === self.conn else { return }
            switch st {
            case .ready:
                self.send(self.connectPacket(user: "bblp", pass: code))
                self.receive(c)
            case .failed, .cancelled:
                self.lost()
            default: break
            }
        }
        c.start(queue: q)
    }

    private func lost() {
        conn?.stateUpdateHandler = nil
        conn = nil
        DispatchQueue.main.async {
            self.onState?(false)
            self.ping?.invalidate()
            self.retryTimer?.invalidate()
            self.retryTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [q = self.q] _ in
                q.async { [weak self] in self?.open() }
            }
        }
    }

    private func send(_ d: Data) { conn?.send(content: d, completion: .contentProcessed { _ in }) }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self, c === self.conn else { return }
            if let data { self.ingest(data) }
            if done || err != nil { c.cancel(); return }
            self.receive(c)
        }
    }

    /// appends bytes from the socket and handles every complete packet
    func ingest(_ d: Data) {
        lastRx = Date()
        buf.append(d)
        parse()
    }

    private func parse() {
        while buf.count >= 2 {
            let b = [UInt8](buf.prefix(5))
            var len = 0, mul = 1, i = 1
            while true {
                guard i < b.count else { return }
                len += Int(b[i] & 0x7f) * mul
                if b[i] & 0x80 == 0 { break }
                mul *= 128; i += 1
            }
            let total = 1 + i + len
            guard buf.count >= total else { return }
            let pkt = Data(buf.subdata(in: buf.startIndex + 1 + i ..< buf.startIndex + total))
            buf.removeFirst(total)
            switch b[0] >> 4 {
            case 2: // connack
                let ok = pkt.count >= 2 && pkt[pkt.startIndex + 1] == 0
                DispatchQueue.main.async { self.onState?(ok) }
                guard ok, let serial = target?.serial else { return }
                send(subscribePacket("device/\(serial)/report"))
                send(publishPacket("device/\(serial)/request", #"{"pushing":{"sequence_id":"0","command":"pushall"}}"#))
                DispatchQueue.main.async { [weak self] in
                    self?.ping?.invalidate()
                    self?.ping = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                        self?.q.async {
                            guard let self else { return }
                            // a printer that lost power never closes the socket; treat 90 s of silence as a drop
                            if Date().timeIntervalSince(self.lastRx) > 90 { self.conn?.cancel(); return }
                            self.send(Data([0xC0, 0x00]))
                        }
                    }
                }
            case 3: // publish
                guard pkt.count >= 2 else { continue }
                let tl = Int(pkt[pkt.startIndex]) << 8 | Int(pkt[pkt.startIndex + 1])
                var off = 2 + tl
                if (b[0] >> 1) & 3 > 0 { off += 2 }
                guard off <= pkt.count else { continue }
                let payload = pkt.subdata(in: pkt.startIndex + off ..< pkt.endIndex)
                if let j = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                    DispatchQueue.main.async { self.onReport?(j) }
                }
            default: break
            }
        }
    }

    private func encLen(_ n: Int) -> Data {
        var n = n, out = Data()
        repeat {
            var byte = UInt8(n % 128); n /= 128
            if n > 0 { byte |= 0x80 }
            out.append(byte)
        } while n > 0
        return out
    }
    private func str(_ s: String) -> Data {
        let u = Data(s.utf8); return Data([UInt8(u.count >> 8), UInt8(u.count & 0xff)]) + u
    }
    private func connectPacket(user: String, pass: String) -> Data {
        let body = str("MQTT") + Data([4, 0xC2, 0, 60]) + str("baski-\(UUID().uuidString.prefix(8))") + str(user) + str(pass)
        return Data([0x10]) + encLen(body.count) + body
    }
    private func subscribePacket(_ topic: String) -> Data {
        let body = Data([0, 1]) + str(topic) + Data([0])
        return Data([0x82]) + encLen(body.count) + body
    }
    func publishPacket(_ topic: String, _ msg: String) -> Data {
        let body = str(topic) + Data(msg.utf8)
        return Data([0x30]) + encLen(body.count) + body
    }
}

// MARK: state

final class Model: ObservableObject {
    @Published var printers: [String: Printer] = [:]
    @Published var selected: String? = defaults.string(forKey: "selected")
    @Published var online = false
    @Published var report: [String: Any] = [:]
    @Published var camera: CameraState = .idle
    @Published var certChanged = false

    enum CameraState: Equatable { case idle, connecting(String), live, failed(String) }

    var printer: Printer? { selected.flatMap { printers[$0] } }
    var state: String { report["gcode_state"] as? String ?? "" }
    var remaining: Int { (report["mc_remaining_time"] as? NSNumber)?.intValue ?? 0 }
    var percent: Int { (report["mc_percent"] as? NSNumber)?.intValue ?? 0 }
    var layer: Int { (report["layer_num"] as? NSNumber)?.intValue ?? 0 }
    var totalLayers: Int { (report["total_layer_num"] as? NSNumber)?.intValue ?? 0 }
    var job: String {
        let s = report["subtask_name"] as? String ?? ""
        return s.isEmpty ? (report["gcode_file"] as? String ?? "") : s
    }
    var rtspURL: String? {
        guard let u = (report["ipcam"] as? [String: Any])?["rtsp_url"] as? String, u.hasPrefix("rtsp") else { return nil }
        return u
    }
    var active: Bool { ["RUNNING", "PAUSE", "PREPARE", "SLICING"].contains(state) }

    var stateLabel: String {
        guard online else { return "Offline" }
        switch state {
        case "RUNNING": return "Printing"
        case "PAUSE": return "Paused"
        case "PREPARE", "SLICING": return "Preparing"
        case "FINISH": return "Finished"
        case "FAILED": return "Failed"
        case "": return "Connecting…"
        default: return "Idle"
        }
    }

    static func duration(_ m: Int) -> String { m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m) min" }

    var eta: String {
        let f = DateFormatter(); f.timeStyle = .short
        return f.string(from: Date().addingTimeInterval(TimeInterval(remaining * 60)))
    }
}

// MARK: camera

final class VideoView: NSView {
    let video = AVSampleBufferDisplayLayer()
    let still = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        for l in [video, still] as [CALayer] {
            l.frame = bounds
            l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.addSublayer(l)
        }
        video.videoGravity = .resizeAspectFill
        still.contentsGravity = .resizeAspectFill
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// runs bambu_source for one url and turns its stdout (annex-b h264, or jpeg on the port 6000 tunnel) into frames
final class Camera {
    let view = VideoView(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
    var onState: ((Model.CameraState) -> Void)?

    private var proc: Process?
    private var keepalive: Pipe?
    private var queue: [(String, String)] = []
    private var pending = Data()
    private var sps: Data?, pps: Data?
    private var fmt: CMVideoFormatDescription?
    private var frame: [Data] = []
    private(set) var frames = 0
    private let q = DispatchQueue(label: "camera")
    private let junk = Data("BambuTunnel::".utf8)

    /// candidates are (label, bambu_source url) tried in order until one produces frames
    func start(_ candidates: [(String, String)]) {
        stop()
        queue = candidates
        next()
    }

    func stop() {
        queue = []
        let p = proc; proc = nil
        p?.terminate()
        try? keepalive?.fileHandleForWriting.close(); keepalive = nil
        view.video.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        view.still.contents = nil
    }

    private func next() {
        guard !queue.isEmpty else {
            onState?(.failed("Camera unavailable. Turn on LAN Only Liveview on the printer (Settings → Network)."))
            return
        }
        let (label, url) = queue.removeFirst()
        let tools = studioDir + "/cameratools"
        guard FileManager.default.isExecutableFile(atPath: tools + "/bambu_source") else {
            onState?(.failed("Bambu Studio's camera tools are missing. In Studio, open the printer's live view and turn on the virtual camera once to install them."))
            return
        }
        onState?(.connecting(label))
        log("camera: trying \(label)")
        q.sync { pending = Data(); frame = []; sps = nil; pps = nil; fmt = nil; frames = 0 }

        // a small shell guard owns bambu_source and kills it once our stdin pipe closes,
        // so the camera never outlives the app (even on a crash or kill -9)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // DYLD_* is stripped when launching the SIP-protected /bin/sh, so the library path is passed as $2
        p.arguments = ["-c", #"exec 3<&0; trap 'kill $c 2>/dev/null; exit 0' TERM INT; DYLD_LIBRARY_PATH="$2" "$0" "$1" 3<&- & c=$!; (cat <&3 >/dev/null; kill $c 2>/dev/null) >/dev/null & wait $c"#,
                       tools + "/bambu_source", url, studioDir + "/plugins"]
        let out = Pipe(), keepalive = Pipe()
        p.standardInput = keepalive
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        self.keepalive = keepalive
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self, !d.isEmpty else { h.readabilityHandler = nil; return }
            self.q.async { self.feed(d) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.proc === p else { return }
                self.proc = nil
                try? self.keepalive?.fileHandleForWriting.close(); self.keepalive = nil
                let got = self.q.sync { self.frames > 0 }
                if got { self.onState?(.failed("Stream ended.")) } else { self.next() }
            }
        }
        do { try p.run(); proc = p } catch { next(); return }
        // a tunnel that never delivers a frame keeps retrying forever, so move on after a while
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.proc === p, self.q.sync(execute: { self.frames == 0 }) else { return }
            log("camera: \(label) timed out")
            p.terminate()
        }
    }

    // MARK: stream parsing (runs on q)

    func feed(_ d: Data) {
        pending.append(d)
        // bambu_source occasionally prints "BambuTunnel::GetMsg(n)\n" into stdout
        while let r = pending.range(of: junk) {
            guard let nl = pending[r.upperBound...].firstIndex(of: 0x0A) else { break }
            pending.removeSubrange(r.lowerBound ... nl)
        }
        let bytes = [UInt8](pending)
        if let soi = jpegStart(bytes) { feedJPEG(bytes, from: soi); return }

        var starts: [(Int, Int)] = [] // (start code index, payload index)
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 { starts.append((i, i + 3)); i += 3; continue }
                if bytes[i + 2] == 0, bytes[i + 3] == 1 { starts.append((i, i + 4)); i += 4; continue }
            }
            i += 1
        }
        guard starts.count >= 2 else { return }
        for k in 0 ..< starts.count - 1 {
            nal(Data(bytes[starts[k].1 ..< starts[k + 1].0]))
        }
        pending = Data(bytes[starts.last!.0...])
    }

    private func jpegStart(_ b: [UInt8]) -> Int? {
        guard sps == nil, b.count > 3 else { return nil }
        for i in 0 ..< min(b.count - 2, 64) where b[i] == 0xFF && b[i + 1] == 0xD8 && b[i + 2] == 0xFF { return i }
        return nil
    }

    private func feedJPEG(_ b: [UInt8], from soi: Int) {
        var start = soi, i = soi + 2
        while i + 1 < b.count {
            if b[i] == 0xFF && b[i + 1] == 0xD9 {
                let jpg = Data(b[start ... i + 1])
                if let src = CGImageSourceCreateWithData(jpg as CFData, nil),
                   let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                    shown()
                    DispatchQueue.main.async { [weak self] in self?.view.still.contents = img }
                }
                // several pictures can arrive in one read; keep going so the view never falls behind
                guard let next = stride(from: i + 2, to: b.count - 1, by: 1).first(where: { b[$0] == 0xFF && b[$0 + 1] == 0xD8 }) else {
                    pending = Data(); return
                }
                start = next; i = next + 2
                continue
            }
            i += 1
        }
        pending = Data(b[start...])
    }

    private func nal(_ n: Data) {
        guard let h = n.first else { return }
        switch h & 0x1f {
        case 7: flush(); if sps != n { sps = n; fmt = nil }
        case 8: flush(); if pps != n { pps = n; fmt = nil }
        case 9: flush()
        case 1, 5:
            if n.count > 1, n[n.startIndex + 1] & 0x80 != 0 { flush() } // first_mb_in_slice == 0
            frame.append(n)
        default: break
        }
    }

    private func flush() {
        defer { frame = [] }
        guard !frame.isEmpty, let sps, let pps else { return }
        if fmt == nil {
            fmt = sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
                let ptrs = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                var f: CMVideoFormatDescription?
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: ptrs,
                    parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4, formatDescriptionOut: &f)
                return f
            }}
        }
        guard let fmt else { return }
        var avcc = Data()
        for n in frame {
            var len = UInt32(n.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4)); avcc.append(n)
        }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: avcc.count,
                                           blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                           dataLength: avcc.count, flags: 0, blockBufferOut: &block)
        guard let block else { return }
        avcc.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                 offsetIntoDestination: 0, dataLength: avcc.count) }
        var sample: CMSampleBuffer?
        var size = avcc.count
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: 1,
                                  sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &sample)
        guard let sample else { return }
        if let att = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            att.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        shown()
        DispatchQueue.main.async { [weak self] in
            guard let r = self?.view.video.sampleBufferRenderer else { return }
            if r.status == .failed { r.flush() }
            r.enqueue(sample)
        }
    }

    private func shown() {
        frames += 1
        if frames == 1 { DispatchQueue.main.async { self.onState?(.live) } }
        if frames % 300 == 0 { log("camera: \(frames) frames") }
    }
}

/// bambu_source urls to try for a printer, best first (formats as used by Bambu Studio's MediaPlayCtrl)
func cameraCandidates(_ p: Printer, rtsp: String?) -> [(String, String)] {
    var out: [(String, String)] = []
    let code = accessCode(p.serial) ?? ""
    let tail = "&device=\(p.serial)&dev_ver=00.00.00.00&cli_ver=02.00.00.00"
    if let rtsp, let u = URL(string: rtsp) {
        let proto = u.scheme ?? "rtsps"
        out.append(("LAN (\(proto.uppercased()))",
                    "bambu:///\(proto)___bblp:\(code)@\(p.ip)\(u.path)?proto=\(proto)\(tail)"))
    }
    if let saved = try? String(contentsOfFile: studioDir + "/cameratools/url.txt", encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), saved.contains("device=\(p.serial)") {
        out.append(("Bambu Studio link", saved))
    }
    out.append(("LAN (port 6000)", "bambu:///local/\(p.ip).?port=6000&user=bblp&passwd=\(code)\(tail)"))
    return out
}

// MARK: popover ui

struct CameraSurface: NSViewRepresentable {
    let view: VideoView
    func makeNSView(context: Context) -> VideoView { view }
    func updateNSView(_ v: VideoView, context: Context) {}
}

struct Panel: View {
    @ObservedObject var m: Model
    let camera: VideoView
    #if DEBUG
    var preview: NSImage? = nil
    #endif
    var choose: (String) -> Void
    var retryCamera: () -> Void
    var addPrinter: () -> Void = {}

    var tint: Color {
        switch m.state {
        case "PAUSE": return .orange
        case "FAILED": return .red
        case "FINISH": return .green
        default: return .accentColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                #if DEBUG
                if let preview { Image(nsImage: preview).resizable().scaledToFill() } else { CameraSurface(view: camera) }
                #else
                CameraSurface(view: camera)
                #endif
                cameraOverlay
            }
            // the embedded NSView reports no size of its own, so give the box the full width and a 16:9 height
            .frame(maxWidth: .infinity)
            .frame(height: (340 - 28) * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)))

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.active || m.state == "FINISH" ? (m.job.isEmpty ? "Untitled" : m.job) : m.stateLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(m.certChanged ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if m.active || m.state == "FINISH" {
                    Text("\(m.state == "FINISH" ? 100 : m.percent)%")
                        .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                }
            }

            if m.active || m.state == "FINISH" {
                VStack(spacing: 6) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(tint)
                                .frame(width: max(6, g.size.width * CGFloat(m.state == "FINISH" ? 100 : m.percent) / 100))
                        }
                    }
                    .frame(height: 6)
                    .animation(.easeOut(duration: 0.4), value: m.percent)
                    if m.active {
                        HStack {
                            Label("\(Model.duration(m.remaining)) left", systemImage: "hourglass")
                            Spacer()
                            Label("Done at \(m.eta)", systemImage: "flag.checkered")
                        }
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                    }
                }
            }

            Divider()

            HStack(spacing: 6) {
                Circle().fill(m.online ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(m.printer.map { "\($0.name) · \($0.modelName)" }
                     ?? (m.printers.isEmpty ? "Looking for printers…" : "Found a printer, but no access code. Use ⋯ → Add Printer."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    let list = m.printers.values.sorted { $0.name < $1.name }
                    if list.count > 1 {
                        ForEach(list, id: \.serial) { p in
                            Button { choose(p.serial) } label: {
                                if p.serial == m.selected { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                            }
                        }
                        Divider()
                    }
                    Button("Add Printer…", action: addPrinter)
                    Divider()
                    Button("Quit baski") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                #if DEBUG
                // ImageRenderer can't draw a Menu, so snapshots show a plain icon
                .opacity(preview == nil ? 1 : 0)
                .overlay { if preview != nil { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) } }
                #endif
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    var subtitle: String {
        var parts: [String] = []
        if m.active || m.state == "FINISH" { parts.append(m.stateLabel) }
        if m.totalLayers > 0 && m.active { parts.append("Layer \(m.layer) of \(m.totalLayers)") }
        if m.certChanged { return "Printer certificate changed. Use ⋯ → Add Printer to trust it." }
        if parts.isEmpty, let p = m.printer { parts.append(m.online ? "Ready" : "Can't reach \(p.ip)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder var cameraOverlay: some View {
        switch m.camera {
        case .live, .idle: EmptyView()
        case .connecting(let how):
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connecting · \(how)").font(.system(size: 11))
            }
            .foregroundStyle(.white.opacity(0.8))
        case .failed(let why):
            VStack(spacing: 8) {
                Image(systemName: "video.slash").font(.system(size: 20))
                Text(why).font(.system(size: 11)).multilineTextAlignment(.center)
                Button("Retry", action: retryCamera).controlSize(.small)
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(16)
        }
    }
}

// MARK: app

final class App: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let model = Model()
    let mqtt = MQTT()
    let discovery = Discovery()
    let camera = Camera()
    let popover = NSPopover()
    var faking = false
    var fake: [String: Any] = [:]

    func applicationDidFinishLaunching(_ n: Notification) {
        item.button?.target = self
        item.button?.action = #selector(toggle)

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: Panel(
            m: model, camera: camera.view,
            choose: { [weak self] in self?.select($0) },
            retryCamera: { [weak self] in self?.startCamera() },
            addPrinter: { [weak self] in self?.askPrinter() }))

        camera.onState = { [weak self] s in self?.model.camera = s }
        mqtt.onState = { [weak self] ok in
            if ok { self?.model.certChanged = false }
            self?.model.online = ok
            self?.redraw()
        }
        mqtt.onCertChanged = { [weak self] in self?.model.certChanged = true }
        mqtt.onReport = { [weak self] j in
            guard let self else { return }
            guard let pr = j["print"] as? [String: Any] else { return }
            let hadRTSP = self.model.rtspURL != nil
            // reports are partial deltas, nested objects included
            self.model.report.merge(pr) { old, new in
                guard let o = old as? [String: Any], let n = new as? [String: Any] else { return new }
                return o.merging(n) { _, b in b }
            }
            if self.faking { self.model.report.merge(self.fake) { _, b in b } }
            // the lan stream became known after the popover opened: switch to it
            if !hadRTSP, self.model.rtspURL != nil, self.popover.isShown, self.model.camera != .live { self.startCamera() }
            self.redraw()
        }
        discovery.onFound = { [weak self] p in self?.found(p) }

        // reuse the last known address so status shows up before the first broadcast arrives
        if let s = model.selected, let ip = defaults.string(forKey: "ip.\(s)") {
            found(Printer(serial: s, ip: ip, name: defaults.string(forKey: "name.\(s)") ?? s,
                          model: defaults.string(forKey: "model.\(s)") ?? ""))
        }
        #if DEBUG
        // fake job fields are laid over the live reports, so the camera and connection stay real
        if debug, let f = ProcessInfo.processInfo.environment["BASKI_FAKE"]?.split(separator: ",") {
            fake = ["gcode_state": String(f[0]), "mc_remaining_time": Int(f[1])!, "mc_percent": Int(f[2])!,
                    "subtask_name": "3DBenchy", "layer_num": 37, "total_layer_num": 120]
            model.report = fake
            model.online = true
            faking = true
        }
        #endif
        redraw()
        discovery.start()
        // nothing usable after 30 s: the broadcast is blocked or Studio has no access code, so ask
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.model.printer == nil, !self.faking else { return }
            self.askPrinter()
        }
        #if DEBUG
        if debug {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let r = self?.item.button?.window?.frame else { return }
                log("shot: item rect \(Int(r.minX)),\(Int(NSScreen.screens[0].frame.height - r.maxY)),\(Int(r.width)),\(Int(r.height))")
            }
        }
        if debug, ProcessInfo.processInfo.environment["BASKI_OPEN"] != nil {
            popover.behavior = .applicationDefined  // stays open while screenshots are taken
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.toggle() }
        }
        if debug, let out = ProcessInfo.processInfo.environment["BASKI_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { MainActor.assumeIsolated { self.snapshot(out) } }
        }
        #endif
    }

    #if DEBUG
    /// debug: renders the panel (with a still image instead of live video) to a png
    @MainActor func snapshot(_ out: String) {
        let still = ProcessInfo.processInfo.environment["BASKI_STILL"].flatMap { NSImage(contentsOfFile: $0) }
        if ProcessInfo.processInfo.environment["BASKI_FAILED"] != nil {
            model.camera = .failed("Camera unavailable. Turn on LAN Only Liveview on the printer (Settings → Network).")
        }
        let view = Panel(m: model, camera: camera.view, preview: still, choose: { _ in }, retryCamera: {})
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, ProcessInfo.processInfo.environment["BASKI_LIGHT"] != nil ? .light : .dark)
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
        log("snapshot written")
        NSApp.terminate(nil)
    }
    #endif

    func found(_ p: Printer) {
        let old = model.printers[p.serial]
        guard old != p else { return }
        model.printers[p.serial] = p
        defaults.set(p.ip, forKey: "ip.\(p.serial)")
        defaults.set(p.name, forKey: "name.\(p.serial)")
        defaults.set(p.model, forKey: "model.\(p.serial)")
        log("found \(p.name) \(p.modelName) at \(p.ip)")
        if model.selected == nil, accessCode(p.serial) != nil { select(p.serial) }
        else if model.selected == p.serial, old?.ip != p.ip { select(p.serial) }
    }

    func select(_ serial: String) {
        guard let p = model.printers[serial] else { return }
        model.selected = serial
        defaults.set(serial, forKey: "selected")
        model.report = [:]
        model.online = false
        mqtt.connect(ip: p.ip, serial: serial)
        if popover.isShown { startCamera() }
        redraw()
    }

    func startCamera() {
        log("camera: start (popover shown: \(popover.isShown), rtsp: \(model.rtspURL ?? "off"))")
        guard let p = model.printer else { model.camera = .failed("No printer found yet."); return }
        camera.start(cameraCandidates(p, rtsp: model.rtspURL))
    }

    /// fallback for networks that block the broadcast, or printers Bambu Studio never saw
    func askPrinter() {
        popover.performClose(nil)
        let fields = ["IP address", "Serial number", "Access code"].map { label -> NSTextField in
            let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            f.placeholderString = label
            return f
        }
        if let p = model.printer {
            fields[0].stringValue = p.ip
            fields[1].stringValue = p.serial
            fields[2].stringValue = accessCode(p.serial) ?? ""
        }
        let stack = NSStackView(views: fields)
        stack.orientation = .vertical
        stack.frame = NSRect(x: 0, y: 0, width: 240, height: 88)
        let a = NSAlert()
        a.messageText = "Add Printer"
        a.informativeText = "All three are on the printer screen: Settings → Network (IP, access code) and Settings → Device (serial)."
        a.accessoryView = stack
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let v = fields.map { $0.stringValue.trimmingCharacters(in: .whitespaces) }
        guard !v[0].isEmpty, !v[1].isEmpty, !v[2].isEmpty else { return }
        defaults.set(v[2], forKey: "code.\(v[1])")
        defaults.removeObject(forKey: "cert.\(v[1])")  // a reset or replaced printer has a new certificate
        model.certChanged = false
        let p = Printer(serial: v[1], ip: v[0], name: model.printers[v[1]]?.name ?? v[1], model: model.printers[v[1]]?.model ?? "")
        found(p)
        select(p.serial)
    }

    @objc func toggle() {
        if popover.isShown { popover.performClose(nil); return }
        guard let b = item.button else { return }
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        startCamera()
        #if DEBUG
        // for real screenshots: screencapture -l <window> and -R <menu bar item rect>
        if let w = popover.contentViewController?.view.window, let bw = b.window {
            let r = bw.frame, top = NSScreen.screens[0].frame.height
            log("shot: popover window \(w.windowNumber); item rect \(Int(r.minX)),\(Int(top - r.maxY)),\(Int(r.width)),\(Int(r.height))")
        }
        #endif
    }

    func popoverDidClose(_ n: Notification) {
        log("popover closed")
        camera.stop()
        model.camera = .idle
    }

    func redraw() {
        guard let b = item.button else { return }
        b.appearsDisabled = !model.online
        guard model.online, model.active else {
            let sym = !model.online ? "printer" : model.state == "FINISH" ? "checkmark.circle"
                : model.state == "FAILED" ? "exclamationmark.triangle" : "printer.fill"
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: model.stateLabel)
            b.image?.isTemplate = true
            return
        }
        let text = (model.state == "PAUSE" ? "⏸ " : "") + Model.duration(model.remaining)
        let frac = CGFloat(min(max(model.percent, 0), 100)) / 100
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        let w = max(ceil((text as NSString).size(withAttributes: [.font: font]).width), 34) + 2
        let img = NSImage(size: NSSize(width: w, height: 18), flipped: false) { r in
            // drawn black, then used as a template so the menu bar tints it
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let ts = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: (r.width - ts.width) / 2, y: r.height - ts.height + 1), withAttributes: attrs)
            let track = NSRect(x: 1, y: 1, width: r.width - 2, height: 3)
            NSColor.black.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
            var fill = track; fill.size.width = max(3, track.width * frac)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "\(model.stateLabel), \(model.percent)%, \(Model.duration(model.remaining)) left"
        b.image = img
        log("bar: \(text) \(model.percent)%")
        #if DEBUG
        if debug, let out = ProcessInfo.processInfo.environment["BASKI_BARPNG"] {
            let dark = ProcessInfo.processInfo.environment["BASKI_LIGHT"] == nil
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w + 24) * 4, pixelsHigh: 24 * 4, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = NSSize(width: w + 24, height: 24)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor(white: dark ? 0.16 : 0.93, alpha: 1).setFill(); NSRect(origin: .zero, size: rep.size).fill()
            let tinted = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r); (dark ? NSColor.white : NSColor.black).set(); r.fill(using: .sourceAtop); return true
            }
            tinted.draw(at: NSPoint(x: 12, y: 3), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
        #endif
    }
}

#if TEST
runTests()
#else
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
#endif
