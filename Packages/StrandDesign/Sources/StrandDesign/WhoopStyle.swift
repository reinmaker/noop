import SwiftUI

/// WHOOP-style fork tokens: the colours, type and metrics used by the WHOOP-style Home (score rings,
/// insight card, Health / Stress Monitor cards, My Day), the Sleep contributor rows and the floating
/// Coach button. Kept here, beside `StrandPalette` / `StrandFont`, so app code never hardcodes a value.
public enum WhoopStyle {

    // MARK: Surfaces

    public static let cardFill = Color(light: "#FFFFFF", dark: "#22272D")
    public static let cardStroke = Color(light: "#0000001A", dark: "#FFFFFF12")
    /// The dim full-circle track behind a score ring, and the unlit segment of a band bar.
    public static let ringTrack = Color(light: "#0000001F", dark: "#FFFFFF1F")
    public static let cardRadius: CGFloat = 18
    public static let cardPadding: CGFloat = 16
    public static let compactPadding: CGFloat = 14
    public static let rowGap: CGFloat = 12

    // MARK: Status

    public static let rangeGreen = Color(light: "#0E9F6E", dark: "#16D9A0")
    public static let rangeYellow = Color(light: "#B59A00", dark: "#F2D24B")
    public static let rangeAmber = Color(light: "#C77C00", dark: "#F5A623")
    public static let sufficientGray = Color(light: "#8A94A4", dark: "#B8C0CC")

    // MARK: Day in Review row

    public static let reviewGradient = LinearGradient(
        colors: [Color(light: "#5B4AA8", dark: "#3A2F66"), Color(light: "#2C6F7E", dark: "#1F4752")],
        startPoint: .leading, endPoint: .trailing)
    public static let reviewAccent = Color(light: "#3A7BD5", dark: "#7FB2FF")
    /// Text and icons drawn on a coloured gradient (always light, in both appearances).
    public static let onGradient = Color(hex: "#FFFFFF")

    // MARK: Floating Coach button

    public static let coachButtonFill = Color(hex: "#1C2230")
    public static let coachButtonRing: [Color] = [
        Color(hex: "#5B8CFF"), Color(hex: "#A86BFF"), Color(hex: "#3FD0E0"), Color(hex: "#5B8CFF"),
    ]
    public static let coachButtonShadow = Color(hex: "#00000073")
    public static let coachButtonSize: CGFloat = 58

    // MARK: Type

    /// Ring labels ("SLEEP", "RECOVERY", "STRAIN").
    public static let label = Font.system(size: 13, weight: .bold).width(.expanded)
    /// Card titles and status words ("HEALTH MONITOR", "WITHIN RANGE").
    public static let smallLabel = Font.system(size: 11, weight: .bold).width(.expanded)
    public static let sectionTitle = Font.system(size: 26, weight: .semibold)
    public static let headline = Font.system(size: 17, weight: .semibold)
    public static let body = Font.system(size: 15)
    public static let reading = Font.system(size: 16)
    public static let detail = Font.system(size: 13, weight: .semibold)
    public static let caption = Font.system(size: 13)
    public static let chevron = Font.system(size: 11, weight: .bold)
    public static let icon = Font.system(size: 15, weight: .semibold)
    public static let iconMedium = Font.system(size: 17)
    public static let iconLarge = Font.system(size: 20)
    public static let coachIcon = Font.system(size: 22, weight: .semibold)

    /// Bold condensed numerals — the score inside a ring, a monitor value, a contributor percentage.
    public static func number(_ size: CGFloat) -> Font {
        Font.system(size: size, weight: .bold).width(.condensed)
    }
}
