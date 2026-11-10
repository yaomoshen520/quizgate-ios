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
        /// 答对那一屏的渐变底色：白到一点点绿。原来写在 QuizView 的字面量里，
        /// 和 ok/okBg 分家之后，改成功色要改两个文件。
        static let successWash = Color(hex: 0xF2F9F4)
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
        /// 卡片的圆角。Android `bg_card.xml` 里写死的是 26dp、`bg_hero_card.xml` 用 radius_lg，
        /// 两者同值，所以这一档就是卡片档。
        static let card: CGFloat = 26
        /// 按钮、输入框、选项行。Android 那三个 drawable 都是 18dp（radius_md）。
        static let control: CGFloat = 18
        /// 「再想一步」那块解析底。Android `bg_note.xml` 是 16dp，比控件小一档、比胶囊大得多。
        static let note: CGFloat = 16
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
        /// 关闭答题页那颗叉的图标字号：它是个按钮的图标，不是正文，
        /// 但"图标多大"散在视图里就会有三处不一样的 22。
        static let icon: CGFloat = 22
        /// 答对那一屏的印章。
        static let successIcon: CGFloat = 64
    }

    enum Metric {
        /// 小朋友的指尖也得住，最小 52pt。所有可点元素都不许低于这个数。
        static let controlHeight: CGFloat = 52
        static let controlHeightLarge: CGFloat = 56
        static let chipHeight: CGFloat = 30
        static let progressHeight: CGFloat = 12
        /// 首页 hero 上那枚状态圆点。
        static let toneDot: CGFloat = 12
        /// 设置页步骤序号那枚圆章。
        static let stepBadge: CGFloat = 26
        /// 首页 hero 上那只狐狸的边长。和 Android activity_main.xml 的 44dp 同一个数：
        /// 两端首页第一段的第一眼必须是同一只狐狸、同一个大小。
        static let avatarHero: CGFloat = 44
        /// 答题页那只：比 hero 小一圈，它是陪跑的，不是主角。
        static let avatarQuiz: CGFloat = 40
    }

    enum Layout {
        /// 宽屏（iPad、iPad 侧边分屏后的全宽）上内容列的宽度上限。
        /// 不限宽的后果不是难看而是点不到：题干拉到 1000pt 一行要扫两次，
        /// 按钮横贯整屏后拇指够着的还是最左边那一段。
        static let maxContentWidth: CGFloat = 680
        /// 卡片网格在宽屏上的最小列宽。低于这个数就说明屏不够宽，退回单列。
        static let minColumnWidth: CGFloat = 320
        /// 答题页顶部那枚知识点标签的截断宽度：宽屏给得多一点，窄屏必须让位给关闭按钮。
        static let chipMaxWide: CGFloat = 260
        static let chipMaxNarrow: CGFloat = 140
        /// 答对那一屏的内容列宽：一句「答对了」铺满 iPad 会变成一张横幅。
        static let successColumnWidth: CGFloat = 520
    }

    static let pageGradient = LinearGradient(
        colors: [Palette.pageTop, Palette.pageBottom],
        startPoint: .top, endPoint: .bottom
    )

    /// 首页第一段那张卡的底：Android `bg_hero_card.xml` 是 brand_050 → card 的 315° 渐变，
    /// 换算到 SwiftUI 的坐标就是左上到右下。hero 之外一律纯白，不然整屏都是淡蓝块。
    static let heroWash = LinearGradient(
        colors: [Palette.brand050, Palette.card],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// 主按钮：Android `bg_primary_button.xml` 常态是 brand_500 → brand_600 的 270°（上到下）渐变，
    /// 按下换成 brand_600 纯色。
    static let primaryButton = LinearGradient(
        colors: [Palette.brand500, Palette.brand600],
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
/// 内边距 24、圆角 26、描边 1pt：三个数都取自 Android `bg_card.xml` + 布局里的 `padding=space_6`。
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.Space.s6)
            .background(Theme.Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Palette.cardStroke, lineWidth: 1)
            )
    }
}

/// 首页第一段专用：同一副尺寸，底色换成淡蓝渐变、描边换成 brand_200。
/// 单独一个 modifier 而不是给 `card()` 加参数，是因为「哪一块是 hero」这件事
/// 只该由首页那一处决定，传参的版本迟早会被第二屏拿去当普通卡用。
struct HeroCardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.Space.s6)
            .background(Theme.heroWash)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Palette.brand200, lineWidth: 1)
            )
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
    func heroCard() -> some View { modifier(HeroCardBackground()) }
}

/// 宽屏限宽，窄屏铺满。
///
/// 双层 frame 是刻意的：里层那一圈把内容压到 `maxWidth`，外层再让这块内容在整屏里居中。
/// 只写里层会出现「内容贴左边、右边一片空白」，只写外层等于没限宽。
struct ReadableColumn: ViewModifier {
    var maxWidth: CGFloat = Theme.Layout.maxContentWidth

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: maxWidth, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

extension View {
    func readableColumn() -> some View { modifier(ReadableColumn()) }

    /// 少数几块内容比正文列更该收窄（比如答对那整屏的成功层：一句「答对了」铺满 iPad
    /// 会变成一张横幅），所以留一个带宽度的重载，而不是再抄一遍 modifier。
    func readableColumn(_ maxWidth: CGFloat) -> some View { modifier(ReadableColumn(maxWidth: maxWidth)) }
}

/// 卡片网格的列定义：宽屏两列、窄屏一列。
/// 把 size class 由调用方传进来而不是在这里摸 environment，是因为三屏都要用同一份判据，
/// 而「iPad 上现在是不是全宽」这件事一旦在两处各判一次，迟早有一处判错。
/// 列间距与段间距同一个数（16）：Android 卡片之间是 `layout_marginTop=space_4`，
/// 宽屏并两列时横向缝隙要是比纵向大，同一段落看起来就成了两块不相干的东西。
func cardGridColumns(wide: Bool) -> [GridItem] {
    if wide {
        return [GridItem(.adaptive(minimum: Theme.Layout.minColumnWidth,
                                   maximum: Theme.Layout.maxContentWidth),
                         spacing: Theme.Space.s4)]
    }
    return [GridItem(.flexible(), spacing: Theme.Space.s4)]
}