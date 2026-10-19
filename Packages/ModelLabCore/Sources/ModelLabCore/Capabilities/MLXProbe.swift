import Foundation
import MLXLMCommon

/// Smoke-test symbol used only to confirm the MLX Swift LM dependency
/// resolves and compiles on this toolchain. Real usage lives in
/// `MLXInferenceProvider`.
enum MLXProbe {
    static func describe(_ configuration: ModelConfiguration) -> String {
        configuration.name
    }
}
