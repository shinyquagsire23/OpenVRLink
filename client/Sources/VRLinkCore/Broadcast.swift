// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// The UDP 27036 protocol: find a host and ask it for a VR Link session (docs/remoteplay/)

public struct SteamHost {
    public let address: String
    public let clientID: UInt64
    public let hostname: String
    /// The host says it can serve VR Link (it has SteamVR and a hardware encoder).
    public let offersVRLink: Bool
}

/// The session string the host returns (docs/remoteplay/session-request.md):
/// `host~port~port~startinfo~~~~token`.
public struct SessionArgs {
    public let host: String
    public let port: UInt16
    public let token: String

    init?(_ text: String) {
        let fields = text.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 8, let port = UInt16(fields[1]) else { return nil }
        host = fields[0]
        self.port = port
        token = fields[7]
    }
}

public enum BroadcastError: Error, CustomStringConvertible {
    case noReply
    case notPaired
    case refused(result: UInt64)
    case pairingRefused(String)
    case badResponse(String)

    public var description: String {
        switch self {
        case .noReply: return "the host did not answer"
        case .notPaired: return "this device is not paired with the host"
        case .pairingRefused(let why): return "pairing failed: \(why)"
        case .refused(let result):
            // Steam's own names for the results
            let reasons = [2: "its screen is locked", 3: "it failed to start streaming (SteamVR may still be starting; try again)", 4: "it is busy", 7: "its streaming drivers are not installed",
                           8: "streaming is turned off there", 10: "SteamVR is already in use there",
                           14: "it could not start SteamVR (is SteamVR running on another computer of the same account?)",
                           15: "SteamVR is not installed there"]
            return "the host refused the session: " + (reasons[Int(result)] ?? "result \(result)")
        case .badResponse(let why): return "could not read the host's response: \(why)"
        }
    }
}

public enum Broadcast {
    static let port: UInt16 = 27036
    static let magic: Bytes = [0xFF, 0xFF, 0xFF, 0xFF, 0x21, 0x4C, 0x5F, 0xA0]

    // ERemoteClientBroadcastMsg
    static let discovery: UInt64 = 0, status: UInt64 = 1
    static let streamingRequest: UInt64 = 5, streamingResponse: UInt64 = 6
    static let proofRequest: UInt64 = 7, proofResponse: UInt64 = 8
    static let authorizationRequest: UInt64 = 3, authorizationResponse: UInt64 = 4
    static let authorizationConfirmed: UInt64 = 14

    static func datagram(deviceID: UInt64, type: UInt64, body: Bytes) -> Bytes {
        var header = ProtoWriter()
        header.varint(1, deviceID)
        header.varint(2, type)
        var out = magic
        out.append(integer: UInt32(header.bytes.count))
        out.append(contentsOf: header.bytes)
        out.append(integer: UInt32(body.count))
        out.append(contentsOf: body)
        return out
    }

    /// (sender's client id, message type, body)
    static func parse(_ datagram: Bytes) -> (clientID: UInt64, type: UInt64, body: ProtoMessage)? {
        guard datagram.count >= 16, Bytes(datagram.prefix(8)) == magic else { return nil }
        let headerLength = Int(datagram.integer(at: 8) as UInt32)
        let bodyStart = 12 + headerLength + 4
        guard bodyStart <= datagram.count else { return nil }
        let bodyLength = Int(datagram.integer(at: 12 + headerLength) as UInt32)
        guard bodyStart + bodyLength <= datagram.count,
              let header = ProtoMessage(Bytes(datagram[12..<12 + headerLength])),
              let body = ProtoMessage(Bytes(datagram[bodyStart..<bodyStart + bodyLength])),
              let clientID = header.varint(1)
        else { return nil }
        return (clientID, header.varint(2) ?? 0, body)
    }

    private static func host(from reply: (bytes: Bytes, sender: String)) -> SteamHost? {
        guard let message = parse(reply.bytes), message.type == status else { return nil }
        return SteamHost(address: reply.sender, clientID: message.clientID,
                         hostname: message.body.string(4) ?? "",
                         offersVRLink: message.body.varint(26) == 1)   // vr_link_caps: available
    }

    private static func probe(deviceID: UInt64) -> Bytes {
        var body = ProtoWriter()
        body.varint(1, 1)   // seq_num
        return datagram(deviceID: deviceID, type: discovery, body: body.bytes)
    }

    public static func findHost(_ socket: UDPSocket, address: String, deviceID: UInt64, wait: Double = 2) throws -> SteamHost {
        socket.send(probe(deviceID: deviceID), host: address, port: port)
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            if let reply = socket.receiveFrom(timeout: deadline.timeIntervalSinceNow),
               reply.sender == address, let found = host(from: reply) {
                return found
            }
        }
        throw BroadcastError.noReply
    }

    /// Reach a host at a known address, by a preferred network interface if
    /// it answers there. `preferred` lists interface names in order of
    /// preference (a platform puts its wired ones here); each is tried
    /// briefly, and the system's own routing is the fallback. Returns the
    /// socket to go on using, and the interface it is tied to, if any.
    public static func reach(address: String, deviceID: UInt64, preferring preferred: [String])
        throws -> (socket: UDPSocket, host: SteamHost, interface: String?) {
        for interface in preferred {
            if let socket = UDPSocket(interface: interface),
               let host = try? findHost(socket, address: address, deviceID: deviceID, wait: 0.5) {
                return (socket, host, interface)
            }
        }
        guard let socket = UDPSocket() else { throw BroadcastError.noReply }
        return (socket, try findHost(socket, address: address, deviceID: deviceID), nil)
    }

    /// Find Steam hosts on the local network without broadcasting, which
    /// Apple's platforms refuse without an entitlement: send the probe to
    /// every address of the local subnets, one by one. A host answers a
    /// unicast probe exactly as it answers a broadcast.
    public static func discover(_ socket: UDPSocket, deviceID: UInt64, wait: Double = 1.5) -> [SteamHost] {
        let datagram = probe(deviceID: deviceID)
        for address in UDPSocket.localSubnetAddresses() { socket.send(datagram, host: address, port: port) }
        var found: [UInt64: SteamHost] = [:]
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            if let reply = socket.receiveFrom(timeout: deadline.timeIntervalSinceNow), let host = host(from: reply) {
                found[host.clientID] = host
            }
        }
        return found.values.sorted { $0.hostname < $1.hostname }
    }

    /// Pair with a host (docs/remoteplay/pairing.md). `showPIN` is called once
    /// with a four-digit PIN that the user must type into Steam on the host.
    /// On success, the shared secret is stored in `identity`.
    /// `deviceName` and `deviceModel` are what the host is told this device
    /// is called and what kind of device it is, at most 64 characters each.
    public static func pair(_ socket: UDPSocket, host: SteamHost, identity: Identity, deviceName: String,
                            deviceModel: String, showPIN: (String) -> Void) throws {
        let pin = String(format: "%04d", Int.random(in: 1...9999))
        let exchange = SteamCrypto.KeyExchange()
        let requestID = UInt64(UInt32.random(in: 1...UInt32.max))
        let unpairedSecret = identity.secret(forHost: host.clientID)
        var deviceIDBytes = Bytes()
        deviceIDBytes.append(integer: identity.deviceID)

        // Only Steam's servers can open the ticket. A host that completes the
        // key exchange itself does not need it, but the field is required.
        var ticket = ProtoWriter()
        ticket.bytes(1, Bytes(pin.utf8))             // password
        ticket.varint(2, identity.deviceID)          // identifier
        ticket.bytes(3, unpairedSecret)              // payload
        ticket.varint(5, 0)                          // usage: streaming device
        ticket.string(6, deviceName)
        ticket.string(7, deviceModel)                // model
        ticket.string(8, identity.serial)            // serial, at most 32 characters
        ticket.varint(9, 0)                          // provisioning id
        guard let encryptedTicket = SteamCrypto.encryptTicket(ticket.bytes),
              let deviceToken = SteamCrypto.encrypt(deviceIDBytes, key: unpairedSecret)
        else { throw BroadcastError.pairingRefused("could not build the request") }

        var request = ProtoWriter()
        request.bytes(1, deviceToken)
        request.string(2, deviceName)
        request.bytes(3, encryptedTicket)
        request.bytes(4, exchange.maskedPublicKey(pin: pin))
        request.varint(5, requestID)

        showPIN(pin)
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            socket.send(datagram(deviceID: identity.deviceID, type: authorizationRequest, body: request.bytes),
                        host: host.address, port: port)
            let resendAt = Date().addingTimeInterval(3)      // vrlink repeats every 3 s
            while Date() < resendAt {
                guard let reply = socket.receive(timeout: resendAt.timeIntervalSinceNow),
                      let message = parse(reply), message.clientID == host.clientID,
                      message.type == authorizationResponse
                else { continue }
                let result = message.body.varint(1) ?? 7
                if result == 5 { continue }                  // in progress: waiting for the PIN
                guard result == 0 else { throw BroadcastError.pairingRefused("host answered result \(result)") }
                guard let hostKey = message.body.bytes(3) else {
                    // The older route: Steam's servers opened the ticket, so the
                    // secret we put in it is now the shared one.
                    identity.setSecret(unpairedSecret, forHost: host.clientID)
                    return
                }
                // The host proves it derived the same secret by encrypting our device id with it.
                guard let secret = exchange.sharedSecret(maskedPeerKey: hostKey, pin: pin),
                      let proof = message.body.bytes(4),
                      SteamCrypto.decrypt(proof, key: secret) == deviceIDBytes
                else { throw BroadcastError.pairingRefused("the host's proof did not check out (wrong PIN?)") }
                identity.setSecret(secret, forHost: host.clientID)
                var confirmed = ProtoWriter()
                confirmed.varint(1, 0)
                socket.send(datagram(deviceID: identity.deviceID, type: authorizationConfirmed, body: confirmed.bytes),
                            host: host.address, port: port)
                return
            }
        }
        throw BroadcastError.pairingRefused("nobody entered the PIN on the host")
    }

    /// Ask the host to start SteamVR streaming.
    /// Repeats the request once a second, answers the proof challenge, 
    /// and decrypts the session string from the final response
    ///
    /// We roll our own protobuf here because I hate having protobuf as a dependency.
    ///
    /// `deviceVersion` is free text the host is given about this client.
    public static func requestSession(_ socket: UDPSocket, host: SteamHost, identity: Identity,
                                      deviceVersion: String) throws -> SessionArgs {
        let secret = identity.secret(forHost: host.clientID)
        let requestID = UInt64(UInt32.random(in: 1...UInt32.max))
        var deviceIDBytes = Bytes()
        deviceIDBytes.append(integer: identity.deviceID)

        func send(_ type: UInt64, _ body: Bytes) {
            socket.send(datagram(deviceID: identity.deviceID, type: type, body: body),
                        host: host.address, port: port)
        }

        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            // TODO maybe have some consts for all of this
            var request = ProtoWriter()
            request.varint(1, requestID)
            request.varint(2, 1280)                      // maximum_resolution; ignored for VR
            request.varint(3, 800)
            request.varint(4, 2)                         // audio_channel_count
            request.string(5, deviceVersion)             // device_version
            request.bytes(7, SteamCrypto.encrypt(deviceIDBytes, key: secret) ?? [])   // device_token
            request.bytes(8, [])                         // pin
            request.bool(9, true)                        // enable video, audio, input
            request.bool(10, true)
            request.bool(11, true)
            request.bool(12, false)                      // network_test
            request.varint(13, host.clientID)
            for transport: UInt64 in [1, 2, 4] { request.varint(14, transport) }   // UDP, UDPRelay, SDR
            request.bool(15, false)                      // restricted
            request.varint(16, 5)                        // form_factor: VR headset
            request.varint(17, 0)                        // gamepad_count
            request.varint(19, 0)                        // gameid
            request.varint(20, 4)                        // stream_interface: SteamVR. This is what makes it VR Link.
            send(streamingRequest, request.bytes)

            let resendAt = Date().addingTimeInterval(1)
            while Date() < resendAt {
                guard let reply = socket.receive(timeout: resendAt.timeIntervalSinceNow),
                      let message = parse(reply), message.clientID == host.clientID
                else { continue }
                let body = message.body
                if message.type == proofRequest, body.varint(2) == requestID, let challenge = body.bytes(1) {
                    guard body.varint(3) ?? 0 == 0 else {
                        throw BroadcastError.badResponse("host asked to rotate the pairing secret, which is not implemented")
                    }
                    var proof = ProtoWriter()
                    proof.bytes(1, SteamCrypto.encrypt(challenge, key: secret) ?? [])
                    proof.varint(2, requestID)
                    proof.bool(3, false)
                    send(proofResponse, proof.bytes)
                } else if message.type == streamingResponse, body.varint(1) == requestID {
                    let result = body.varint(2) ?? 0
                    if result == 5 { continue }          // InProgress: SteamVR is starting
                    if result == 1 { throw BroadcastError.notPaired }
                    if result != 0 { throw BroadcastError.refused(result: result) }
                    guard let wrappedKey = body.bytes(4),
                          let sessionKey = SteamCrypto.decrypt(wrappedKey, key: secret),
                          let cert = body.string(8).flatMap({ Bytes(hex: $0) }),
                          let text = SteamCrypto.decrypt(cert, key: sessionKey)
                    else { throw BroadcastError.badResponse("session key or session string did not decrypt") }
                    // The host omits its own address; the client prepends the one it used.
                    let string = String(decoding: text, as: UTF8.self)
                    guard let args = SessionArgs(string.hasPrefix("~") ? host.address + string : string)
                    else { throw BroadcastError.badResponse("unexpected session string shape") }
                    return args
                }
            }
        }
        throw BroadcastError.noReply
    }
}
