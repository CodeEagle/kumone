import Foundation

/// Equatable error wrapper so failures can ride in TCA actions (which must be
/// `Equatable` for `TestStore` assertions) while still carrying a localized
/// message for toasts.
struct AppError: Error, Equatable, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    init(wrapping error: Error) {
        self.message = error.localizedDescription
    }
}
