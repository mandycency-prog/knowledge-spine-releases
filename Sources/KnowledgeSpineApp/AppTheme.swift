import SwiftUI

enum AppTheme {
    static let ink = Color(red: 0.075, green: 0.11, blue: 0.15)
    static let muted = Color(red: 0.39, green: 0.43, blue: 0.46)
    static let canvas = Color(red: 0.956, green: 0.946, blue: 0.915)
    static let paper = Color(red: 0.992, green: 0.987, blue: 0.972)
    static let teal = Color(red: 0.11, green: 0.43, blue: 0.42)
    static let tealSoft = Color(red: 0.84, green: 0.92, blue: 0.89)
    static let coral = Color(red: 0.82, green: 0.31, blue: 0.23)
    static let coralSoft = Color(red: 0.98, green: 0.89, blue: 0.85)
    static let amber = Color(red: 0.82, green: 0.58, blue: 0.18)
    static let amberSoft = Color(red: 0.98, green: 0.93, blue: 0.76)
    static let blue = Color(red: 0.20, green: 0.37, blue: 0.57)
    static let blueSoft = Color(red: 0.87, green: 0.91, blue: 0.96)
    static let line = Color(red: 0.18, green: 0.25, blue: 0.28).opacity(0.26)
}

struct AppCardModifier: ViewModifier {
    var radius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .background(AppTheme.paper)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(AppTheme.ink.opacity(0.09), lineWidth: 1)
            }
            .shadow(color: AppTheme.ink.opacity(0.07), radius: 16, y: 7)
    }
}

extension View {
    func appCard(radius: CGFloat = 18) -> some View {
        modifier(AppCardModifier(radius: radius))
    }
}
