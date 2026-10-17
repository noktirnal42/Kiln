import SwiftUI

@MainActor
public protocol ModuleUI: Module {
    func makeRootView() -> AnyView
}
