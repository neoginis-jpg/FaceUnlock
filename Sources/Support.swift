import ApplicationServices
import CoreGraphics
import Foundation
import OpenDirectory
import Security

// MARK: - 로그 (~/Library/Logs/FaceUnlock.log). 비밀번호는 절대 기록하지 않는다.

enum Log {
    private static let queue = DispatchQueue(label: "faceunlock.log")

    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("FaceUnlock.log")
    }()

    static func write(_ message: String) {
        let now = Date()
        queue.async {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            guard let data = "\(formatter.string(from: now)) \(message)\n".data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}

// MARK: - 설정

enum Settings {
    private static let defaults = UserDefaults.standard

    static var enabled: Bool {
        get { defaults.bool(forKey: "enabled") }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    static var requireBlink: Bool {
        get { defaults.bool(forKey: "requireBlink") }
        set { defaults.set(newValue, forKey: "requireBlink") }
    }

    /// 스캔 중·성공·실패 효과를 잠금 화면에 표시할지.
    static var showEffect: Bool {
        get { defaults.object(forKey: "showEffect") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showEffect") }
    }

    /// 0 = 엄격, 1 = 보통, 2 = 느슨
    static var sensitivity: Int {
        get { defaults.object(forKey: "sensitivity") as? Int ?? 1 }
        set { defaults.set(newValue, forKey: "sensitivity") }
    }

    /// 비밀번호나 Touch ID로 직접 푼 뒤 이 시간이 지나면 얼굴 잠금해제를 쓰지 않는다.
    static let maxHoursSincePassword: Double = 12
}

// MARK: - 키체인

enum Keychain {
    private static let service = "local.faceunlock.app"
    private static let account = "login-password"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ password: String) -> Bool {
        delete()
        var query = baseQuery
        query[kSecValueData as String] = Data(password.utf8)
        query[kSecAttrLabel as String] = "FaceUnlock 로그인 비밀번호"
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// 값은 읽지 않고 항목이 있는지만 확인한다.
    static func exists() -> Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete() -> Bool {
        SecItemDelete(baseQuery as CFDictionary) == errSecSuccess
    }
}

// MARK: - 입력한 비밀번호가 실제 로그인 비밀번호인지 확인

enum PasswordCheck {
    enum Result { case correct, wrong, unknown }

    static func verify(_ password: String) -> Result {
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
            try record.verifyPassword(password)
            return .correct
        } catch let error as NSError {
            if error.code == Int(kODErrorCredentialsInvalid.rawValue) { return .wrong }
            Log.write("비밀번호 확인 불가: \(error.domain) \(error.code)")
            return .unknown
        }
    }
}

// MARK: - 화면 잠금 상태

enum ScreenLock {
    static var isLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }
}

// MARK: - 잠금 화면에 키 입력 보내기 (손쉬운 사용 권한 필요)

enum Typer {
    private static let keyReturn: CGKeyCode = 36
    private static let keyDelete: CGKeyCode = 51
    private static let keyA: CGKeyCode = 0
    private static let keyShift: CGKeyCode = 56
    private static let keySpace: CGKeyCode = 49

    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private static func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// 글자를 넣지 않고 암호 입력란만 깨운다.
    static func nudge() {
        press(keyShift)
    }

    /// 입력란에 이미 들어간 글자를 지운다.
    static func clearField() {
        press(keyA, flags: .maskCommand)
        press(keyDelete)
    }

    /// 잠금 상태일 때만 한 글자씩 입력한다. 도중에 잠금이 풀리면 즉시 멈춘다.
    /// 끝까지 입력했으면 true.
    static func type(_ text: String) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        for character in text {
            guard ScreenLock.isLocked else { return false }
            var units = Array(String(character).utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: keySpace, keyDown: down)
                event?.flags = []
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                event?.post(tap: .cghidEventTap)
            }
            usleep(6000)
        }
        return true
    }

    static func pressReturn() {
        guard ScreenLock.isLocked else { return }
        press(keyReturn)
    }
}
