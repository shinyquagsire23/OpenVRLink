// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import VRLinkAppleAudio
import VRLinkAppleNetwork
import VRLinkCore
import VRLinkOpenXR
import VRLinkOpenXRMetal
import VRLinkVideoToolbox

/// Runs OpenVRLink as a macOS OpenXR application:
///
///     swift run OpenVRLinkXR [host address] [--wivrn] [--pin <digits>] [--mic] [--pictures <folder>]
///
/// Connects to a Steam or WiVRn host and renders into the active macOS OpenXR runtime (such as OXRSys).
/// Set `XR_RUNTIME_JSON` to override the active runtime manifest. Streaming starts when the OpenXR
/// session begins and stops when the session ends.

setvbuf(stdout, nil, _IOLBF, 0)

var hostAddress: String?
var wivrn = false
var wivrnPin: String?
var useMicrophone = false
var picturesFolder: String?
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    if argument == "--wivrn" {
        wivrn = true
    } else if argument == "--mic" {
        useMicrophone = true
    } else if argument == "--pictures", let folder = arguments.popFirst() {
        picturesFolder = folder
    } else if argument == "--pin", let digits = arguments.popFirst() {
        wivrnPin = digits
    } else if hostAddress == nil, !argument.hasPrefix("-") {
        hostAddress = argument
    } else {
        print("usage: OpenVRLinkXR [host address] [--wivrn] [--pin <digits>] [--mic] [--pictures <folder>]")
        exit(2)
    }
}

/// Discovers Steam hosts on the local network that offer VR Link, preferring a previously paired host.
func findSteamHost() -> String? {
    print("looking for Steam hosts")
    let identity = Identity()
    guard let searcher = UDPSocket() else { return nil }
    let usable = Broadcast.discover(searcher, deviceID: identity.deviceID).filter(\.offersVRLink)
    for found in usable { print("  \(found.hostname) at \(found.address)") }
    return (usable.first { identity.isPaired(withHost: $0.clientID) } ?? usable.first)?.address
}

/// Browses mDNS for up to 5 seconds and returns the first discovered WiVRn host.
func findWiVRnHost() -> String? {
    print("looking for WiVRn hosts")
    var address: String?
    let browser = ServiceBrowser(type: WiVRn.serviceType)
    let found = DispatchSemaphore(value: 0)
    browser.start { services in
        guard let first = services.first, address == nil else { return }
        address = first.host
        found.signal()
    }
    _ = withExtendedLifetime(browser) { found.wait(timeout: .now() + 5) }
    return address
}

let settings = Settings.load()
let link = StreamLink(decoder: VideoDecoder())
link.onStatus = { print($0) }

var audio: AudioOutput?
let microphone = MicrophoneInput()
link.onStarted = { session in
    DispatchQueue.main.async {
        audio = AudioOutput(buffer: session.audio)
        guard useMicrophone else { return }
        MicrophoneInput.requestPermission { allowed in
            let started = allowed && microphone.start(into: session.microphoneSink)
            print(started ? "microphone: sending to the host" : "microphone: not available or not permitted")
        }
    }
}
link.onStopped = {
    DispatchQueue.main.async {
        microphone.stop()
        audio = nil
    }
}

let graphics = MetalXRGraphics()
graphics.picturesFolder = picturesFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
let display: XRDisplay<MetalXRGraphics>
do {
    display = try XRDisplay(applicationName: "OpenVRLink", graphics: graphics, frames: link.frames) { Log.note($0) }
} catch {
    print("could not start OpenXR: \(error)")
    exit(1)
}
display.streamingSession = { link.session }
display.chromaKey = { settings.chromaKeying(inGame: link.session?.sceneApplicationRunning ?? false) }
display.onPaused = { link.stop() }
display.onReady = { measured in
    var profile = measured
    profile.systemName = SystemVersion.name
    profile.clientVersion = SystemVersion.client
    profile.eyeFrusta = profile.eyeFrusta.map {
        $0.scaled(horizontal: settings.fovScaleHorizontal, vertical: settings.fovScaleVertical)
    }
    // Forward the OpenXR stage bounds to the host as the room chaperone boundary when available.
    link.playSpace = PlaySpace(origin: PlaySpace.trackingSpace.origin, boundary: display.boundary())

    var address = hostAddress ?? (wivrn ? findWiVRnHost() : findSteamHost())
    // Parse an optional ":port" suffix when connecting to a WiVRn host on a non-default port.
    var port: UInt16?
    if wivrn, let whole = address, let colon = whole.lastIndex(of: ":"), let given = UInt16(whole[whole.index(after: colon)...]) {
        port = given
        address = String(whole[..<colon])
    }
    guard let address else {
        print("no host found; pass a host address on the command line")
        display.quit()
        return
    }
    var connector = HostConnector(deviceName: HostConnector.name(of: Host.current().localizedName ?? "Mac"),
                                  deviceModel: display.instance.systemName(), systemVersion: SystemVersion.named)
    connector.microphone = useMicrophone
    connector.preferredInterfaces = { WiredInterfaces.names() }
    connector.keepLooking = false
    connector.log = { Log.note($0) }
    connector.askPin = {
        if let wivrnPin { return wivrnPin }
        print("Type the PIN shown on the host: ", terminator: "")
        return readLine()?.trimmingCharacters(in: .whitespaces)
    }
    var inputs = StreamLink<VideoDecoder>.Inputs(head: { display.input.head() }, hands: { display.input.hands() })
    inputs.haptic = { display.input.vibrate($0) }
    inputs.refreshRateRequested = { display.requestRefreshRate($0) }
    link.start(wivrn ? .wivrn : .steam, address: address, port: port, profile: profile, connector: connector, inputs: inputs)
}

// Shut down the OpenXR session cleanly on SIGINT/SIGTERM so the host receives a disconnect notice.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let quitSignals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { display.quit() }
    source.resume()
    return source
}

let frameThread = Thread {
    do {
        try display.run()
    } catch {
        print("OpenXR session failed: \(error)")
    }
    link.stop(leaving: true)
    // Allow the session thread time to send its disconnect packet before exiting.
    Thread.sleep(forTimeInterval: 0.6)
    exit(0)
}
frameThread.name = "openxr"
frameThread.qualityOfService = .userInteractive
frameThread.start()
dispatchMain()
