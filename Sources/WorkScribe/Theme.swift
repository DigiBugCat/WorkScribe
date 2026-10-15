import AppKit
import SwiftUI

/// Indigo Wash (design/unified/shared.css) as SwiftUI tokens: Paper in light mode, Chalkboard in dark.
/// Fonts: the mockups use Newsreader (headings) and Manrope (UI). Neither is bundled, so headings fall back to
/// New York (`.serif` system design) and UI text to SF Pro.
enum Theme {
    static let surface = dynamic(light: 0xf1ebdd, dark: 0x22302b)
    static let surfaceRaised = dynamic(light: 0xf9f5ec, dark: 0x2b3b35)
    static let line = dynamic(light: 0xcfc3ab, dark: 0x465a52)
    static let ink = dynamic(light: 0x1f2a44, dark: 0xeee9dd)
    static let inkMuted = dynamic(light: 0x5a5f6e, dark: 0xaeb8b0)
    static let indigo = dynamic(light: 0x23456b, dark: 0x9dbbdd)
    static let onIndigo = dynamic(light: 0xf9f5ec, dark: 0x16201c)
    static let indigoWash = dynamic(light: 0x9db3c8, dark: 0x3e5a73)
    static let sky = dynamic(light: 0xc9d8d3, dark: 0x2e4640)
    static let sage = dynamic(light: 0x9db58c, dark: 0x557a62)
    static let ochre = dynamic(light: 0xe0a84a, dark: 0xe9b865)
    static let blush = dynamic(light: 0xe3b7a0, dark: 0x6b4538)
    static let leaf = dynamic(light: 0x3e6b4f, dark: 0x8cc0a0)
    static let vermilion = dynamic(light: 0xb4462f, dark: 0xee8c70)
    static let chip = dynamic(light: 0xe9e2d2, dark: 0x34443e)

    static let ochreNS = dynamicNS(light: 0xe0a84a, dark: 0xe9b865)
    static let vermilionNS = dynamicNS(light: 0xb4462f, dark: 0xee8c70)

    static func serif(_ size: CGFloat, weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight, design: .serif) }
    static let label = Font.system(size: 11, weight: .bold)
    static let caption = Font.system(size: 12, weight: .medium)
    static let body = Font.system(size: 14)

    static func dynamic(light: UInt32, dark: UInt32) -> Color { Color(nsColor: dynamicNS(light: light, dark: dark)) }
    static func dynamicNS(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
    }
}

/// "LOOKING IN", "OPEN ITEMS": the small-caps label role.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(Theme.label).tracking(0.9).foregroundStyle(Theme.inkMuted)
    }
}

/// A cut sheet on the surface: raised paper, a hairline edge, a small shadow.
struct PaperCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
            .shadow(color: Theme.ink.opacity(0.08), radius: 4, x: 1, y: 2)
    }
}

/// The one indigo action of a view.
struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.indigo
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(Theme.onIndigo)
            .background(tint.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Outlined secondary action.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(Theme.indigo)
            .background(configuration.isPressed ? Theme.chip : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.indigo.opacity(0.6), lineWidth: 1))
    }
}
