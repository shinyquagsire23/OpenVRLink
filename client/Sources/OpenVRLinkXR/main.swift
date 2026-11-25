// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import VRLinkAppleAudio
import VRLinkAppleNetwork
import VRLinkCore
import VRLinkOpenXR
import VRLinkOpenXRMetal
import VRLinkPanel
import VRLinkVideoToolbox
import VRLinkXRClient

// macOS OpenXR client executable:
//
//     swift run OpenVRLinkXR [host] [--wivrn] [--pin <digits>] [--pictures <folder>]
//
// OpenVRLinkXR renders into the active macOS OpenXR runtime (such as OXRSys); set `XR_RUNTIME_JSON` to point at a
// specific runtime manifest. Running without a host argument shows an in-headset panel of Steam and WiVRn hosts
// found on the local network, while passing a host (`address`, `steam://address`, or `wivrn://address[:port]`)
// connects right away. VideoToolbox, CoreAudio, microphone capture, and Bonjour discovery are wired into
// `XRClient` here.

setvbuf(stdout, nil, _IOLBF, 0)

var named: String?
var wivrn = false
var wivrnPin: String?
var picturesFolder: String?
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    if argument == "--wivrn" {
        wivrn = true
    } else if argument == "--pictures", let folder = arguments.popFirst() {
        picturesFolder = folder
    } else if argument == "--pin", let digits = arguments.popFirst() {
        wivrnPin = digits
    } else if named == nil, !argument.hasPrefix("-") {
        named = argument
    } else {
        print("usage: OpenVRLinkXR [host] [--wivrn] [--pin <digits>] [--pictures <folder>]")
        exit(2)
    }
}

let model = ClientModel(finder: HostFinder(services: ServiceBrowser(type: WiVRn.serviceType)))
let panel = Panel(model: model, features: [.microphone, .chromaKey])
panel.caption = SystemVersion.named

var audio: AudioOutput?
let microphone = MicrophoneInput()
var platform = XRPlatform(device: SystemVersion.device(named: Host.current().localizedName ?? "Mac"))
platform.preferredInterfaces = { WiredInterfaces.names() }
platform.startAudio = { session in
    DispatchQueue.main.async { audio = AudioOutput(buffer: session.audio) }
}
platform.stopAudio = {
    DispatchQueue.main.async { audio = nil }
}
platform.startMicrophone = { sink in
    DispatchQueue.main.async {
        MicrophoneInput.requestPermission { allowed in
            let started = allowed && microphone.start(into: sink)
            print(started ? "microphone: sending to the host" : "microphone: not available or not permitted")
        }
    }
}
platform.stopMicrophone = {
    DispatchQueue.main.async { microphone.stop() }
}

let graphics = MetalXRGraphics()
graphics.picturesFolder = picturesFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
let client: XRClient<MetalXRGraphics, VideoDecoder>
do {
    client = try XRClient(applicationName: "OpenVRLink", graphics: graphics, decoder: VideoDecoder(), model: model, panel: panel,
                          platform: platform) { Log.note($0) }
} catch {
    print("could not start OpenXR: \(error)")
    exit(1)
}

// Automatically submit `--pin` when connecting to an unpaired WiVRn host in headless runs.
if let wivrnPin {
    let answer = model.onChange
    model.onChange = {
        answer?()
        if model.state.askingForPin { model.answerPin(wivrnPin) }
    }
}
if let named {
    guard let target = ClientModel.Target(parsing: named, kind: wivrn ? .wivrn : .steam) else {
        print("not a host address: \(named)")
        exit(2)
    }
    model.connect(to: target)
}

// Shut down the OpenXR session cleanly on SIGINT/SIGTERM so the host receives a disconnect notice.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let quitSignals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { client.quit() }
    source.resume()
    return source
}

let frameThread = Thread {
    do {
        try client.run()
    } catch {
        print("OpenXR session failed: \(error)")
    }
    // Allow the session thread time to send its disconnect packet before exiting.
    Thread.sleep(forTimeInterval: 0.6)
    exit(0)
}
frameThread.name = "openxr"
frameThread.qualityOfService = .userInteractive
frameThread.start()
dispatchMain()
