import Foundation

/// The one place an activity is registered. Order is the sidebar order and the ⌘1…⌘9, ⌘0 order, so append new
/// modules at the end. A new module needs its own folder (which declares an `ActivityDescriptor`) and one line here.
enum ActivityCatalog {
    static let descriptors: [ActivityDescriptor] = [
        HomeActivity.descriptor,
        AgentActivity.descriptor,
        SwarmActivity.descriptor,
        DevelopActivity.descriptor,
        AnalyzeActivity.descriptor,
        LabActivity.descriptor,
        AuditActivity.descriptor,
        BrowserActivity.descriptor,
        DevicesActivity.descriptor,
        MediaActivity.descriptor,
    ]
}
