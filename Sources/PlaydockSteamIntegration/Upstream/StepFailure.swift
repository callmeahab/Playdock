// Adapted from NotProton c3a49486; GPL-3.0. See Sources/PlaydockSteamIntegration/NOTICE.
import Foundation

struct StepFailure: LocalizedError {
    let step: String
    let detail: String

    var errorDescription: String? { "\(step): \(detail)" }
}
