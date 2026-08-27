import CoreText
import SwiftUI

enum AppBrand {
    static let lava = Color(red: 1, green: 54 / 255, blue: 33 / 255)
    static let navy900 = Color(red: 11 / 255, green: 32 / 255, blue: 38 / 255)
    static let navy800 = Color(red: 27 / 255, green: 49 / 255, blue: 57 / 255)
    static let navy600 = Color(red: 27 / 255, green: 81 / 255, blue: 98 / 255)
    static let navy300 = Color(red: 196 / 255, green: 204 / 255, blue: 214 / 255)
    static let oatMedium = Color(red: 238 / 255, green: 237 / 255, blue: 233 / 255)
    static let oatLight = Color(red: 249 / 255, green: 247 / 255, blue: 244 / 255)
    static let grayText = Color(red: 90 / 255, green: 111 / 255, blue: 119 / 255)
    static let grayLines = Color(red: 220 / 255, green: 224 / 255, blue: 226 / 255)
    static let green = Color(red: 0, green: 135 / 255, blue: 92 / 255)

    static let background = oatLight
    static let surface = Color.white
    static let primaryText = navy900
    static let secondaryText = grayText
    static let line = grayLines
    static let control = oatMedium.opacity(0.62)

    static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(fontName(for: weight), size: size)
    }

    static func registerFonts() {
        guard let url = Bundle.module.url(
            forResource: "DMSans-Variable",
            withExtension: "ttf"
        ) else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    private static func fontName(for weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black:
            "DMSans-9ptRegular_Bold"
        case .semibold:
            "DMSans-9ptRegular_SemiBold"
        case .medium:
            "DMSans-9ptRegular_Medium"
        default:
            "DMSans-9ptRegular_Regular"
        }
    }
}

enum BrandButtonKind {
    case primary
    case secondary
}

struct BrandButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let kind: BrandButtonKind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppBrand.font(size: 12, weight: .semibold))
            .foregroundStyle(kind == .primary ? Color.white : AppBrand.primaryText)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(kind == .primary ? AppBrand.lava : AppBrand.control)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(kind == .primary ? AppBrand.lava : AppBrand.line, lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.45)
    }
}

struct BrandControlChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(AppBrand.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(AppBrand.control)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(AppBrand.line, lineWidth: 1)
            }
    }
}

extension View {
    func brandControlChrome() -> some View {
        modifier(BrandControlChrome())
    }
}
