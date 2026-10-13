// parser tests; run with tests/run.sh

import Foundation
import AppKit

var failures = 0

func check(_ ok: Bool, _ name: String) {
    print(ok ? "ok    \(name)" : "FAIL  \(name)")
    if !ok { failures += 1 }
}

func drainMain() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

func jpeg(_ gray: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 3,
                               hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for x in 0 ..< 8 { for y in 0 ..< 8 { rep.setColor(NSColor(deviceRed: gray, green: gray, blue: gray, alpha: 1), atX: x, y: y) } }
    return rep.representation(using: .jpeg, properties: [:])!
}

func runTests() {
    // h264: the fixture is 60 frames from a P2S, fed in 4 KB reads with a log line injected mid-stream
    var stream = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    stream.insert(contentsOf: Data("BambuTunnel::GetMsg(13)\n".utf8), at: stream.count / 2)
    let cam = Camera()
    var i = 0
    while i < stream.count {
        cam.feed(stream.subdata(in: i ..< min(i + 4096, stream.count)))
        i += 4096
    }
    // at end of input two frames are still held: the last nal waits for the next start code,
    // and the frame before it waits for the next frame's first slice. a live stream releases both.
    check(cam.frames == 58, "h264: 58 of 60 frames out through chunking and log noise (got \(cam.frames))")

    // jpeg: two pictures in one read, then one split across two reads
    let jcam = Camera()
    jcam.feed(jpeg(0.2) + jpeg(0.8))
    check(jcam.frames == 2, "jpeg: two pictures in one read (got \(jcam.frames))")
    let third = jpeg(0.5)
    jcam.feed(third.prefix(third.count / 2))
    jcam.feed(third.suffix(from: third.count / 2))
    check(jcam.frames == 3, "jpeg: picture split across reads (got \(jcam.frames))")

    // mqtt: a publish split over two reads, after two malformed packets
    let mqtt = MQTT()
    var reports: [[String: Any]] = []
    mqtt.onReport = { reports.append($0) }
    mqtt.ingest(Data([0x30, 0x01, 0x00]))                    // shorter than a topic length
    mqtt.ingest(Data([0x30, 0x03, 0x00, 0x09, 0x41]))        // topic length past the end
    let pkt = mqtt.publishPacket("device/X/report", #"{"print":{"mc_percent":63}}"#)
    mqtt.ingest(pkt.prefix(10))
    mqtt.ingest(pkt.suffix(from: 10))
    drainMain()
    let pct = ((reports.first?["print"] as? [String: Any])?["mc_percent"] as? NSNumber)?.intValue
    check(reports.count == 1 && pct == 63, "mqtt: split publish parsed after malformed packets (got \(reports.count))")

    // mqtt: a payload over 127 bytes needs a two-byte length
    let big = #"{"print":{"subtask_name":""# + String(repeating: "x", count: 300) + #""}}"#
    mqtt.ingest(mqtt.publishPacket("device/X/report", big))
    drainMain()
    check(reports.count == 2, "mqtt: multi-byte remaining length")

    print(failures == 0 ? "all passed" : "\(failures) failed")
    exit(failures == 0 ? 0 : 1)
}
