import Foundation

/// Equatable error wrapper so failures can ride in TCA actions (which must be
/// `Equatable` for `TestStore` assertions) while still carrying a localized
/// message for toasts.
public struct AppError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public init(wrapping error: Error) {
        self.message = error.localizedDescription
    }
}
