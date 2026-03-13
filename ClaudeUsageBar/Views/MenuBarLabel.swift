import SwiftUI

struct MenuBarLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkle")
            Text(text)
                .monospacedDigit()
        }
    }
}
