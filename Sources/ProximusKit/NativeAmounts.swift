import Foundation

/// Unsigned atomic amounts. No binary floating point enters a transfer or its review.
public struct NativeAmount: Codable, Equatable, Comparable, Sendable {
    public let atoms: String
    public static let zero = try! NativeAmount("0")
    public init(_ atoms: String) throws {
        guard !atoms.isEmpty, atoms.utf8.allSatisfy({ (48...57).contains($0) }),
              atoms == "0" || atoms.first != "0", atoms.count <= 39,
              atoms.count < 39 || atoms <= "340282366920938463463374607431768211455" else {
            throw ProximusError.invalid("Invalid or oversized coin amount.")
        }
        self.atoms = atoms
    }
    public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(atoms) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.atoms.count == rhs.atoms.count ? lhs.atoms < rhs.atoms : lhs.atoms.count < rhs.atoms.count }
    public static func parse(_ text: String, decimals: Int) throws -> Self {
        guard (0...18).contains(decimals), text.count <= 60 else { throw ProximusError.invalid("Invalid coin amount.") }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty,
              parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              parts.count == 1 || (!parts[1].isEmpty && parts[1].count <= decimals) else {
            throw ProximusError.invalid("Use a positive decimal amount with at most \(decimals) decimal places; no separators or exponents.")
        }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        return try Self(normalize(String(parts[0]) + fraction + String(repeating: "0", count: decimals - fraction.count)))
    }
    public func formatted(decimals: Int) -> String {
        guard decimals > 0 else { return atoms }
        let padded = String(repeating: "0", count: max(0, decimals + 1 - atoms.count)) + atoms
        let split = padded.index(padded.endIndex, offsetBy: -decimals)
        var fraction = String(padded[split...]); while fraction.last == "0" { fraction.removeLast() }
        return String(padded[..<split]) + (fraction.isEmpty ? "" : "." + fraction)
    }
    public func adding(_ other: Self) throws -> Self {
        let a = Array(atoms.utf8.reversed()), b = Array(other.atoms.utf8.reversed())
        var result = [UInt8](), carry = 0
        for i in 0..<max(a.count, b.count) {
            let sum = (i < a.count ? Int(a[i] - 48) : 0) + (i < b.count ? Int(b[i] - 48) : 0) + carry
            result.append(UInt8(sum % 10) + 48); carry = sum / 10
        }
        if carry != 0 { result.append(UInt8(carry) + 48) }
        return try Self(String(decoding: result.reversed(), as: UTF8.self))
    }
    public static func hex(_ text: String) throws -> Self {
        guard text.hasPrefix("0x"), (3...34).contains(text.count), text.dropFirst(2).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }) else { throw ProximusError.transport("Invalid RPC hexadecimal quantity.") }
        var value = zero
        for digit in text.dropFirst(2) {
            for _ in 0..<4 { value = try value.adding(value) }
            value = try value.adding(Self(String(digit.hexDigitValue!)))
        }
        return value
    }
    public var rpcHex: String {
        var digits = atoms.compactMap(\.wholeNumberValue), result = ""
        repeat {
            var quotient = [Int](), remainder = 0
            for digit in digits { let v = remainder * 10 + digit; if !quotient.isEmpty || v / 16 != 0 { quotient.append(v / 16) }; remainder = v % 16 }
            result = String(remainder, radix: 16) + result; digits = quotient
        } while !digits.isEmpty
        return "0x" + result
    }
    static func normalize(_ text: String) -> String { let n = text.drop(while: { $0 == "0" }); return n.isEmpty ? "0" : String(n) }
    var uint64: UInt64 { get throws { guard let v = UInt64(atoms) else { throw ProximusError.invalid("Coin amount exceeds the network limit.") }; return v } }
}

public struct WalletChain: Codable, Equatable, Sendable {
    public let network: WalletNetwork
    public let identity: String
    public let name: String
    public let symbol: String
    public let decimals: Int
    public var display: String { name + " - " + symbol }
    public func amount(_ value: NativeAmount) -> String { value.formatted(decimals: decimals) + " " + symbol }
    static let solanaGenesis = "5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d"
    public static func resolve(_ network: WalletNetwork, identity: String) throws -> Self {
        switch network {
        case .solana:
            guard identity == solanaGenesis else { throw ProximusError.invalid("Choose a Solana mainnet RPC for this wallet.") }
            return Self(network: network, identity: identity, name: "Solana mainnet", symbol: "SOL", decimals: 9)
        case .bitcoin:
            guard identity == "main" else { throw ProximusError.invalid("This Bitcoin wallet requires mainnet.") }
            return Self(network: network, identity: identity, name: "Bitcoin mainnet", symbol: "BTC", decimals: 8)
        case .monero:
            guard identity == "mainnet" else { throw ProximusError.invalid("This Monero wallet requires mainnet.") }
            return Self(network: network, identity: identity, name: "Monero mainnet", symbol: "XMR", decimals: 12)
        case .evm:
            let chains: [String: (String, String)] = ["1": ("Ethereum", "ETH"), "56": ("BNB Smart Chain", "BNB"), "137": ("Polygon PoS", "POL"), "43114": ("Avalanche C-Chain", "AVAX"), "11155111": ("Ethereum Sepolia (testnet)", "test ETH")]
            guard let chain = chains[identity] else { throw ProximusError.unavailable("EVM chain \(identity) is not supported for sending yet. Choose Ethereum, BNB Smart Chain, Polygon PoS, Avalanche C-Chain, or Sepolia. Networks with additional data fees need a separate fee implementation.") }
            return Self(network: network, identity: identity, name: chain.0, symbol: chain.1, decimals: 18)
        }
    }
    func validate() throws { guard self == (try Self.resolve(network, identity: identity)) else { throw ProximusError.authentication } }
}

extension WalletNetwork {
    public var coinLabel: String { switch self { case .solana: return "Solana - SOL"; case .evm: return "EVM - select chain in RPC settings"; case .bitcoin: return "Bitcoin - BTC"; case .monero: return "Monero - XMR" } }
}
