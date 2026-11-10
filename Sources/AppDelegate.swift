import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let controller = UnlockController()
    private var cameraWindow: CameraWindowController?
    private lazy var previewOverlay = ScanOverlay(method: .skyLight)
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 화면이 잠긴 동안에도 알림을 제때 받도록 App Nap을 막는다.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep], reason: "화면 잠금 감시")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "faceid", accessibilityDescription: "FaceUnlock") {
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "Face"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        controller.start()
        Log.write("앱 시작 (사용: \(Settings.enabled), 카메라 권한: \(Camera.authorized), 손쉬운 사용 권한: \(Typer.trusted), 비밀번호: \(Keychain.exists()))")
    }

    // MARK: 메뉴

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let profile = FaceStore.load()
        let hasPassword = Keychain.exists()

        func info(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        func action(_ title: String, _ selector: Selector, checked: Bool = false, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? selector : nil, keyEquivalent: "")
            item.target = self
            item.state = checked ? .on : .off
            item.isEnabled = enabled
            menu.addItem(item)
        }

        action("얼굴 잠금해제 사용", #selector(toggleEnabled), checked: Settings.enabled)
        menu.addItem(.separator())

        info(profile.map { "얼굴: 등록됨 (샘플 \($0.samples.count)개)" } ?? "얼굴: 미등록")
        info(hasPassword ? "비밀번호: 저장됨" : "비밀번호: 미저장")
        info("카메라 권한: " + (Camera.authorized ? "허용됨" : "필요"))
        info("손쉬운 사용 권한: " + (Typer.trusted ? "허용됨" : "필요"))
        info("최근: \(controller.lastStatus)")
        menu.addItem(.separator())

        action(profile == nil ? "얼굴 등록…" : "얼굴 다시 등록…", #selector(enroll))
        action("얼굴 샘플 추가… (다른 조명·안경 등)", #selector(addSamples), enabled: profile != nil)
        action("인식 테스트…", #selector(test), enabled: profile != nil)
        action(hasPassword ? "로그인 비밀번호 다시 저장…" : "로그인 비밀번호 저장…", #selector(setPassword))
        menu.addItem(.separator())

        let sensitivity = NSMenuItem(title: "민감도", action: nil, keyEquivalent: "")
        let sensitivityMenu = NSMenu()
        for (index, title) in ["엄격 (덜 풀림, 더 안전)", "보통", "느슨 (잘 풀림, 덜 안전)"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(setSensitivity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = Settings.sensitivity == index ? .on : .off
            sensitivityMenu.addItem(item)
        }
        sensitivity.submenu = sensitivityMenu
        menu.addItem(sensitivity)
        action("눈 깜빡임 확인 (사진 방어, 실험적)", #selector(toggleBlink), checked: Settings.requireBlink)
        action("인식 효과 표시", #selector(toggleEffect), checked: Settings.showEffect)
        action("효과 미리 보기", #selector(previewEffect))
        menu.addItem(.separator())

        action("권한 요청…", #selector(requestPermissions))
        action("로그 보기", #selector(openLog))
        action("얼굴·비밀번호 데이터 삭제…", #selector(deleteData), enabled: profile != nil || hasPassword)
        menu.addItem(.separator())
        action("종료", #selector(quit))
    }

    // MARK: 동작

    @objc private func toggleEnabled() {
        if Settings.enabled {
            Settings.enabled = false
            return
        }
        var missing: [String] = []
        if FaceStore.load() == nil { missing.append("얼굴 등록") }
        if !Keychain.exists() { missing.append("로그인 비밀번호 저장") }
        if !Camera.authorized { missing.append("카메라 권한") }
        if !Typer.trusted { missing.append("손쉬운 사용 권한") }
        guard missing.isEmpty else {
            alert("아직 켤 수 없습니다", "먼저 필요한 것: " + missing.joined(separator: ", "))
            return
        }
        Settings.enabled = true
        Log.write("얼굴 잠금해제 켜짐")
    }

    @objc private func enroll() { openCamera(.enroll(append: false)) }
    @objc private func addSamples() { openCamera(.enroll(append: true)) }
    @objc private func test() { openCamera(.test) }

    private func openCamera(_ mode: CameraWindowController.Mode) {
        if let existing = cameraWindow {
            existing.onClose = nil
            existing.close()
        }
        let controller = CameraWindowController(mode: mode)
        controller.onClose = { [weak self, weak controller] in
            if self?.cameraWindow === controller { self?.cameraWindow = nil }
        }
        cameraWindow = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func setPassword() {
        NSApp.activate(ignoringOtherApps: true)
        let dialog = NSAlert()
        dialog.messageText = "로그인 비밀번호 저장"
        dialog.informativeText = "이 Mac의 로그인 비밀번호를 입력하세요. 이 Mac의 키체인에만 저장되고, 얼굴이 확인됐을 때 잠금 화면에 대신 입력됩니다."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        dialog.accessoryView = field
        dialog.addButton(withTitle: "저장")
        dialog.addButton(withTitle: "취소")
        dialog.window.initialFirstResponder = field
        guard dialog.runModal() == .alertFirstButtonReturn else { return }
        let password = field.stringValue
        guard !password.isEmpty else { return }

        if PasswordCheck.verify(password) == .wrong {
            alert("비밀번호가 맞지 않습니다", "로그인 비밀번호와 달라서 저장하지 않았습니다.")
            return
        }
        if Keychain.save(password) {
            Log.write("로그인 비밀번호를 키체인에 저장함")
            alert("저장했습니다", "키체인 접근 앱의 'FaceUnlock 로그인 비밀번호' 항목에서 확인하거나 지울 수 있습니다.")
        } else {
            alert("저장하지 못했습니다", "키체인에 쓰는 중 오류가 났습니다.")
        }
    }

    @objc private func setSensitivity(_ sender: NSMenuItem) {
        Settings.sensitivity = sender.tag
    }

    @objc private func toggleBlink() {
        Settings.requireBlink.toggle()
    }

    @objc private func toggleEffect() {
        Settings.showEffect.toggle()
    }

    @objc private func previewEffect() {
        previewOverlay.show(.scanning)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.previewOverlay.finish(.success, hideAfter: 1.8)
        }
    }

    @objc private func requestPermissions() {
        Camera.requestAccess { _ in }
        if !Typer.trusted { Typer.requestTrust() }
        if Camera.authorized, Typer.trusted {
            alert("권한이 모두 허용되어 있습니다", "")
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Log.url)
    }

    @objc private func deleteData() {
        NSApp.activate(ignoringOtherApps: true)
        let dialog = NSAlert()
        dialog.messageText = "등록된 얼굴과 저장된 비밀번호를 삭제할까요?"
        dialog.informativeText = "얼굴 잠금해제도 함께 꺼집니다."
        dialog.addButton(withTitle: "삭제")
        dialog.addButton(withTitle: "취소")
        guard dialog.runModal() == .alertFirstButtonReturn else { return }
        FaceStore.delete()
        Keychain.delete()
        Settings.enabled = false
        Log.write("얼굴·비밀번호 데이터 삭제")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let dialog = NSAlert()
        dialog.messageText = title
        dialog.informativeText = text
        dialog.runModal()
    }
}
