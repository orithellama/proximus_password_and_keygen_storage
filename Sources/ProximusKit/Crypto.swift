import Foundation
import CryptoKit
import ProximusCrypto

public enum ProximusError: Error, LocalizedError, Equatable {
    case invalid(String), authentication, locked, conflict, unavailable(String), transport(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .unavailable(let message), .transport(let message): return message
        case .authentication: return "Could not authenticate the data. Check your passphrase and recovery key."
        case .locked: return "Unlock your vault first."
        case .conflict: return "The vault changed on another device or in AutoFill. Reload before saving. Your changes have not replaced it."
        }
    }
}

public final class SecretBytes {
    private var storage: Data
    public init(_ data: Data) throws {
        guard data.count == 32 else { throw ProximusError.invalid("Invalid key length.") }
        storage = data
    }
    public func withData<T>(_ body: (Data) throws -> T) rethrows -> T { try body(storage) }
    public func erase() { storage.withUnsafeMutableBytes { px_zero($0.bindMemory(to: UInt8.self).baseAddress, $0.count) }; storage.removeAll(keepingCapacity: false) }
    deinit { erase() }
}

public enum VaultCrypto {
    public static let maximumPayload = 8 * 1024 * 1024
    public static func random(_ count: Int) throws -> Data {
        guard count > 0, count <= maximumPayload else { throw ProximusError.invalid("Invalid random byte count.") }
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { px_random($0.bindMemory(to: UInt8.self).baseAddress, count) }
        guard result == 0 else { throw ProximusError.unavailable("Secure randomness is unavailable.") }
        return data
    }
    public static func recoveryKey() throws -> String { try random(32).base64URLEncoded }
    public static func decodeRecovery(_ value: String) throws -> Data {
        guard let data = Data(base64URL: value.trimmingCharacters(in: .whitespacesAndNewlines)), data.count == 32 else { throw ProximusError.invalid("Enter the complete recovery key from your kit.") }
        return data
    }
    public static func derive(passphrase: String, recovery: Data, salt: Data) throws -> Data {
        var password = Data(passphrase.utf8)
        defer { password.withUnsafeMutableBytes { px_zero($0.bindMemory(to: UInt8.self).baseAddress, $0.count) } }
        guard (12...1024).contains(password.count), recovery.count == 32, salt.count == 16 else { throw ProximusError.invalid("Use a passphrase of at least 12 characters. Six or seven randomly selected words are recommended.") }
        var output = Data(count: 32)
        let result = password.withUnsafeBytes { p in recovery.withUnsafeBytes { r in salt.withUnsafeBytes { s in output.withUnsafeMutableBytes { o in
            px_derive_key(p.bindMemory(to: UInt8.self).baseAddress, password.count, r.bindMemory(to: UInt8.self).baseAddress, s.bindMemory(to: UInt8.self).baseAddress, o.bindMemory(to: UInt8.self).baseAddress)
        } } } }
        guard result == 0 else { throw ProximusError.authentication }
        return output
    }
    public static func seal(_ plain: Data, key: Data, context: Data) throws -> Data {
        guard key.count == 32, !plain.isEmpty, plain.count <= maximumPayload, !context.isEmpty, context.count <= 4096 else { throw ProximusError.invalid("Invalid encryption input.") }
        var output = Data(count: plain.count + 28)
        let result = key.withUnsafeBytes { k in plain.withUnsafeBytes { p in context.withUnsafeBytes { a in output.withUnsafeMutableBytes { o in
            px_seal(k.bindMemory(to: UInt8.self).baseAddress, p.bindMemory(to: UInt8.self).baseAddress, plain.count, a.bindMemory(to: UInt8.self).baseAddress, context.count, o.bindMemory(to: UInt8.self).baseAddress)
        } } } }
        guard result == 0 else { throw ProximusError.authentication }
        return output
    }
    public static func open(_ sealed: Data, key: Data, context: Data) throws -> Data {
        guard key.count == 32, sealed.count > 28, sealed.count <= maximumPayload + 28, !context.isEmpty, context.count <= 4096 else { throw ProximusError.authentication }
        var output = Data(count: sealed.count - 28)
        let result = key.withUnsafeBytes { k in sealed.withUnsafeBytes { s in context.withUnsafeBytes { a in output.withUnsafeMutableBytes { o in
            px_open(k.bindMemory(to: UInt8.self).baseAddress, s.bindMemory(to: UInt8.self).baseAddress, sealed.count, a.bindMemory(to: UInt8.self).baseAddress, context.count, o.bindMemory(to: UInt8.self).baseAddress)
        } } } }
        guard result == 0 else { output.resetBytes(in: 0..<output.count); throw ProximusError.authentication }
        return output
    }
    public static func password(length: Int = 24, symbols: Bool = true) throws -> String {
        let alphabet = Data(("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789" + (symbols ? "!#$%&()*+,-./:;<=>?@[]^_{|}~" : "")).utf8)
        guard (12...128).contains(length) else { throw ProximusError.invalid("Choose 12 to 128 characters.") }
        var output = Data(count: length)
        let result = alphabet.withUnsafeBytes { a in output.withUnsafeMutableBytes { o in px_generate_password(length, a.bindMemory(to: UInt8.self).baseAddress, alphabet.count, o.bindMemory(to: UInt8.self).baseAddress) } }
        guard result == 0, let text = String(data: output, encoding: .utf8) else { throw ProximusError.unavailable("Password generation failed.") }
        return text
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

extension Data {
    public var base64URLEncoded: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    public init?(base64URL: String) {
        guard base64URL.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }), base64URL.count % 4 != 1 else { return nil }
        let standard = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: standard + String(repeating: "=", count: (4 - standard.count % 4) % 4))
    }
}

public enum Encoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= VaultCrypto.maximumPayload * 2 else { throw ProximusError.invalid("This file is too large.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}
