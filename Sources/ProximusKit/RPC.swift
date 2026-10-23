import Foundation

public struct RPCConfiguration: Codable, Sendable {
    public var network: WalletNetwork
    public var endpoint: URL
    public var username: String
    public var password: String
    public init(network: WalletNetwork, endpoint: URL, username: String = "", password: String = "") throws {
        self.network = network; self.endpoint = endpoint; self.username = username; self.password = password
        try validate()
    }
    public func validate() throws {
        guard endpoint.absoluteString.utf8.count <= 2048, endpoint.host?.isEmpty == false, endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil,
              endpoint.scheme == "https" || (endpoint.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(endpoint.host ?? "")),
              username.utf8.count <= 256, password.utf8.count <= 2048, !username.contains(":"), !username.contains(where: { $0.isNewline }), !password.contains(where: { $0.isNewline }), password.isEmpty || !username.isEmpty else {
            throw ProximusError.invalid("Use an HTTPS RPC URL, or HTTP on localhost. Enter RPC credentials in their separate fields.")
        }
    }
    public func save() throws { try validate(); try DeviceKeychain.write(Encoding.encode(self), account: "rpc/" + network.rawValue) }
    public static func load(_ network: WalletNetwork) throws -> RPCConfiguration? {
        guard let data = try DeviceKeychain.read("rpc/" + network.rawValue) else { return nil }
        let value = try Encoding.decode(Self.self, from: data); try value.validate()
        guard value.network == network else { throw ProximusError.authentication }; return value
    }
    public static func remove(_ network: WalletNetwork) throws { try DeviceKeychain.delete("rpc/" + network.rawValue) }
    func request() throws -> URLRequest {
        try validate()
        let method: String
        switch network { case .solana: method = "getGenesisHash"; case .evm: method = "eth_chainId"; case .bitcoin: method = "getblockchaininfo"; case .monero: method = "get_info" }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": "proximus-connection-check", "method": method, "params": []])
        if !username.isEmpty { request.setValue("Basic " + Data((username + ":" + password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization") }
        return request
    }
    public func checkConnection() async throws -> String {
        let (data, response) = try await BoundedHTTP.send(request(), limit: 256 * 1024)
        guard response.statusCode == 200 else { throw ProximusError.transport("RPC connection check failed (HTTP \(response.statusCode)).") }
        return try parseResponse(data)
    }
    func parseResponse(_ data: Data) throws -> String {
        guard data.count <= 256 * 1024, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["id"] as? String == "proximus-connection-check", json["error"] == nil || json["error"] is NSNull, let result = json["result"] else { throw ProximusError.transport("The endpoint returned an invalid RPC response.") }
        switch network {
        case .solana:
            guard let value = result as? String, (32...64).contains(value.count), value.allSatisfy({ "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".contains($0) }) else { throw ProximusError.transport("Invalid Solana genesis hash.") }
            return "Connected. Solana genesis: " + value
        case .evm:
            guard let value = result as? String, value.hasPrefix("0x"), (3...66).contains(value.count), value.dropFirst(2).allSatisfy(\.isHexDigit) else { throw ProximusError.transport("Invalid EVM chain ID.") }
            return "Connected. EVM chain ID: " + value
        case .bitcoin, .monero:
            guard let info = result as? [String: Any], let network = info[network == .bitcoin ? "chain" : "nettype"] as? String, ["main", "test", "testnet4", "signet", "regtest", "mainnet", "testnet", "stagenet"].contains(network), let height = info[self.network == .bitcoin ? "blocks" : "height"] as? Int, height >= 0 else { throw ProximusError.transport("Invalid node network or height.") }
            return "Connected to \(network). Block height: \(height)"
        }
    }
}
