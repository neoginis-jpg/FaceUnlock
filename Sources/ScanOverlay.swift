import AppKit
import QuartzCore

// MARK: - 잠금 화면 위로 창 올리기
// 공개 API로는 잠금 화면 위에 창을 띄울 수 없어서, macOS 내부(비공개) SkyLight 함수를 쓴다.
// macOS 업데이트로 막히면 조용히 실패하고, 그 경우 효과만 안 보일 뿐 잠금 해제는 그대로 된다.

enum SkyLight {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    /// 잠금 화면의 알림 센터와 같은 높이.
    private static let lockScreenLevel: Int32 = 400

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)

    private static func load<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    private static let space: (connection: Int32, id: Int32)? = {
        guard let mainConnection = load("SLSMainConnectionID", MainConnectionID.self),
              let create = load("SLSSpaceCreate", SpaceCreate.self),
              let setLevel = load("SLSSpaceSetAbsoluteLevel", SpaceSetAbsoluteLevel.self),
              let show = load("SLSShowSpaces", ShowSpaces.self) else { return nil }
        let connection = mainConnection()
        let id = create(connection, 1, 0)
        _ = setLevel(connection, id, lockScreenLevel)
        _ = show(connection, [id] as CFArray)
        return (connection, id)
    }()

    /// 창을 잠금 화면 위 공간으로 옮긴다. 함수를 찾지 못하면 false.
    @discardableResult
    static func raise(_ window: NSWindow) -> Bool {
        guard let space,
              let add = load("SLSSpaceAddWindowsAndRemoveFromSpaces", AddWindows.self) else { return false }
        _ = add(space.connection, space.id, [window.windowNumber] as CFArray, 7)
        return true
    }
}

// MARK: - 얼굴 스캔 표시 (스캔 중 → 체크 / 실패)

final class ScanHUDView: NSView {
    enum State { case scanning, success, failure }

    static let size = CGSize(width: 172, height: 196)

    /// 시험용: 문구 앞에 붙는 표시.
    var prefix = ""

    private let glyphSide: CGFloat = 96
    private let glyph = CALayer()
    private let corners = CAShapeLayer()
    private let face = CAShapeLayer()
    private let scanLine = CAGradientLayer()
    private let circle = CAShapeLayer()
    private let check = CAShapeLayer()
    private let label = CATextLayer()
    private var current: State?

    private let white = NSColor.white.cgColor
    private let green = NSColor(srgbRed: 0.20, green: 0.84, blue: 0.42, alpha: 1).cgColor
    private let red = NSColor(srgbRed: 1.0, green: 0.33, blue: 0.30, alpha: 1).cgColor

    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer()
        root.backgroundColor = NSColor(white: 0, alpha: 0.78).cgColor
        root.cornerRadius = 40
        root.cornerCurve = .continuous
        layer = root
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        guard let root = layer else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let side = glyphSide

        glyph.frame = CGRect(x: (Self.size.width - side) / 2, y: Self.size.height - 30 - side, width: side, height: side)
        root.addSublayer(glyph)

        // 네 모서리 괄호
        let cornerPath = CGMutablePath()
        let inset: CGFloat = 6, radius: CGFloat = 18, arm: CGFloat = 11
        for (cx, cy, dx, dy) in [(inset, inset, 1.0, 1.0), (side - inset, inset, -1.0, 1.0),
                                 (inset, side - inset, 1.0, -1.0), (side - inset, side - inset, -1.0, -1.0)] {
            cornerPath.move(to: CGPoint(x: cx, y: cy + dy * (radius + arm)))
            cornerPath.addLine(to: CGPoint(x: cx, y: cy + dy * radius))
            cornerPath.addQuadCurve(to: CGPoint(x: cx + dx * radius, y: cy), control: CGPoint(x: cx, y: cy))
            cornerPath.addLine(to: CGPoint(x: cx + dx * (radius + arm), y: cy))
        }
        style(corners, path: cornerPath, width: 5, color: white, scale: scale)

        // 얼굴: 눈 두 개, 코, 입 (y는 위쪽이 큰 값)
        let facePath = CGMutablePath()
        facePath.move(to: CGPoint(x: 35, y: 62)); facePath.addLine(to: CGPoint(x: 35, y: 54))
        facePath.move(to: CGPoint(x: 61, y: 62)); facePath.addLine(to: CGPoint(x: 61, y: 54))
        facePath.move(to: CGPoint(x: 49, y: 60)); facePath.addLine(to: CGPoint(x: 49, y: 47))
        facePath.addQuadCurve(to: CGPoint(x: 44, y: 43), control: CGPoint(x: 49, y: 43))
        facePath.move(to: CGPoint(x: 36, y: 34))
        facePath.addQuadCurve(to: CGPoint(x: 60, y: 34), control: CGPoint(x: 48, y: 24))
        style(face, path: facePath, width: 5, color: white, scale: scale)

        // 위아래로 훑는 스캔 선
        scanLine.bounds = CGRect(x: 0, y: 0, width: 70, height: 3)
        scanLine.position = CGPoint(x: side / 2, y: side / 2)
        scanLine.cornerRadius = 1.5
        scanLine.startPoint = CGPoint(x: 0, y: 0.5)
        scanLine.endPoint = CGPoint(x: 1, y: 0.5)
        scanLine.colors = [NSColor.clear.cgColor, green, NSColor.clear.cgColor]
        glyph.addSublayer(scanLine)

        // 성공: 위에서 시작해 시계 방향으로 그려지는 원 + 체크
        let circlePath = CGMutablePath()
        circlePath.addArc(center: CGPoint(x: side / 2, y: side / 2), radius: 40,
                          startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        style(circle, path: circlePath, width: 5, color: green, scale: scale)
        circle.strokeEnd = 0

        let checkPath = CGMutablePath()
        checkPath.move(to: CGPoint(x: 31, y: 49))
        checkPath.addLine(to: CGPoint(x: 43, y: 37))
        checkPath.addLine(to: CGPoint(x: 66, y: 61))
        style(check, path: checkPath, width: 6, color: green, scale: scale)
        check.strokeEnd = 0

        label.frame = CGRect(x: 8, y: 24, width: Self.size.width - 16, height: 22)
        label.alignmentMode = .center
        label.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        label.fontSize = 14
        label.foregroundColor = NSColor(white: 1, alpha: 0.92).cgColor
        label.contentsScale = scale
        root.addSublayer(label)
    }

    private func style(_ shape: CAShapeLayer, path: CGPath, width: CGFloat, color: CGColor, scale: CGFloat) {
        shape.frame = CGRect(x: 0, y: 0, width: glyphSide, height: glyphSide)
        shape.path = path
        shape.fillColor = nil
        shape.strokeColor = color
        shape.lineWidth = width
        shape.lineCap = .round
        shape.lineJoin = .round
        shape.contentsScale = scale
        glyph.addSublayer(shape)
    }

    func set(_ state: State, animated: Bool = true) {
        guard state != current else { return }
        current = state

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in [glyph, corners, face, scanLine, circle, check] { item.removeAllAnimations() }
        let text: String
        switch state {
        case .scanning:
            text = "얼굴 확인 중"
            corners.opacity = 1; face.opacity = 1; scanLine.opacity = 1
            corners.strokeColor = white; face.strokeColor = white
            circle.strokeEnd = 0; check.strokeEnd = 0
        case .success:
            text = "얼굴 확인됨"
            corners.opacity = 0; face.opacity = 0; scanLine.opacity = 0
            circle.strokeEnd = 1; check.strokeEnd = 1
        case .failure:
            text = "인식하지 못했습니다"
            corners.opacity = 1; face.opacity = 1; scanLine.opacity = 0
            corners.strokeColor = red; face.strokeColor = red
            circle.strokeEnd = 0; check.strokeEnd = 0
        }
        label.string = prefix.isEmpty ? text : "\(prefix) · \(text)"
        CATransaction.commit()

        guard animated else { return }
        switch state {
        case .scanning:
            let sweep = CABasicAnimation(keyPath: "position.y")
            sweep.fromValue = 20
            sweep.toValue = 76
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 1.0
            pulse.toValue = 1.06
            for animation in [sweep, pulse] {
                animation.duration = 0.9
                animation.autoreverses = true
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            }
            scanLine.add(sweep, forKey: "sweep")
            corners.add(pulse, forKey: "pulse")
        case .success:
            for item in [corners, face, scanLine] { animate(item, "opacity", from: 1, to: 0, duration: 0.18) }
            animate(circle, "strokeEnd", from: 0, to: 1, duration: 0.36)
            animate(check, "strokeEnd", from: 0, to: 1, duration: 0.22, delay: 0.3)
            let pop = CAKeyframeAnimation(keyPath: "transform.scale")
            pop.values = [0.9, 1.08, 1.0]
            pop.keyTimes = [0, 0.6, 1]
            pop.duration = 0.45
            glyph.add(pop, forKey: "pop")
        case .failure:
            let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
            shake.values = [0, -9, 9, -6, 6, -3, 3, 0]
            shake.duration = 0.45
            glyph.add(shake, forKey: "shake")
        }
    }

    private func animate(_ target: CALayer, _ keyPath: String, from: Float, to: Float,
                         duration: CFTimeInterval, delay: CFTimeInterval = 0) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.beginTime = target.convertTime(CACurrentMediaTime(), from: nil) + delay
        animation.fillMode = .backwards
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        target.add(animation, forKey: keyPath)
    }
}

// MARK: - 화면 가운데에 뜨는 표시 창

final class ScanOverlay {
    enum Method { case windowLevel, skyLight }

    private let panel: NSPanel
    private let hud = ScanHUDView(frame: NSRect(origin: .zero, size: ScanHUDView.size))
    private let method: Method
    private let offsetX: CGFloat
    private var generation = 0

    /// SkyLight 공간으로 옮기는 데 성공했는지 (시험·로그용).
    private(set) var raised = false

    init(method: Method = .skyLight, tag: String = "", offsetX: CGFloat = 0) {
        self.method = method
        self.offsetX = offsetX
        hud.prefix = tag
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: ScanHUDView.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.canBecomeVisibleWithoutLogin = true
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hud
    }

    func show(_ state: ScanHUDView.State) {
        generation += 1
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.frame
            panel.setFrameOrigin(NSPoint(x: frame.midX - ScanHUDView.size.width / 2 + offsetX,
                                         y: frame.midY - ScanHUDView.size.height / 2))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        if method == .skyLight { raised = SkyLight.raise(panel) }
        hud.set(state)
    }

    /// 결과를 보여 주고 잠시 뒤 사라진다.
    func finish(_ state: ScanHUDView.State, hideAfter delay: TimeInterval = 1.4) {
        show(state)
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == shown else { return }
            self.hide()
        }
    }

    func hide() {
        generation += 1
        let hidden = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == hidden else { return }
            self.panel.orderOut(nil)
        })
    }
}
