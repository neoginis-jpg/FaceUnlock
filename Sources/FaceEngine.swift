import AVFoundation
import CoreImage
import Foundation
import Vision

// MARK: - 저장되는 얼굴 프로필

struct FaceProfile: Codable {
    var samples: [[Float]]
    var baseThreshold: Float
    var createdAt: Date
}

enum FaceStore {
    static let maxSamples = 60

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FaceUnlock", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profile.json")
    }

    static func load() -> FaceProfile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FaceProfile.self, from: data)
    }

    static func save(_ profile: FaceProfile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - 임베딩 비교

enum FaceMatcher {
    static func normalize(_ v: [Float]) -> [Float] {
        let norm = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return .infinity }
        var sum: Float = 0
        for i in 0..<a.count {
            let d = a[i] - b[i]
            sum += d * d
        }
        return sum.squareRoot()
    }

    /// 등록 샘플 중 가장 가까운 3개와의 평균 거리. 작을수록 같은 얼굴.
    static func score(_ probe: [Float], against samples: [[Float]]) -> Float {
        let distances = samples.map { distance(probe, $0) }.sorted()
        let k = min(3, distances.count)
        guard k > 0 else { return .infinity }
        return distances.prefix(k).reduce(0, +) / Float(k)
    }

    /// 등록 샘플끼리의 거리를 보고 기준값을 정한다.
    static func calibrate(_ samples: [[Float]]) -> Float {
        guard samples.count >= 4 else { return 0.35 }
        var worst: Float = 0
        for i in samples.indices {
            var others = samples
            others.remove(at: i)
            worst = max(worst, score(samples[i], against: others))
        }
        return min(max(worst * 1.25, 0.25), 0.9)
    }

    static func threshold(for profile: FaceProfile) -> Float {
        let multipliers: [Float] = [0.85, 1.0, 1.2]
        let index = min(max(Settings.sensitivity, 0), multipliers.count - 1)
        return profile.baseThreshold * multipliers[index]
    }
}

// MARK: - 프레임 분석

struct FaceReading {
    let embedding: [Float]
    let eyeOpenness: Float?
}

enum FrameResult {
    case noFace
    case multipleFaces
    case tooSmall
    case notFrontal
    case face(FaceReading)

    var hint: String {
        switch self {
        case .noFace: return "얼굴이 보이지 않습니다."
        case .multipleFaces: return "얼굴이 여러 개 보입니다. 혼자 화면 앞에 있어 주세요."
        case .tooSmall: return "조금 더 가까이 와 주세요."
        case .notFrontal: return "화면을 정면으로 봐 주세요."
        case .face: return ""
        }
    }
}

final class FaceAnalyzer {
    private let ciContext = CIContext()

    func analyze(_ pixelBuffer: CVPixelBuffer) -> FrameResult {
        let landmarks = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do { try handler.perform([landmarks]) } catch { return .noFace }

        let faces = (landmarks.results ?? []).sorted { $0.boundingBox.width > $1.boundingBox.width }
        guard let face = faces.first else { return .noFace }
        if faces.count > 1, faces[1].boundingBox.width > face.boundingBox.width * 0.6 {
            return .multipleFaces
        }
        guard face.boundingBox.width >= 0.12 else { return .tooSmall }
        if let yaw = face.yaw?.doubleValue, abs(yaw) > 0.35 { return .notFrontal }
        if let roll = face.roll?.doubleValue, abs(roll) > 0.35 { return .notFrontal }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let box = VNImageRectForNormalizedRect(face.boundingBox, width, height)
        let side = max(box.width, box.height) * 1.15
        let square = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
            .intersection(image.extent)
            .integral
        guard square.width > 60, square.height > 60 else { return .tooSmall }
        guard let crop = ciContext.createCGImage(image.cropped(to: square), from: square) else { return .noFace }

        let featurePrint = VNGenerateImageFeaturePrintRequest()
        do { try VNImageRequestHandler(cgImage: crop, options: [:]).perform([featurePrint]) } catch { return .noFace }
        guard let observation = featurePrint.results?.first,
              let vector = Self.vector(from: observation) else { return .noFace }

        let size = CGSize(width: width, height: height)
        let eyes = [face.landmarks?.leftEye, face.landmarks?.rightEye].compactMap { Self.openness($0, imageSize: size) }
        let openness = eyes.isEmpty ? nil : eyes.reduce(0, +) / Float(eyes.count)

        return .face(FaceReading(embedding: FaceMatcher.normalize(vector), eyeOpenness: openness))
    }

    private static func vector(from observation: VNFeaturePrintObservation) -> [Float]? {
        let count = observation.elementCount
        switch observation.elementType {
        case .float:
            return observation.data.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Float.self).prefix(count))
            }
        case .double:
            return observation.data.withUnsafeBytes { raw in
                raw.bindMemory(to: Double.self).prefix(count).map { Float($0) }
            }
        default:
            return nil
        }
    }

    /// 눈 윤곽의 세로/가로 비율. 눈을 감으면 작아진다.
    private static func openness(_ region: VNFaceLandmarkRegion2D?, imageSize: CGSize) -> Float? {
        guard let points = region?.pointsInImage(imageSize: imageSize), points.count >= 4 else { return nil }
        let xs = points.map { $0.x }
        let ys = points.map { $0.y }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
              maxX - minX > 1 else { return nil }
        return Float((maxY - minY) / (maxX - minX))
    }
}

// MARK: - 눈 깜빡임

struct BlinkDetector {
    private var history: [Float] = []
    private var closedSeen = false
    private(set) var blinks = 0

    /// 깜빡임 한 번이 끝난 순간 true.
    mutating func feed(_ openness: Float) -> Bool {
        history.append(openness)
        if history.count > 40 { history.removeFirst() }
        guard history.count >= 5 else { return false }
        let sorted = history.sorted()
        let baseline = sorted[Int(Float(sorted.count - 1) * 0.8)]
        guard baseline > 0.05 else { return false }
        if openness < baseline * 0.6 {
            closedSeen = true
            return false
        }
        if closedSeen, openness > baseline * 0.8 {
            closedSeen = false
            blinks += 1
            return true
        }
        return false
    }
}

// MARK: - 카메라

final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var onFrame: ((CVPixelBuffer) -> Void)?

    private let sessionQueue = DispatchQueue(label: "faceunlock.camera.session")
    private let frameQueue = DispatchQueue(label: "faceunlock.camera.frames")
    private var configured = false

    static var authorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    static func requestAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    /// 내장 카메라만 쓴다. (연속성 카메라로 잡히는 iPhone은 제외)
    private static func builtInCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
        return discovery.devices.first { !$0.isContinuityCamera } ?? discovery.devices.first
    }

    private func configure() -> Bool {
        if configured { return true }
        guard let device = Self.builtInCamera(),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        guard session.canAddInput(input) else { session.commitConfiguration(); return false }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(output) else { session.commitConfiguration(); return false }
        session.addOutput(output)
        session.commitConfiguration()
        configured = true
        return true
    }

    @discardableResult
    func start() -> Bool {
        guard configure() else { return false }
        sessionQueue.async { if !self.session.isRunning { self.session.startRunning() } }
        return true
    }

    func stop() {
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(buffer)
    }
}
