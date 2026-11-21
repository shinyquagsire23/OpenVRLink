// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Win32 GUI window for `openvrlink-companion` on Windows. Displays each component's
// installation status with Install/Update and Uninstall buttons, plus version info and a
// self-update button at the bottom.

#if os(Windows)
import CompanionKit
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import WinAPI
import CRT
import WinSDK

enum Console {
    /// Attaches stdout/stderr to the parent console when run with CLI arguments from a
    /// terminal, unless output has already been redirected to a file or pipe.
    static func attach() {
        func isMissing(_ handle: DWORD) -> Bool {
            let file = GetStdHandle(handle)
            return file == nil || file == INVALID_HANDLE_VALUE || GetFileType(file) == DWORD(FILE_TYPE_UNKNOWN)
        }
        guard isMissing(STD_OUTPUT_HANDLE) || isMissing(STD_ERROR_HANDLE), AttachConsole(DWORD(bitPattern: -1) /* ATTACH_PARENT_PROCESS */) else { return }
        if isMissing(STD_OUTPUT_HANDLE) { freopen("CONOUT$", "w", stdout) }
        if isMissing(STD_ERROR_HANDLE) { freopen("CONOUT$", "w", stderr) }
    }
}

/// Queues closures from background worker threads onto the Win32 UI thread.
private enum MainThread {
    static let message = UINT(WM_APP) + 1
    private static var lock = SRWLOCK()
    private static var waiting: [() -> Void] = []
    static var window: HWND?

    static func run(_ work: @escaping () -> Void) {
        AcquireSRWLockExclusive(&lock)
        waiting.append(work)
        ReleaseSRWLockExclusive(&lock)
        PostMessageW(window, message, 0, 0)
    }

    static func drain() {
        AcquireSRWLockExclusive(&lock)
        let work = waiting
        waiting = []
        ReleaseSRWLockExclusive(&lock)
        for item in work { item() }
    }
}

private enum Control: Int {
    case modelsAction = 100, modelsRemove, driverAction, driverRemove, update, encodingAction, encodingRemove

    static func action(_ component: Component) -> Control {
        switch component {
        case .models: return .modelsAction
        case .driver: return .driverAction
        case .encodingSize: return .encodingAction
        }
    }
    static func remove(_ component: Component) -> Control {
        switch component {
        case .models: return .modelsRemove
        case .driver: return .driverRemove
        case .encodingSize: return .encodingRemove
        }
    }
}

private enum UpdateState {
    case unknown
    case checking
    case newest
    case available(Release.Offer)
    case fetching(Release.Offer, String)
    case failed(String)
}

private final class CompanionWindow {
    var window: HWND?
    var scale = 1.0
    var font: HFONT?, bold: HFONT?
    var steamVR: HWND?, notice: HWND?, version: HWND?, updateButton: HWND?
    var rows: [Component: (detail: HWND?, action: HWND?, remove: HWND?)] = [:]
    var grayControls: Set<UInt> = []
    var update = UpdateState.unknown
    var changed = false
    var lastRefresh: UInt64 = 0

    func px(_ points: Int) -> Int32 { Int32((Double(points) * scale).rounded()) }

    func child(_ kind: String, _ text: String, style: Int32, _ x: Int, _ y: Int, _ width: Int, _ height: Int, id: Int = 0, bold isBold: Bool = false) -> HWND? {
        let control = CreateWindowExW(0, kind.wide, text.wide, DWORD(WS_CHILD | WS_VISIBLE | style), px(x), px(y), px(width), px(height),
                                      window, HMENU(bitPattern: UInt(id)), GetModuleHandleW(nil), nil)
        SendMessageW(control, UINT(WM_SETFONT), WPARAM(UInt(bitPattern: isBold ? bold : font)), 1)
        return control
    }

    static let width = 620, margin = 18, rowHeight = 92

    func build() {
        let dpi = GetDpiForWindow(window)
        scale = Double(dpi == 0 ? 96 : dpi) / 96
        func makeFont(weight: Int32) -> HFONT? {
            CreateFontW(-px(12), 0, 0, 0, weight, 0, 0, 0, DWORD(DEFAULT_CHARSET), 0, 0, DWORD(CLEARTYPE_QUALITY), 0, "Segoe UI".wide)
        }
        font = makeFont(weight: FW_NORMAL)
        bold = makeFont(weight: FW_SEMIBOLD)
        let margin = CompanionWindow.margin, inner = CompanionWindow.width - 2 * margin
        let label = SS_LEFT | SS_NOPREFIX
        steamVR = child("STATIC", "", style: label | SS_PATHELLIPSIS, margin, 14, inner, 18)
        if let steamVR { grayControls.insert(UInt(bitPattern: steamVR)) }
        var y = 44
        for component in Component.allCases {
            _ = child("STATIC", "", style: SS_ETCHEDHORZ, margin, y, inner, 2)
            _ = child("STATIC", component.title, style: label, margin, y + 14, inner - 150, 20, bold: true)
            let detail = child("STATIC", "", style: label | SS_EDITCONTROL, margin, y + 36, inner - 150, 50)
            if let detail { grayControls.insert(UInt(bitPattern: detail)) }
            let action = child("BUTTON", "Install", style: BS_PUSHBUTTON | WS_TABSTOP, margin + inner - 132, y + 16, 96, 28, id: Control.action(component).rawValue)
            let remove = child("BUTTON", "\u{2715}", style: BS_PUSHBUTTON | WS_TABSTOP, margin + inner - 30, y + 16, 30, 28, id: Control.remove(component).rawValue)
            rows[component] = (detail, action, remove)
            y += CompanionWindow.rowHeight
        }
        _ = child("STATIC", "", style: SS_ETCHEDHORZ, margin, y, inner, 2)
        notice = child("STATIC", "", style: label, margin, y + 12, inner, 20)
        version = child("STATIC", "", style: label | SS_EDITCONTROL, margin, y + 40, inner - 190, 38)
        if let version { grayControls.insert(UInt(bitPattern: version)) }
        updateButton = child("BUTTON", "Check for updates", style: BS_PUSHBUTTON | WS_TABSTOP, margin + inner - 170, y + 38, 170, 28, id: Control.update.rawValue)
        // Size the frame around the content.
        var frame = RECT(left: 0, top: 0, right: px(CompanionWindow.width), bottom: px(y + 90))
        AdjustWindowRectExForDpi(&frame, DWORD(GetWindowLongW(window, GWL_STYLE)), false, 0, dpi == 0 ? 96 : dpi)
        SetWindowPos(window, nil, 0, 0, frame.right - frame.left, frame.bottom - frame.top, UINT(SWP_NOMOVE | SWP_NOZORDER))
    }

    func set(_ control: HWND?, _ text: String) {
        // Only call SetWindowTextW when the text actually changes to avoid redraw flicker.
        var current = [WCHAR](repeating: 0, count: 1024)
        let length = GetWindowTextW(control, &current, Int32(current.count))
        if String(decoding: current[..<Int(length)], as: UTF16.self) != text { SetWindowTextW(control, text.wide) }
    }

    func refresh() {
        lastRefresh = GetTickCount64()
        do {
            let setup = try makeSetup()
            setup.clearLeftovers()
            set(steamVR, "SteamVR: \(setup.found.steamVR.map { Steam.nativePath($0) } ?? "not found")")
            for component in Component.allCases {
                guard let row = rows[component] else { continue }
                let state = setup.state(of: component)
                set(row.detail, state.detail)
                set(row.action, state.action ?? (state.kind == .installed ? (component == .encodingSize ? "Applied" : "Installed") : "Install"))
                EnableWindow(row.action, state.action != nil)
                EnableWindow(row.remove, state.isInstalled)
            }
        } catch {
            set(steamVR, "\(error)")
        }
        set(notice, changed ? "Restart SteamVR for the changes to take effect." : "")
        let name = "OpenVRLink companion \(Machine.version)"
        var button = "Check for updates", enabled = true
        switch update {
        case .unknown: set(version, name)
        case .checking:
            set(version, "\(name)\nChecking for updates\u{2026}")
            enabled = false
        case .newest: set(version, "\(name)\nUp to date.")
        case .available(let offer):
            set(version, "\(name)\nVersion \(offer.version) is available.")
            button = "Update to \(offer.version)"
        case .fetching(let offer, let progress):
            set(version, "\(name)\nDownloading version \(offer.version)\u{2026} \(progress)")
            button = "Updating\u{2026}"
            enabled = false
        case .failed(let why): set(version, "\(name)\n\(why)")
        }
        set(updateButton, button)
        EnableWindow(updateButton, enabled)
    }

    func tell(_ text: String, asking: Bool = false, warning: Bool = false) -> Bool {
        let style = asking ? MB_YESNO | MB_ICONQUESTION : MB_OK | (warning ? MB_ICONWARNING : MB_ICONINFORMATION)
        return MessageBoxW(window, text.wide, "OpenVRLink companion".wide, UINT(style)) == IDYES
    }

    func act(on component: Component, removing: Bool) {
        do {
            let setup = try makeSetup()
            if removing {
                let question = component == .encodingSize ? "Reset VR Link's encoding size to SteamVR defaults?" : "Uninstall \(component.title)?"
                guard tell(question, asking: true) else { return }
                _ = try setup.uninstall(component)
            } else {
                _ = try setup.install(component)
            }
            changed = true
        } catch {
            _ = tell("\(error)", warning: true)
        }
        refresh()
    }

    /// Runs `work` on a detached Win32 thread.
    func background(_ work: @escaping () -> Void) {
        final class Work {
            let run: () -> Void
            init(_ run: @escaping () -> Void) { self.run = run }
        }
        let boxed = Unmanaged.passRetained(Work(work)).toOpaque()
        let thread = CreateThread(nil, 0, { boxed in
            Unmanaged<Work>.fromOpaque(boxed!).takeRetainedValue().run()
            return 0
        }, boxed, 0, nil)
        CloseHandle(thread)
    }

    func checkForUpdates(quietly: Bool) {
        update = .checking
        refresh()
        background {
            let result = Result { try Updater.check() }
            MainThread.run {
                switch result {
                case .success(let offer): self.update = offer.map { .available($0) } ?? .newest
                // Suppress errors from the automatic startup check (e.g. when offline).
                case .failure(let error): self.update = quietly ? .unknown : .failed("Update check failed: \(error)")
                }
                self.refresh()
            }
        }
    }

    func fetch(_ offer: Release.Offer) {
        update = .fetching(offer, "")
        refresh()
        background {
            var shown = -1
            let result = Result {
                try Updater.fetch(offer) { got, total in
                    guard let total, total > 0 else { return }
                    let percent = got * 100 / total
                    guard percent != shown else { return }
                    shown = percent
                    MainThread.run {
                        self.update = .fetching(offer, "\(percent)%")
                        self.refresh()
                    }
                }
            }
            MainThread.run {
                do {
                    try Updater.finish(try result.get())
                    Updater.relaunch()
                    DestroyWindow(self.window)
                } catch {
                    self.update = .failed("Update failed: \(error)")
                    self.refresh()
                }
            }
        }
    }

    func command(_ id: Int) {
        switch Control(rawValue: id) {
        case .modelsAction: act(on: .models, removing: false)
        case .modelsRemove: act(on: .models, removing: true)
        case .driverAction: act(on: .driver, removing: false)
        case .driverRemove: act(on: .driver, removing: true)
        case .encodingAction: act(on: .encodingSize, removing: false)
        case .encodingRemove: act(on: .encodingSize, removing: true)
        case .update:
            if case .available(let offer) = update { fetch(offer) } else { checkForUpdates(quietly: false) }
        case nil: break
        }
    }
}

private var theWindow = CompanionWindow()

private let windowProcedure: WNDPROC = { window, message, wParam, lParam in
    switch message {
    case UINT(WM_COMMAND):
        if (wParam >> 16) & 0xFFFF == UInt64(BN_CLICKED) { theWindow.command(Int(wParam & 0xFFFF)) }
        return 0
    case UINT(WM_CTLCOLORSTATIC):
        // Draw static labels transparently on the window background and use gray text for secondary labels.
        let context = HDC(bitPattern: UInt(wParam))
        SetBkMode(context, TRANSPARENT)
        if theWindow.grayControls.contains(UInt(truncatingIfNeeded: lParam)) { SetTextColor(context, GetSysColor(COLOR_GRAYTEXT)) }
        return LRESULT(Int(bitPattern: GetSysColorBrush(COLOR_WINDOW)))
    case UINT(WM_ACTIVATE):
        // Re-check installation state when the window regains focus in case Steam or SteamVR changed on disk.
        if wParam & 0xFFFF != 0, GetTickCount64() - theWindow.lastRefresh > 2000, !theWindow.rows.isEmpty { theWindow.refresh() }
    case MainThread.message:
        MainThread.drain()
        return 0
    case UINT(WM_DESTROY):
        PostQuitMessage(0)
        return 0
    default: break
    }
    return DefWindowProcW(window, message, wParam, lParam)
}

/// Renders `window`'s client area to a 32-bit `.bmp` file for headless layout inspection.
private func snapshot(of window: HWND?, to file: URL) throws {
    var area = RECT()
    GetClientRect(window, &area)
    let width = area.right, height = area.bottom
    var info = BITMAPINFO()
    info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
    info.bmiHeader.biWidth = width
    info.bmiHeader.biHeight = height   // Positive height writes a standard bottom-up BMP.
    info.bmiHeader.biPlanes = 1
    info.bmiHeader.biBitCount = 32
    var pixels: UnsafeMutableRawPointer?
    let screen = GetDC(window), memory = CreateCompatibleDC(screen)
    defer { ReleaseDC(window, screen); DeleteDC(memory) }
    guard let bitmap = CreateDIBSection(memory, &info, UINT(DIB_RGB_COLORS), &pixels, nil, 0), let pixels else { throw Failure("could not allocate bitmap for window snapshot") }
    defer { DeleteObject(bitmap) }
    let before = SelectObject(memory, bitmap)
    PrintWindow(window, memory, 1 /* PW_CLIENTONLY */ | 2 /* PW_RENDERFULLCONTENT */)
    GdiFlush()
    SelectObject(memory, before)
    let size = Int(width) * Int(height) * 4
    var data = Data()
    func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
    append(UInt16(0x4D42)); append(UInt32(54 + size)); append(UInt32(0)); append(UInt32(54))
    append(info.bmiHeader)
    data.append(Data(bytes: pixels, count: size))
    try data.write(to: file)
}

func runWindow(snapshot file: URL?, afterUpdate: Bool = false) throws {
    Updater.clearLeftovers(patiently: afterUpdate)
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_SYSTEM_AWARE)
    var controls = INITCOMMONCONTROLSEX(dwSize: DWORD(MemoryLayout<INITCOMMONCONTROLSEX>.size), dwICC: DWORD(ICC_STANDARD_CLASSES))
    InitCommonControlsEx(&controls)
    let instance = GetModuleHandleW(nil)
    let className = "OpenVRLinkCompanion".wide
    try className.withUnsafeBufferPointer { className in
        var windowClass = WNDCLASSEXW()
        windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
        windowClass.lpfnWndProc = windowProcedure
        windowClass.hInstance = instance
        windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512 /* IDC_ARROW */))
        windowClass.hIcon = LoadIconW(nil, UnsafePointer<WCHAR>(bitPattern: 32512 /* IDI_APPLICATION */))
        windowClass.hbrBackground = GetSysColorBrush(COLOR_WINDOW)
        windowClass.lpszClassName = className.baseAddress
        guard RegisterClassExW(&windowClass) != 0 else { throw Failure("could not register Win32 window class (error \(GetLastError()))") }
        let style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX
        guard let window = CreateWindowExW(0, className.baseAddress, "OpenVRLink companion".wide, DWORD(style),
                                           CW_USEDEFAULT, CW_USEDEFAULT, 640, 400, nil, nil, instance, nil)
        else { throw Failure("could not create Win32 window (error \(GetLastError()))") }
        theWindow.window = window
        MainThread.window = window
        theWindow.build()
        theWindow.refresh()
        if let file {
            ShowWindow(window, SW_SHOWNOACTIVATE)
            UpdateWindow(window)
            try snapshot(of: window, to: file)
            DestroyWindow(window)
            return
        }
        ShowWindow(window, SW_SHOWNORMAL)
        UpdateWindow(window)
        theWindow.checkForUpdates(quietly: true)
        var message = MSG()
        while GetMessageW(&message, nil, 0, 0) {
            if IsDialogMessageW(window, &message) { continue }
            TranslateMessage(&message)
            DispatchMessageW(&message)
        }
    }
}

/// Copies the running executable to `output` and embeds `driver` (plus an optional
/// `version` string) as Win32 `RT_RCDATA` resources read by `Machine.resource`.
func pack(to output: URL, driver: URL, version: String?) throws {
    let library: Data
    do { library = try Data(contentsOf: driver) } catch { throw Failure("\(driver.path): \(OS.describe(error))") }
    let files = FileManager.default
    if files.fileExists(atPath: output.path) { try files.removeItem(at: output) }
    try files.copyItem(at: Machine.executable, to: output)
    func failed(_ step: String) -> Failure { Failure("\(output.path): \(step) failed (error \(GetLastError()))") }
    guard let update = BeginUpdateResourceW(Steam.nativePath(output).wide, false) else { throw failed("BeginUpdateResourceW") }
    func add(_ name: String, _ data: Data) -> Bool {
        var bytes = [UInt8](data)
        return UpdateResourceW(update, UnsafePointer<WCHAR>(bitPattern: 10 /* RT_RCDATA */), name.wide, 0x0409 /* English (US) */, &bytes, DWORD(bytes.count))
    }
    guard add("DRIVER", library), version.map({ add("VERSION", Data($0.utf8)) }) ?? true else {
        EndUpdateResourceW(update, true)
        throw failed("UpdateResourceW")
    }
    guard EndUpdateResourceW(update, false) else { throw failed("EndUpdateResourceW") }
    // Verify that the packed binary runs and reports the expected version.
    guard let said = Machine.output(of: output, ["version"])?.trimmed, said == version ?? Machine.version else {
        throw Failure("\(output.path) failed verification after packing")
    }
    print("\(output.path): version \(said), driver \(library.count) bytes")
}
#endif
