import Foundation
import LocalAuthentication

public enum CredentialPrivacy {
    /// Render only this redacted value. Blurring the original text would still expose it to accessibility and selection.
    public static func maskedEmail(_ value: String) -> String {
        guard value.contains("@"), value.count > 4 else { return value }
        return String(value.prefix(4)) + "********"
    }
}

public enum CredentialAuthorization {
    case device
    case vaultPassword(String, recoveryKey: String)
}

public struct CredentialAccessGrant {
    let id: UUID
    let generation: UInt64
    let item: VaultItem
    let expires: Date
}

enum DeviceOwnerAuthentication {
    @MainActor static func authenticate(reason: String) async throws {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedCancelTitle = "Cancel"
        defer { context.invalidate() }
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw ProximusError.unavailable("Device authentication is unavailable. Use your vault password instead.")
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
                throw ProximusError.authentication
            }
            try Task.checkCancellation()
        } onCancel: {
            context.invalidate()
        }
    }
}
