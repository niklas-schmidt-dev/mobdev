import CoreGraphics
import CoreMedia
import Foundation
import Testing
import VideoToolbox
@testable import MobdevCore

/// scrcpy's wire format, byte for byte as scrcpy 3.3.4's own tests (app/tests/test_control_msg_serialize.c,
/// test_device_msg_deserialize.c) and bytes recorded from its server on an Android 16 emulator.
@Suite struct ScrcpyProtocolTests {
    func bytes(_ hex: String) -> Data {
        var data = Data()
        var digits = hex.filter(\.isHexDigit).makeIterator()
        while let high = digits.next(), let low = digits.next() { data.append(UInt8(String([high, low]), radix: 16)!) }
        return data
    }

    @Test func keycodeAsScrcpySerializesIt() {
        // AKEY_EVENT_ACTION_UP, AKEYCODE_ENTER, repeat 5, AMETA_SHIFT_ON | AMETA_SHIFT_LEFT_ON.
        let data = ScrcpyProtocol.injectKeycode(.up, keycode: 66, repeat: 5, metaState: 0x41)
        #expect(data == bytes("00 01 00000042 00000005 00000041"))
    }

    @Test func textAsScrcpySerializesItCutAtACharacter() {
        #expect(ScrcpyProtocol.injectText("hello, world!") == Data([1, 0, 0, 0, 0x0d]) + Data("hello, world!".utf8))
        let long = ScrcpyProtocol.injectText(String(repeating: "a", count: 300))
        #expect(long.count == 305)
        #expect(long.prefix(5) == bytes("01 0000012c"))
        // 299 ASCII bytes and a two-byte "ü" would end inside the ü: it is left out.
        let cut = ScrcpyProtocol.injectText(String(repeating: "a", count: 299) + "ü")
        #expect(cut.prefix(5) == bytes("01 0000012b"))
        #expect(ScrcpyProtocol.utf8Prefix(Array("👋".utf8), maxLength: 3) == 0)
        #expect(ScrcpyProtocol.utf8Prefix(Array("ab".utf8), maxLength: 5) == 2)
    }

    @Test func touchAsScrcpySerializesIt() {
        let data = ScrcpyProtocol.injectTouch(
            .down, pointer: 0x1234_5678_8765_4321, x: 100, y: 200, width: 1080, height: 1920, pressure: 1,
            actionButton: 1, buttons: 1)
        #expect(data == bytes("02 00 1234567887654321 00000064 000000c8 0438 0780 ffff 00000001 00000001"))
        // A finger lifting: scrcpy's generic finger id, no pressure.
        let up = ScrcpyProtocol.injectTouch(.up, pointer: ScrcpyProtocol.finger, x: 1, y: 2, width: 576, height: 1280, pressure: 0)
        #expect(up == bytes("02 01 fffffffffffffffe 00000001 00000002 0240 0500 0000 00000000 00000000"))
        #expect(ScrcpyProtocol.secondFinger == 0xffff_ffff_ffff_fffd)
        #expect(ScrcpyProtocol.unsignedFixedPoint(0.5) == 0x8000)
    }

    @Test func clipboardMessagesAsScrcpySerializesThem() {
        #expect(ScrcpyProtocol.getClipboard(copyKey: 1) == Data([8, 1]))
        let set = ScrcpyProtocol.setClipboard(sequence: 0x0102_0304_0506_0708, text: "hello, world!", paste: true)
        #expect(set == bytes("09 0102030405060708 01 0000000d") + Data("hello, world!".utf8))
        #expect(set.count == 27)
        #expect(ScrcpyProtocol.resetVideo() == Data([17]))
    }

    @Test func deviceMessagesAsScrcpyReadsThem() throws {
        let clipboard = try #require(try ScrcpyProtocol.deviceMessage(in: bytes("00 00000003 414243")))
        #expect(clipboard.message == .clipboard("ABC"))
        #expect(clipboard.length == 8)
        let ack = try #require(try ScrcpyProtocol.deviceMessage(in: bytes("01 0102030405060708")))
        #expect(ack.message == .clipboardAcknowledged(0x0102_0304_0506_0708))
        #expect(ack.length == 9)
        let uhid = try #require(try ScrcpyProtocol.deviceMessage(in: bytes("02 002a 0005 0102030405")))
        #expect(uhid.message == .uhidOutput(id: 42, data: Data([1, 2, 3, 4, 5])))
        // Recorded: an acknowledgement and the clipboard in one read, UTF-8 included.
        var stream = bytes("010000000000000009 00 00000011 4772c3bcc39f6520f09f918b20636c6970")
        var messages: [ScrcpyProtocol.DeviceMessage] = []
        while let (message, length) = try ScrcpyProtocol.deviceMessage(in: stream) {
            messages.append(message)
            stream = Data(stream.dropFirst(length))
        }
        #expect(messages == [.clipboardAcknowledged(9), .clipboard("Grüße 👋 clip")])
        // Incomplete messages wait for more bytes; unknown ones end the connection.
        #expect(try ScrcpyProtocol.deviceMessage(in: bytes("00 00000003 4142")) == nil)
        #expect(try ScrcpyProtocol.deviceMessage(in: bytes("01 0102")) == nil)
        #expect(try ScrcpyProtocol.deviceMessage(in: Data()) == nil)
        #expect(throws: DeveloperError.self) { try ScrcpyProtocol.deviceMessage(in: Data([7])) }
    }

    @Test func recordedVideoHeadersAndParameterSets() throws {
        // An Android 16 emulator with a 1280×2856 screen and max_size=1280.
        let header = try ScrcpyProtocol.videoHeader(bytes("68323634 00000240 00000500"))
        #expect(header == .init(codec: ScrcpyProtocol.h264, width: 576, height: 1280))
        #expect(throws: DeveloperError.self) { try ScrcpyProtocol.videoHeader(bytes("00000000 00000000 00000000")) }
        #expect(throws: DeveloperError.self) { try ScrcpyProtocol.videoHeader(bytes("00000001 00000000 00000000")) }

        let config = ScrcpyProtocol.packetHeader(bytes("8000000000000000 00000020"))
        #expect(config == .init(config: true, keyFrame: false, pts: 0, size: 32))
        let key = ScrcpyProtocol.packetHeader(bytes("400000009c520f69 0000ad77"))
        #expect(key == .init(config: false, keyFrame: true, pts: 0x9c52_0f69, size: 44407))

        let packet = bytes("000000016742c0298d680900a1a420202020f08846a00000000168ce01a835c8")
        let units = ScrcpyProtocol.nalUnits(packet)
        #expect(units.map { $0.first! & 0x1f } == [7, 8])  // SPS, PPS
        #expect(units.map(\.count) == [18, 6])
        // Three-byte start codes count too.
        #expect(ScrcpyProtocol.nalUnits(bytes("000001 65 aa 000001 41 bb")) == [bytes("65aa"), bytes("41bb")])
    }

    @Test func serverCommandPinsVersionAndCleansUp() {
        let command = ScrcpyConnection.command(remote: "/data/local/tmp/mobdev-scrcpy-0abc1234.jar", scid: "0abc1234", maxSize: 1280)
        #expect(command.hasSuffix(
            "CLASSPATH=/data/local/tmp/mobdev-scrcpy-0abc1234.jar app_process / com.genymobile.scrcpy.Server 3.3.4 scid=0abc1234 log_level=info tunnel_forward=true audio=false control=true video_codec=h264 max_size=1280 clipboard_autosync=false power_on=false"))
        #expect(command.hasPrefix("(sleep 15; grep -q ' 00010000 0001 01 .*@scrcpy_0abc1234$' /proc/net/unix && pkill -f 'scid=[0]abc1234')"))
        #expect(ScrcpyConnection.killCommand("7f00aa11") == "kill -9 $(pgrep -f 'scid=[7]f00aa11') 2>/dev/null")
    }

    @Test func buildScriptDownloadsThePinnedServer() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/build-app.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(text.contains("SCRCPY_VERSION=\"\(ScrcpyServer.version)\""))
        #expect(text.contains("SCRCPY_SHA256=\"\(ScrcpyServer.sha256)\""))
    }

    @Test func switchTurnsScrcpyOff() {
        #expect(ScrcpySession.isEnabled([:]))
        #expect(ScrcpySession.isEnabled(["MOBDEV_ANDROID_SCRCPY": "1"]))
        #expect(!ScrcpySession.isEnabled(["MOBDEV_ANDROID_SCRCPY": "0"]))
        #expect(ScrcpyConnection.typesAsKeys("hello, world! ~"))
        #expect(!ScrcpyConnection.typesAsKeys("Grüße"))
        #expect(!ScrcpyConnection.typesAsKeys("tab\there"))
    }
}

// MARK: - Decoding

/// Pictures encoded on this Mac with VideoToolbox, sent as scrcpy sends them: the parameter sets as
/// a config packet and a key frame, both with Annex B start codes. Nil where the Mac cannot encode
/// H.264, as on some virtual machines.
func encodeH264(width: Int, height: Int, draw: (CGContext) -> Void) -> (config: Data, frame: Data)? {
    var created: VTCompressionSession?
    guard
        VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
            refcon: nil, compressionSessionOut: &created) == noErr,
        let session = created
    else { return nil }
    defer { VTCompressionSessionInvalidate(session) }
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    var pixels: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixels)
    guard let pixels else { return nil }
    CVPixelBufferLockBaseAddress(pixels, [])
    let context = CGContext(
        data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    draw(context)
    CVPixelBufferUnlockBaseAddress(pixels, [])
    let output = Locked<CMSampleBuffer?>(nil)
    let status = VTCompressionSessionEncodeFrame(
        session, imageBuffer: pixels, presentationTimeStamp: .zero, duration: .invalid,
        frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary, infoFlagsOut: nil
    ) { status, _, sample in
        if status == noErr { output.set(sample) }
    }
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    guard status == noErr, let sample = output.get(), let format = CMSampleBufferGetFormatDescription(sample),
        let block = CMSampleBufferGetDataBuffer(sample)
    else { return nil }
    let start = Data([0, 0, 0, 1])
    var config = Data()
    for index in 0..<2 {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        guard
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer
        else { return nil }
        config += start + Data(bytes: pointer, count: size)
    }
    var length = 0
    var pointer: UnsafeMutablePointer<CChar>?
    guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
        let pointer
    else { return nil }
    let avcc = [UInt8](UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: length))
    var frame = Data()
    var offset = 0
    while offset + 4 <= avcc.count {
        let size = avcc[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        frame += start + Data(avcc[offset + 4..<min(offset + 4 + size, avcc.count)])
        offset += 4 + size
    }
    return (config, frame)
}

/// Left half red, right half blue.
func drawHalves(_ context: CGContext) {
    context.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: context.width / 2, height: context.height))
    context.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: context.width / 2, y: 0, width: context.width - context.width / 2, height: context.height))
}

/// The red and blue of a pixel in an image, 0–255.
func redAndBlue(_ image: CGImage, x: Int, y: Int) -> (red: Int, blue: Int) {
    let context = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    let pixel = context.data!.assumingMemoryBound(to: UInt8.self)
    return (Int(pixel[0]), Int(pixel[2]))
}

@Suite struct H264DecoderTests {
    /// 568×1272 is what max_size=1272 makes of a 1080×2400 screen: not a multiple of 16, so the
    /// stream is cropped, and touches must use the cropped size.
    @Test func decodesTheNewestPictureCroppedToItsSize() throws {
        guard let encoded = encodeH264(width: 568, height: 1272, draw: drawHalves) else {
            print("This Mac cannot encode H.264; skipped.")
            return
        }
        let decoder = H264Decoder()
        #expect(decoder.image() == nil)
        #expect(decoder.decode(encoded.config, config: true, keyFrame: false))
        #expect(decoder.size.map { [$0.width, $0.height] } == [568, 1272])
        // Pictures before a key frame cannot be decoded and are left out.
        #expect(decoder.decode(encoded.frame, config: false, keyFrame: true))
        #expect(decoder.frameCount == 1)
        let image = try #require(decoder.image())
        #expect(image.width == 568)
        #expect(image.height == 1272)
        #expect(decoder.image() === image)  // Made once per picture.
        let left = redAndBlue(image, x: 100, y: 600)
        let right = redAndBlue(image, x: 468, y: 600)
        #expect(left.red > 180 && left.blue < 80, "\(left)")
        #expect(right.blue > 180 && right.red < 80, "\(right)")
        // The same picture again counts as the newest.
        #expect(decoder.decode(encoded.frame, config: false, keyFrame: true))
        #expect(decoder.frameCount == 2)
        #expect(decoder.image() !== image)
    }
}

// MARK: - A fake device

/// adb for a device whose scrcpy server is `FakeScrcpyServer`: push and forward succeed (or forward
/// fails with `refuseForward`), the shell records commands, and screencap returns a 4×8 picture.
final class FakeADB: CommandRunning, @unchecked Sendable {
    let port: Int
    let refuseForward: Bool
    let calls = Locked<[[String]]>([])
    let stopped = Locked(0)

    init(port: Int, refuseForward: Bool = false) {
        self.port = port
        self.refuseForward = refuseForward
    }

    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        calls.withLock { $0.append(arguments) }
        if arguments.dropFirst(2).starts(with: ["forward", "tcp:0"]) {
            return refuseForward ? CommandResult(status: 1, output: "adb: error: cannot bind") : CommandResult(status: 0, output: "\(port)\n")
        }
        return CommandResult(status: 0, output: "")
    }

    func start(
        _ executable: URL, _ arguments: [String], onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> RunningCommand {
        calls.withLock { $0.append(arguments) }
        onLine("[server] INFO: Device: [Google] google sdk_gphone64_arm64 (Android 16)")
        return Stop(stopped: stopped)
    }

    func runBinary(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> (status: Int32, data: Data) {
        calls.withLock { $0.append(arguments) }
        guard arguments.last == "screencap" else { return (0, Data()) }
        var data = Data([4, 0, 0, 0, 8, 0, 0, 0, 1, 0, 0, 0])
        data.append(Data(repeating: 0x80, count: 4 * 8 * 4))
        return (0, data)
    }

    var shellCommands: [String] { calls.get().filter { $0.count == 4 && $0[2] == "shell" }.map { $0[3] } }

    private struct Stop: RunningCommand {
        let stopped: Locked<Int>
        func stop() { stopped.withLock { $0 += 1 } }
    }
}

/// scrcpy's server as the Mac sees it through the forward tunnel: a dummy byte and the device's
/// name on the first connection, a codec header and optionally a picture, and a control socket that
/// keeps the clipboard and acknowledges it. Every control message is recorded.
final class FakeScrcpyServer: @unchecked Sendable {
    let port: Int
    let messages = Locked<[Data]>([])
    let clipboard = Locked("")
    private let listener: Int32
    private let video: (config: Data, frame: Data)?
    private let size: (width: Int, height: Int)

    init(video: (config: Data, frame: Data)?, width: Int, height: Int) throws {
        self.video = video
        size = (width, height)
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(socket, 4) == 0 else { throw DeveloperError("bind failed") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(socket, $0, &length) }
        }
        listener = socket
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread.detachNewThread { [self] in serve() }
    }

    deinit { close(listener) }

    private func serve() {
        let videoSocket = accept(listener, nil, nil)
        guard videoSocket >= 0 else { return }
        _ = try? ADB.write(videoSocket, Data([0]))
        let controlSocket = accept(listener, nil, nil)
        guard controlSocket >= 0 else { return }
        var head = Data("sdk_gphone64_arm64".utf8)
        head.append(Data(repeating: 0, count: 64 - head.count))
        head.append(contentsOf: [0x68, 0x32, 0x36, 0x34])
        for value in [size.width, size.height] { head.append(contentsOf: withUnsafeBytes(of: UInt32(value).bigEndian, Array.init)) }
        _ = try? ADB.write(videoSocket, head)
        if let video {
            for (packet, flags) in [(video.config, UInt64(1) << 63), (video.frame, UInt64(1) << 62 | 1000)] {
                var header = Data(withUnsafeBytes(of: flags.bigEndian, Array.init))
                header.append(contentsOf: withUnsafeBytes(of: UInt32(packet.count).bigEndian, Array.init))
                _ = try? ADB.write(videoSocket, header + packet)
            }
        }
        Thread.detachNewThread { [self] in readControl(controlSocket) }
        // The video socket stays open until the Mac closes it.
        var byte: UInt8 = 0
        _ = read(videoSocket, &byte, 1)
        close(videoSocket)
    }

    /// Control messages by their scrcpy layout, the fixed part then the text's length.
    private func readControl(_ socket: Int32) {
        defer { close(socket) }
        while let type = try? ADB.read(socket, count: 1).first {
            var message = Data([type])
            let fixed = [0: 13, 1: 4, 2: 31, 8: 1, 9: 13, 17: 0][Int(type)]
            guard let fixed, let rest = try? ADB.read(socket, count: fixed) else { return }
            message.append(rest)
            if type == 1 || type == 9, let length = Int(exactly: rest.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }) {
                guard let text = try? ADB.read(socket, count: length) else { return }
                message.append(text)
            }
            messages.withLock { $0.append(message) }
            switch type {
            case 8:
                let text = Data(clipboard.get().utf8)
                var reply = Data([0])
                reply.append(contentsOf: withUnsafeBytes(of: UInt32(text.count).bigEndian, Array.init))
                _ = try? ADB.write(socket, reply + text)
            case 9:
                clipboard.set(String(decoding: message.dropFirst(14), as: UTF8.self))
                _ = try? ADB.write(socket, Data([1]) + message[1..<9])
            default: break
            }
        }
    }
}

@Suite(.serialized) struct ScrcpySessionTests {
    func device(_ adb: FakeADB, server: Result<URL, DeveloperError> = .success(URL(fileURLWithPath: "/tmp/scrcpy-server"))) -> AndroidDevice {
        AndroidDevice(
            serial: "emulator-test-scrcpy",
            details: .init(name: "Test", model: "sdk", modelName: "Android Emulator", osVersion: "16", width: 1080, height: 2400),
            adb: ADB(executable: URL(fileURLWithPath: "/fake/adb"), runner: adb),
            reportsFolder: FileManager.default.temporaryDirectory, scrcpyServer: { server })
    }

    func touch(_ action: ScrcpyProtocol.TouchAction, _ pointer: UInt64, _ x: Int, _ y: Int) -> Data {
        ScrcpyProtocol.injectTouch(action, pointer: pointer, x: x, y: y, width: 568, height: 1272, pressure: action == .up ? 0 : 1)
    }

    func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func inputTextClipboardAndPicturesGoThroughTheServer() async throws {
        let encoded = encodeH264(width: 568, height: 1272, draw: drawHalves)
        let server = try FakeScrcpyServer(video: encoded, width: 568, height: 1272)
        let adb = FakeADB(port: server.port)
        let android = device(adb)
        defer { android.close() }

        try await android.tap(at: NormalizedPoint(x: 0.5, y: 0.25), hold: 0.08)
        // Pushed, forwarded, started with the pinned version, connected, then the forward removed.
        let calls = adb.calls.get()
        #expect(calls[0].starts(with: ["-s", "emulator-test-scrcpy", "push", "/tmp/scrcpy-server"]))
        let scid = try #require(calls[0].last?.firstMatch(of: /mobdev-scrcpy-([0-9a-f]{8})\.jar/)?.1).description
        #expect(calls[1] == ["-s", "emulator-test-scrcpy", "forward", "tcp:0", "localabstract:scrcpy_\(scid)"])
        #expect(calls[2][3].contains("com.genymobile.scrcpy.Server 3.3.4 scid=\(scid) "))
        #expect(calls[3] == ["-s", "emulator-test-scrcpy", "forward", "--remove", "tcp:\(server.port)"])
        await waitFor { server.messages.get().count >= 2 }
        // 0.5 × 567 and 0.25 × 1271, in the video's pixels.
        #expect(server.messages.get() == [touch(.down, ScrcpyProtocol.finger, 284, 318), touch(.up, ScrcpyProtocol.finger, 284, 318)])
        #expect(!adb.shellCommands.contains { $0.hasPrefix("input") })

        server.messages.set([])
        #expect(try await android.typeText("hi\nGrüße 👋"))
        try await android.press(KeyStroke(0x04, KeyStroke.control))  // Ctrl+A
        await waitFor { server.messages.get().count >= 8 }
        #expect(
            server.messages.get() == [
                ScrcpyProtocol.injectText("hi"),
                ScrcpyProtocol.injectKeycode(.down, keycode: 66), ScrcpyProtocol.injectKeycode(.up, keycode: 66),
                ScrcpyProtocol.setClipboard(sequence: 1, text: "Grüße 👋", paste: true),
                ScrcpyProtocol.injectKeycode(.down, keycode: 113, metaState: 0x3000),
                ScrcpyProtocol.injectKeycode(.down, keycode: 29, metaState: 0x3000),
                ScrcpyProtocol.injectKeycode(.up, keycode: 29, metaState: 0x3000),
                ScrcpyProtocol.injectKeycode(.up, keycode: 113),
            ])

        let settings = try #require(android.settings)
        #expect(try await settings.clipboard() == "Grüße 👋")
        try await settings.setClipboard("Mobdev ✓")
        #expect(server.clipboard.get() == "Mobdev ✓")
        #expect(try await settings.clipboard() == "Mobdev ✓")

        server.messages.set([])
        try await android.pinch(at: NormalizedPoint(x: 0.5, y: 0.5), scale: 2, duration: 0.05)
        await waitFor { server.messages.get().filter { $0[1] == 1 }.count >= 2 }
        let pinch = server.messages.get()
        #expect(pinch.first == touch(.down, ScrcpyProtocol.finger, 198, 636))  // 0.35 × 567
        #expect(pinch[1] == touch(.down, ScrcpyProtocol.secondFinger, 369, 636))  // 0.65 × 567
        #expect(pinch.suffix(2) == [touch(.up, ScrcpyProtocol.secondFinger, 454, 636), touch(.up, ScrcpyProtocol.finger, 113, 636)])
        #expect(pinch.dropFirst(2).dropLast(2).allSatisfy { $0[1] == ScrcpyProtocol.TouchAction.move.rawValue })

        if encoded != nil {
            await waitFor { android.isStreaming }
            #expect(android.isStreaming)
            #expect(android.status().input == .direct("scrcpy"))
            let frame = try #require(android.frame())
            #expect(frame.width == 568 && frame.height == 1272)
            #expect(android.status().frameSize.map { [$0.width, $0.height] } == [568, 1272])
            #expect(!adb.calls.get().contains { $0.last == "screencap" })
        }

        // Closing kills the server by its scid and stops the adb shell.
        android.close()
        #expect(adb.shellCommands.contains(ScrcpyConnection.killCommand(scid)))
        #expect(adb.stopped.get() == 1)
        #expect(!android.isStreaming)
    }

    @Test func adbTakesOverWhenTheServerCannotStart() async throws {
        let adb = FakeADB(port: 9, refuseForward: true)
        let android = device(adb)
        defer { android.close() }
        try await android.tap(at: NormalizedPoint(x: 0.5, y: 0.5), hold: 0.08)
        #expect(adb.shellCommands.contains("input tap 540 1200"))
        // Cleaned up after the failure, and not tried again right away.
        #expect(adb.shellCommands.contains { $0.hasPrefix("kill -9 $(pgrep -f 'scid=") })
        try await android.tap(at: NormalizedPoint(x: 0.5, y: 0.5), hold: 0.08)
        #expect(adb.calls.get().filter { $0.contains("forward") }.count == 1)
        let frame = try #require(android.frame())
        #expect(frame.width == 4 && frame.height == 8)
        #expect(android.status().input == .direct("adb"))
        #expect(try await android.typeText("ok"))
        #expect(adb.shellCommands.contains("input text 'ok'"))
        await #expect(throws: DeveloperError.self) { try await android.typeText("Grüße") }
        await #expect(throws: DeveloperError.self) { try await android.settings?.clipboard() }
        await #expect(throws: DeveloperError.self) { try await android.pinch(at: NormalizedPoint(x: 0.5, y: 0.5), scale: 2) }
    }

    @Test func withoutTheServerFileAdbDoesEverything() async throws {
        let adb = FakeADB(port: 9)
        let android = device(adb, server: .failure(DeveloperError("The app has no scrcpy-server-v3.3.4 in its Resources.")))
        defer { android.close() }
        try await android.press(KeyStroke(0x28))
        #expect(adb.shellCommands == ["input keyevent 66"])
        do {
            _ = try await android.typeText("Grüße")
            Issue.record("typed non-ASCII text without scrcpy")
        } catch {
            #expect(String(describing: error).contains("no scrcpy-server-v3.3.4"))
        }
        // Switched off, there is no session at all.
        let off = AndroidDevice(
            serial: "emulator-test-off", details: .init(name: "Off", model: "sdk", modelName: "Android Emulator", osVersion: "16"),
            adb: ADB(executable: URL(fileURLWithPath: "/fake/adb"), runner: adb), scrcpyServer: nil)
        #expect(off.scrcpy == nil)
        #expect(off.frame()?.width == 4)
    }
}
