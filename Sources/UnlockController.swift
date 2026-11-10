import AppKit
import AVFoundation

/// 화면이 잠긴 상태에서 화면이 켜지거나 입력이 감지되면 얼굴을 확인하고,
/// 일치하면 키체인의 로그인 비밀번호를 잠금 화면에 입력한다.
final class UnlockController {
    private static let scanSeconds: TimeInterval = 8
    private static let requiredStreak = 3
    private static let maxScansPerLock = 3
    private static let maxFailedTypes = 2
    /// 잠근 뒤, 그리고 마지막 입력 뒤 이만큼 조용해야 다음 입력을 "돌아왔다"는 신호로 본다.
    private static let quietSeconds: TimeInterval = 1.5

    private let camera = Camera()
    private let analyzer = FaceAnalyzer()
    private lazy var overlay = ScanOverlay(method: .skyLight)

    private var scanning = false
    private var scanID = 0
    private var profile: FaceProfile?
    private var threshold: Float = 0
    private var streak = 0
    private var blink = BlinkDetector()
    private var blinkSeen = false

    private var lockedAt = Date()
    private var scansThisLock = 0
    private var lastPasswordUnlock = Date()
    private var typedAt: Date?
    private var failedTypes = 0
    /// 얼굴이 일치한 뒤 한동안은 새 스캔을 시작하지 않는다.
    /// (앱이 직접 보내는 키 입력을 "사용자가 돌아왔다"로 착각하지 않도록)
    private var suppressScansUntil = Date.distantPast

    private var idleTimer: Timer?
    private var previousIdle: TimeInterval = 0

    private(set) var lastStatus = "대기 중"

    func start() {
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) {
            [weak self] _ in self?.screenLocked()
        }
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) {
            [weak self] _ in self?.screenUnlocked()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) {
            [weak self] _ in self?.woke("화면 켜짐")
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in self?.woke("잠자기 해제")
        }
        camera.onFrame = { [weak self] buffer in
            guard let self else { return }
            let result = self.analyzer.analyze(buffer)
            DispatchQueue.main.async { self.handle(result) }
        }
    }

    // MARK: 잠금 / 해제 이벤트

    private func screenLocked() {
        lockedAt = Date()
        scansThisLock = 0
        typedAt = nil
        note("화면 잠김")
        startIdleWatch()
    }

    private func screenUnlocked() {
        idleTimer?.invalidate()
        idleTimer = nil
        if scanning { endScan("잠금 해제됨") }
        if let typedAt, Date().timeIntervalSince(typedAt) < 6 {
            note("얼굴로 잠금 해제됨")
        } else {
            lastPasswordUnlock = Date()
            note("직접 잠금 해제됨")
        }
        failedTypes = 0
        typedAt = nil
    }

    private func woke(_ reason: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let locked = ScreenLock.isLocked
            Log.write("\(reason) 알림 (잠김: \(locked ? "예" : "아니오"))")
            if locked { self.beginScan(reason: reason) }
        }
    }

    /// 화면이 켜진 채 잠겨 있을 때, 한동안 조용하다가 키보드·마우스 입력이 들어오면 스캔한다.
    private func startIdleWatch() {
        idleTimer?.invalidate()
        previousIdle = 0
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, ScreenLock.isLocked else { return }
            let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
            let previous = self.previousIdle
            self.previousIdle = idle
            // 유휴 시간이 줄었다 = 방금 키보드·마우스·트랙패드 입력이 있었다.
            guard idle < previous, !self.scanning, Date() >= self.suppressScansUntil else { return }
            let lockAge = Date().timeIntervalSince(self.lockedAt)
            Log.write(String(format: "잠금 중 입력 감지 (직전 유휴 %.1f초, 잠근 지 %.1f초)", previous, lockAge))
            if previous >= Self.quietSeconds, lockAge >= Self.quietSeconds {
                self.beginScan(reason: "입력 감지")
            }
        }
    }

    // MARK: 스캔

    private func beginScan(reason: String) {
        guard !scanning, Date() >= suppressScansUntil else { return }
        guard Settings.enabled else { note("건너뜀: 얼굴 잠금해제가 꺼져 있음"); return }
        guard let profile = FaceStore.load(), !profile.samples.isEmpty else { note("건너뜀: 얼굴 미등록"); return }
        guard Keychain.exists() else { note("건너뜀: 비밀번호 미저장"); return }
        guard Camera.authorized else { note("건너뜀: 카메라 권한 없음"); return }
        guard Typer.trusted else { note("건너뜀: 손쉬운 사용 권한 없음"); return }
        guard failedTypes < Self.maxFailedTypes else { note("건너뜀: 입력 실패 누적, 직접 잠금 해제 필요"); return }
        guard scansThisLock < Self.maxScansPerLock else { note("건너뜀: 이번 잠금의 스캔 횟수 초과"); return }
        let hours = Date().timeIntervalSince(lastPasswordUnlock) / 3600
        guard hours < Settings.maxHoursSincePassword else {
            note("건너뜀: 직접 잠금 해제한 지 \(Int(hours))시간 경과")
            return
        }
        guard camera.start() else { note("건너뜀: 카메라를 열지 못함"); return }

        self.profile = profile
        threshold = FaceMatcher.threshold(for: profile)
        streak = 0
        blink = BlinkDetector()
        blinkSeen = false
        scanning = true
        scanID += 1
        scansThisLock += 1
        note("스캔 시작 (\(reason))")
        if Settings.showEffect { overlay.show(.scanning) }

        let id = scanID
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scanSeconds) { [weak self] in
            guard let self, self.scanning, self.scanID == id else { return }
            self.endScan("시간 초과: 얼굴을 확인하지 못함", effect: .failure)
        }
    }

    /// effect가 없으면(직접 잠금을 푼 경우 등) 표시를 조용히 지운다.
    private func endScan(_ why: String, effect: ScanHUDView.State? = nil) {
        scanning = false
        camera.stop()
        if Settings.showEffect {
            if let effect {
                overlay.finish(effect, hideAfter: effect == .success ? 1.8 : 1.4)
            } else {
                overlay.hide()
            }
        }
        note("스캔 종료 (\(why))")
    }

    private func handle(_ result: FrameResult) {
        guard scanning, let profile else { return }
        guard ScreenLock.isLocked else { endScan("이미 잠금 해제됨"); return }
        guard case .face(let reading) = result else { streak = 0; return }

        if let openness = reading.eyeOpenness, blink.feed(openness) { blinkSeen = true }
        let score = FaceMatcher.score(reading.embedding, against: profile.samples)
        streak = score <= threshold ? streak + 1 : 0
        Log.write(String(format: "프레임: 거리 %.3f / 기준 %.3f / 연속 %d", score, threshold, streak))

        if streak >= Self.requiredStreak, !Settings.requireBlink || blinkSeen {
            suppressScansUntil = Date().addingTimeInterval(6)
            endScan("얼굴 일치", effect: .success)
            unlock()
        }
    }

    // MARK: 비밀번호 입력

    private func unlock() {
        guard ScreenLock.isLocked else { return }
        Typer.nudge()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, ScreenLock.isLocked else { return }
            guard let password = Keychain.read() else { self.note("키체인에서 비밀번호를 읽지 못함"); return }
            self.typedAt = Date()
            Typer.clearField()
            guard Typer.type(password) else { self.note("입력 중단: 도중에 잠금이 풀림"); return }
            Typer.pressReturn()
            self.note("비밀번호 입력함")

            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, self.typedAt != nil, ScreenLock.isLocked else { return }
                self.typedAt = nil
                self.failedTypes += 1
                self.note("입력했지만 잠금이 풀리지 않음 (\(self.failedTypes)회)")
            }
        }
    }

    private func note(_ message: String) {
        lastStatus = message
        Log.write(message)
    }
}
