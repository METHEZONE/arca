import SwiftUI

/// ARCA CallLab — a standalone build whose only job is to answer one question:
/// is an ARCA↔ARCA call better than the carrier's mVoIP path?
///
/// It ships separately from ARCA on purpose. Call quality has to be measured on a
/// real radio, on two real devices, over days — and none of that should be gated
/// on the main app being in a releasable state. Once the numbers say yes, the
/// views here move into ARCA proper; the whole media stack already lives in
/// ArcaVoiceKit's Calling module, so nothing has to be rewritten.
@main
struct CallLabApp: App {
    var body: some Scene {
        WindowGroup {
            CallLabView()
                #if os(macOS)
                .frame(minWidth: 420, minHeight: 620)
                #endif
        }
    }
}
