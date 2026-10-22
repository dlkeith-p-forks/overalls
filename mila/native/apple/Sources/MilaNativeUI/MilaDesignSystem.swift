import SwiftUI

/// The four Monospace Web colour tokens used by every native Apple surface.
/// Keep presentation colours inside this type so light/dark contrast remains auditable.
public struct MilaMonoTokens: Equatable {
    public let text: Color
    public let textAlt: Color
    public let background: Color
    public let backgroundAlt: Color

    public static let light = MilaMonoTokens(
        text: Color(red: 0, green: 0, blue: 0),
        textAlt: Color(red: 0.4, green: 0.4, blue: 0.4),
        background: Color(red: 1, green: 1, blue: 1),
        backgroundAlt: Color(red: 0.933333, green: 0.933333, blue: 0.933333)
    )
    public static let dark = MilaMonoTokens(
        text: Color(red: 1, green: 1, blue: 1),
        textAlt: Color(red: 0.666667, green: 0.666667, blue: 0.666667),
        background: Color(red: 0, green: 0, blue: 0),
        backgroundAlt: Color(red: 0.066667, green: 0.066667, blue: 0.066667)
    )

    public init(text: Color, textAlt: Color, background: Color, backgroundAlt: Color) {
        self.text = text
        self.textAlt = textAlt
        self.background = background
        self.backgroundAlt = backgroundAlt
    }
}

private struct MilaMonoTokensKey: EnvironmentKey {
    static let defaultValue = MilaMonoTokens.light
}

extension EnvironmentValues {
    public var milaMonoTokens: MilaMonoTokens {
        get { self[MilaMonoTokensKey.self] }
        set { self[MilaMonoTokensKey.self] = newValue }
    }
}

/// Applies the shared 14px monospace grid, square 2px borders, and high-contrast chrome.
public struct MilaDesignSystem: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public func body(content: Content) -> some View {
        let tokens = colorScheme == .dark ? MilaMonoTokens.dark : MilaMonoTokens.light
        content
            .environment(\.milaMonoTokens, tokens)
            .font(.custom("JetBrains Mono", size: 14, relativeTo: .body))
            .foregroundStyle(tokens.text)
            .tint(tokens.text)
            .background(tokens.background)
            .environment(\.defaultMinListRowHeight, 28)
    }
}

extension View {
    public func milaDesignSystem() -> some View { modifier(MilaDesignSystem()) }

    /// Use on controls and cards instead of rounded platform chrome.
    public func milaSquareBorder(_ tokens: MilaMonoTokens, width: CGFloat = 2) -> some View {
        overlay(Rectangle().stroke(tokens.text, lineWidth: width))
    }
}
