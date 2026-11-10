import AppKit
import AVFoundation

/// 얼굴 등록과 인식 테스트에 쓰는 카메라 창.
final class CameraWindowController: NSWindowController, NSWindowDelegate {
    enum Mode {
        case enroll(append: Bool)
        case test
    }

    private static let targetSamples = 15
    private static let sampleInterval: TimeInterval = 0.4

    private let mode: Mode
    private let camera = Camera()
    private let analyzer = FaceAnalyzer()
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let actionButton = NSButton(title: "", target: nil, action: nil)

    private var collecting = false
    private var finished = false
    private var samples: [[Float]] = []
    private var lastSampleAt = Date.distantPast
    private var blink = BlinkDetector()
    private var profile: FaceProfile?

    var onClose: (() -> Void)?

    init(mode: Mode) {
        self.mode = mode
        previewLayer = AVCaptureVideoPreviewLayer(session: camera.session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 470),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        buildUI()
        startCamera()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let preview = NSView(frame: NSRect(x: 20, y: 180, width: 480, height: 270))
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.backgroundColor = NSColor.black.cgColor
        previewLayer.cornerRadius = 8
        previewLayer.masksToBounds = true
        preview.layer = previewLayer
        preview.wantsLayer = true
        content.addSubview(preview)

        statusLabel.frame = NSRect(x: 20, y: 84, width: 480, height: 84)
        statusLabel.font = .systemFont(ofSize: 14)
        content.addSubview(statusLabel)

        progress.frame = NSRect(x: 20, y: 58, width: 480, height: 16)
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = Double(Self.targetSamples)
        content.addSubview(progress)

        actionButton.frame = NSRect(x: 370, y: 14, width: 130, height: 32)
        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(actionPressed)
        content.addSubview(actionButton)

        switch mode {
        case .enroll(let append):
            window?.title = append ? "얼굴 샘플 추가" : "얼굴 등록"
            statusLabel.stringValue = "화면을 정면으로 보고 [등록 시작]을 누르세요.\n등록 중에는 고개를 아주 조금씩 천천히 움직여 주세요."
            actionButton.title = "등록 시작"
        case .test:
            window?.title = "인식 테스트"
            progress.isHidden = true
            actionButton.title = "닫기"
            profile = FaceStore.load()
            statusLabel.stringValue = profile == nil ? "등록된 얼굴이 없습니다. 먼저 얼굴을 등록하세요." : "카메라를 준비하는 중…"
        }
    }

    private func startCamera() {
        Camera.requestAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.statusLabel.stringValue = "카메라 권한이 없습니다.\n시스템 설정 > 개인정보 보호 및 보안 > 카메라에서 FaceUnlock을 허용해 주세요."
                self.actionButton.isEnabled = false
                return
            }
            self.camera.onFrame = { [weak self] buffer in
                guard let self else { return }
                let result = self.analyzer.analyze(buffer)
                DispatchQueue.main.async { self.handle(result) }
            }
            guard self.camera.start() else {
                self.statusLabel.stringValue = "내장 카메라를 열지 못했습니다."
                return
            }
            // 거울처럼 보이도록 좌우 반전
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let connection = self?.previewLayer.connection, connection.isVideoMirroringSupported else { return }
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
    }

    @objc private func actionPressed() {
        switch mode {
        case .enroll:
            if finished {
                close()
            } else if !collecting {
                samples.removeAll()
                collecting = true
                actionButton.isEnabled = false
            }
        case .test:
            close()
        }
    }

    private func handle(_ result: FrameResult) {
        switch mode {
        case .enroll: handleEnroll(result)
        case .test: handleTest(result)
        }
    }

    private func handleEnroll(_ result: FrameResult) {
        guard collecting else { return }
        guard case .face(let reading) = result else {
            statusLabel.stringValue = result.hint
            return
        }
        guard Date().timeIntervalSince(lastSampleAt) >= Self.sampleInterval else { return }
        lastSampleAt = Date()
        samples.append(reading.embedding)
        progress.doubleValue = Double(samples.count)
        statusLabel.stringValue = "등록 중… \(samples.count)/\(Self.targetSamples)\n고개를 아주 조금씩 천천히 움직여 주세요."
        if samples.count >= Self.targetSamples { finishEnroll() }
    }

    private func finishEnroll() {
        collecting = false
        finished = true
        var all = samples
        if case .enroll(let append) = mode, append, let existing = FaceStore.load() {
            all = existing.samples + samples
        }
        if all.count > FaceStore.maxSamples { all = Array(all.suffix(FaceStore.maxSamples)) }
        let base = FaceMatcher.calibrate(all)
        FaceStore.save(FaceProfile(samples: all, baseThreshold: base, createdAt: Date()))
        Log.write(String(format: "얼굴 등록: 샘플 %d개, 기준 거리 %.3f", all.count, base))
        statusLabel.stringValue = String(format: "등록 완료. 샘플 %d개, 기준 거리 %.2f\n메뉴의 [인식 테스트]에서 잘 인식되는지 확인해 보세요.", all.count, base)
        actionButton.title = "닫기"
        actionButton.isEnabled = true
    }

    private func handleTest(_ result: FrameResult) {
        guard let profile else { return }
        guard case .face(let reading) = result else {
            statusLabel.stringValue = result.hint
            return
        }
        if let openness = reading.eyeOpenness { _ = blink.feed(openness) }
        let score = FaceMatcher.score(reading.embedding, against: profile.samples)
        let threshold = FaceMatcher.threshold(for: profile)
        let verdict = score <= threshold ? "✅ 일치" : "❌ 불일치"
        statusLabel.stringValue = String(
            format: "%@\n거리 %.2f / 기준 %.2f (거리가 기준보다 작아야 일치)\n감지된 눈 깜빡임: %d회",
            verdict, score, threshold, blink.blinks)
    }

    func windowWillClose(_ notification: Notification) {
        camera.onFrame = nil
        camera.stop()
        let callback = onClose
        DispatchQueue.main.async { callback?() }
    }
}
