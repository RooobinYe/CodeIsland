import SwiftUI
import CodeIslandCore

/// The static brand logo that tells a session's harness apart.
struct MascotView: View {
    let source: String
    var size: CGFloat = 27

    var body: some View {
        let resolved = SessionSnapshot.normalizedSupportedSource(source) ?? source
        if let icon = cliIcon(source: resolved, size: size) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }
}
