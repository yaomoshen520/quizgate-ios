import SwiftUI

/// 逐值转写 Android app/src/main/res/values/colors.xml 与 dimens.xml。
/// 孩子端用 #4C6EF5（明快），家长后台用 #3056D3（沉稳），同一个蓝家族不同明度。
/// 改这里之前先改 Android 那份，两边要一起动。
enum Theme {

    enum Palette {
        static let brand050 = Color(hex: 0xF4F7FF)
        static let brand100 = Color(hex: 0xEDF2FF)
        static let brand200 = Color(hex: 0xDCE5FF)
        static let brand300 = Color(hex: 0xB9C6F5)
        static let brand400 = Color(hex: 0x7A96F0)
        static let brand500 = Color(hex: 0x4C6EF5)
        static let brand600 = Color(hex: 0x3B5BDB)
        static let brand700 = Color(hex: 0x2B48A8)

        static let ink = Color(hex: 0x1C1E2A)
        static let inkSoft = Color(hex: 0x5B6178)
        static let inkFaint = Color(hex: 0x8A90A2)
        static let inkOnBrand = Color.white

        static let pageTop = Color(hex: 0xEEF2FF)
        static let pageBottom = Color.white
        static let card = Color.white
        static let cardStroke = Color(hex: 0xE6EAF6)
        static let surfaceSunken = Color(hex: 0xF4F6FB)

        static let ok = Color(hex: 0x1D7A46)
        static let okBg = Color(hex: 0xE7F6EC)
        static let okStroke = Color(hex: 0xA9DDBB)
        static let warn = Color(hex: 0x9A5B0A)
        static let warnBg = Color(hex: 0xFFF4E0)
        static let warnStroke = Color(hex: 0xF0D29A)
        static let danger = Color(hex: 0xB3261E)
        static let dangerBg = Color(hex: 0xFDECEA)
        static let dangerStroke = Color(hex: 0xF0B4AC)

        static let optionStroke = Color(hex: 0xDFE4F1)
        static let optionPressed = Color(hex: 0xF4F7FF)
        static let noteBg = Color(hex: 0xFFF6E5)
        static let noteStroke = Color(hex: 0xF2D9A6)
        static let noteInk = Color(hex: 0x7A5230)
    }

    enum Space {
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s5: CGFloat = 20
        static let s6: CGFloat = 24
        static let s8: CGFloat = 32
        static let s10: CGFloat = 40
    }

    enum Radius {
        static let sm: CGFloat = 12
        static let md: CGFloat = 18
        static let lg: CGFloat = 26
        static let pill: CGFloat = 100
    }

    enum Text {
        static let caption: CGFloat = 12
        static let label: CGFloat = 13
        static let body: CGFloat = 15
        static let control: CGFloat = 17
        static let title: CGFloat = 21
        static let stem: CGFloat = 26
        static let option: CGFloat = 18
        static let hero: CGFloat = 34
    }

    enum Metric {
        /// 小朋友的指尖也得住，最小 52pt。所有可点元素都不许低于这个数。
        static let controlHeight: CGFloat = 52
        static let controlHeightLarge: CGFloat = 56
        static let chipHeight: CGFloat = 30
        static let progressHeight: CGFloat = 12
    }

    static let pageGradient = LinearGradient(
        colors: [Palette.pageTop, Palette.pageBottom],
        startPoint: .top, endPoint: .bottom
    )
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// 卡片样式收在一处，三屏共用，避免各写一套圆角和描边。
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.Space.s5)
            .background(Theme.Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(Theme.Palette.cardStroke, lineWidth: 1)
            )
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}