// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest
@testable import VRLinkCore

/// Minimal local mock of a WiVRn host for connection tests (see docs/wivrn/protocol.md).
/// Replies to the initial crypto handshake with `state`. When `state` is `.encryptionDisabled`,
/// it also completes the UDP stream port handshake and records subsequent control packet types.
private final class PretendWiVRnHost {
    let port: UInt16
    private let listener: Int32
    private let stream: UDPSocket
    private let streamPort: UInt16
    private let done = DispatchSemaphore(value: 0)
    /// Client device name from the handshake, and packet types received after the handshake completes.
    private(set) var name: String?
    private(set) var afterwards: [UInt8] = []

    init?(state: WiVRn.CryptoState) {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        self.listener = listener
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, length) == 0 && listen(listener, 1) == 0 && getsockname(listener, $0, &length) == 0
            }
        }
        var found: (UDPSocket, UInt16)?
        for candidate in (0..<50).map({ _ in UInt16.random(in: 40_000...60_000) }) where found == nil {
            if let socket = UDPSocket(localPort: candidate) { found = (socket, candidate) }
        }
        guard listener >= 0, bound, let found else { return nil }
        port = UInt16(bigEndian: address.sin_port)
        (stream, streamPort) = found
        Thread.detachNewThread { [self] in
            serve(state)
            done.signal()
        }
    }

    deinit { close(listener) }

    /// Waits for the mock server thread to finish handling the connection.
    func finish() { _ = done.wait(timeout: .now() + 10) }

    private func serve(_ state: WiVRn.CryptoState) {
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { return }
        defer { close(connection) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        func read(_ count: Int) -> Bytes? {
            var out = Bytes(repeating: 0, count: count), have = 0
            while have < count {
                let got = out.withUnsafeMutableBytes { recv(connection, $0.baseAddress! + have, count - have, 0) }
                guard got > 0 else { return nil }
                have += got
            }
            return out
        }
        func packet() -> Bytes? {
            guard let length = read(4) else { return nil }
            return read(Int(length.integer(at: 0) as UInt32))
        }
        func send(_ packet: Bytes) {
            var framed = Bytes()
            framed.append(integer: UInt32(packet.count))
            framed.append(contentsOf: packet)
            _ = framed.withUnsafeBytes { Foundation.send(connection, $0.baseAddress, framed.count, 0) }
        }
        var handshake: Bytes = [WiVRn.ToHeadsetKind.handshake.rawValue]
        handshake.append(integer: Int32(streamPort))

        guard let first = packet() else { return }
        var reader = WireReader(first)
        guard reader.integer(UInt8.self) == WiVRn.FromHeadset.cryptoHandshake.rawValue,
              reader.integer(UInt64.self) == WiVRn.protocolVersion else { return }
        _ = reader.string()
        name = reader.string()
        var answer: Bytes = [WiVRn.ToHeadsetKind.cryptoHandshake.rawValue]
        answer.append(string: "")
        answer.append(state.rawValue)
        send(answer)
        guard state == .encryptionDisabled, packet() == WiVRnPacket.cryptoHandshakeDone else { return }
        send(handshake)
        // Wait for the client's initial UDP packet on the stream socket, then acknowledge it.
        guard stream.receive(timeout: 5) == WiVRnPacket.handshake else { return }
        send(handshake)
        while afterwards.count < 2, let next = packet(), let kind = next.first { afterwards.append(kind) }
    }
}

final class HostConnectorTests: XCTestCase {
    private var directory: URL!

    /// Redirects `DataDirectory` to a temporary folder so identity keys and display state
    /// written during connection tests don't touch user files.
    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("connector-" + UUID().uuidString)
        DataDirectory.elsewhere = directory
    }

    override func tearDown() {
        DataDirectory.elsewhere = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func connector() -> HostConnector {
        HostConnector(deviceName: HostConnector.name(of: "A Test"), deviceModel: "Mac", systemVersion: "macOS 1.0")
    }

    /// Reserved documentation IP address (RFC 5737) guaranteed not to respond.
    private let nowhere = "192.0.2.1"

    /// Finds an ephemeral localhost port with nothing listening on it.
    private func closedPort() -> UInt16 {
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(probe) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(probe, $0, length) == 0 && getsockname(probe, $0, &length) == 0 }
        }
        return UInt16(bigEndian: address.sin_port)
    }

    func testTheNameAHostIsGiven() {
        XCTAssertEqual(HostConnector.name(of: "Max's Mac"), "Max's Mac (OpenVRLink)")
    }

    func testAWiVRnHostIsConnectedTo() throws {
        let host = try XCTUnwrap(PretendWiVRnHost(state: .encryptionDisabled))
        var shown: [String] = [], logged: [String] = []
        var connector = connector()
        connector.keepLooking = false
        connector.show = { shown.append($0) }
        connector.log = { logged.append($0) }
        connector.askPin = {
            XCTFail("a host that does not encrypt has no PIN to ask for")
            return nil
        }
        let connected = try connector.connect(.wivrn, address: "127.0.0.1", port: host.port, profile: DeviceProfile())
        let (session, name) = try XCTUnwrap(connected)
        host.finish()
        XCTAssertTrue(session is WiVRnSession)
        XCTAssertEqual(name, "127.0.0.1")
        XCTAssertEqual(shown, ["Looking for WiVRn on 127.0.0.1"])
        XCTAssertTrue(logged.contains("the host does not encrypt"), "\(logged)")
        // Verify the client sent its device name followed by headset info and session state.
        XCTAssertEqual(host.name, "A Test (OpenVRLink)")
        XCTAssertEqual(host.afterwards, [WiVRn.FromHeadset.headsetInfo.rawValue, WiVRn.FromHeadset.sessionStateChanged.rawValue])
        // Display configuration should be saved inside the test's temporary data directory.
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("wivrn-displays.json").path))
    }

    func testAWiVRnHostsPinIsAskedOfTheWearer() throws {
        let host = try XCTUnwrap(PretendWiVRnHost(state: .pinNeeded))
        var shown: [String] = [], asked = 0
        var connector = connector()
        connector.keepLooking = false
        connector.show = { shown.append($0) }
        connector.askPin = {
            asked += 1
            return nil      // user canceled PIN entry
        }
        XCTAssertThrowsError(try connector.connect(.wivrn, address: "127.0.0.1", port: host.port, profile: DeviceProfile())) {
            guard case WiVRnError.pinNeeded = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(shown, ["Looking for WiVRn on 127.0.0.1", "The host wants its PIN"])
    }

    func testAWiVRnHostThatRefusesIsAnErrorEvenWhileLooking() throws {
        let host = try XCTUnwrap(PretendWiVRnHost(state: .pairingDisabled))
        XCTAssertThrowsError(try connector().connect(.wivrn, address: "127.0.0.1", port: host.port, profile: DeviceProfile())) {
            guard case WiVRnError.pairingDisabled = $0 else { return XCTFail("\($0)") }
        }
    }

    func testNothingAnsweringIsAnErrorWhenNotLookingOn() {
        var connector = connector()
        connector.keepLooking = false
        XCTAssertThrowsError(try connector.connect(.wivrn, address: "127.0.0.1", port: closedPort(), profile: DeviceProfile())) {
            guard case WiVRnError.unreachable = $0 else { return XCTFail("\($0)") }
        }
        var shown: [String] = []
        connector.show = { shown.append($0) }
        XCTAssertThrowsError(try connector.connect(.steam, address: nowhere, profile: DeviceProfile())) {
            guard case BroadcastError.noReply = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(shown, ["Looking for \(nowhere)"])
    }

    func testLookingGoesOnUntilGivenUp() throws {
        for kind in [HostKind.wivrn, .steam] {
            var asked = 0, interfacesAsked = 0
            var connector = connector()
            connector.cancelled = {
                asked += 1
                return asked > 2
            }
            connector.preferredInterfaces = {
                interfacesAsked += 1
                return []
            }
            let connected = try connector.connect(kind, address: kind == .wivrn ? "127.0.0.1" : nowhere,
                                                  port: kind == .wivrn ? closedPort() : nil, profile: DeviceProfile())
            XCTAssertNil(connected, "\(kind)")
            // Retried twice, querying preferred interfaces on each attempt, before canceling on the third check.
            XCTAssertEqual(asked, 3, "\(kind)")
            XCTAssertEqual(interfacesAsked, 2, "\(kind)")
        }
    }
}
