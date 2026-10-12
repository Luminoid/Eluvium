import LumiKitUI
import UIKit

/// Theme derived from primary color #007AFF. Text-carrying semantic colors
/// (`primary`, `warning`, `error`, status tones) hold WCAG AA (≥4.5:1)
/// against `backgroundPrimary` and `backgroundSecondary` in their mode;
/// `success` colors glyphs only (the Identity confirm mark), so it holds the
/// 3:1 non-text floor instead. Dark variants are brighter, never darker,
/// than their light counterparts.
extension LMKTheme {
    /// Applied once at launch (`LMKTheme.apply(.eluviumExample)`); every
    /// `LMKColor` token re-resolves through the theme trait.
    static let eluviumExample: LMKTheme = {
        var theme = LMKTheme(colors: .eluviumExample)
        // The looks the app had before LumiKit 1.0: transport and row glyphs
        // at the row symbol size (1.0's button default is the larger action
        // size), and full-screen empty states with a heading-size message
        // (1.0 splits them into a heading title and a body message). Every
        // button keeps the 44pt touch floor here, once, instead of a height
        // constraint at each call site.
        theme.button = LMKButton.Style(symbolPointSize: theme.layout.symbolRow, minimumHeight: theme.layout.minimumTouchTarget)
        theme.emptyState = LMKEmptyStateView.Style(messageTextStyle: .h3)
        return theme
    }()
}

private extension LMKColorTheme {
    /// Only the roles that differ from LumiKit's defaults are named: text
    /// colors stay the system labels, and `outline` stays LumiKit's
    /// half-alpha `divider`.
    static let eluviumExample = LMKColorTheme(
        // Dark mode gets the lighter blue: 0x4DA3FF reads 6.4:1 on
        // `backgroundPrimary` and 5.5:1 on `backgroundSecondary` (0x007AFF
        // sat at 4.2:1 and 3.6:1). A light accent takes dark text, so the
        // dark `onAccent` below is near-black (the tonal-theme rule).
        primary: .lmk_dynamic(lightHex: 0x0068D9, darkHex: 0x4DA3FF),
        primaryVariant: .lmk_dynamic(lightHex: 0x0055B3, darkHex: 0x3D8FE6),
        secondary: .lmk_dynamic(lightHex: 0x4845E6, darkHex: 0x3633CC),
        tertiary: .lmk_dynamic(lightHex: 0x29C8CC, darkHex: 0x22E1E6),
        // 0x248A3D is 4.0:1 on the light backgrounds (0x34C759 was 2.0:1),
        // clear of the 3:1 floor for the glyphs it colors.
        success: .lmk_dynamic(lightHex: 0x248A3D, darkHex: 0x30D158),
        // Warning copy is load-bearing status text: 0x8A6A15 reads 4.5:1 on
        // `backgroundPrimary` and 4.8:1 on `backgroundSecondary` (the old
        // 0xD6A85C sat below 2.1:1 on both).
        warning: .lmk_dynamic(lightHex: 0x8A6A15, darkHex: 0xE6B86C),
        // Failure copy is status text too: 0xD70015 reads 4.8:1 on
        // `backgroundPrimary` and 5.1:1 on `backgroundSecondary` (0xFF3B30
        // was 3.2:1); the dark 0xFF5C52 holds 5.5:1 and 4.7:1.
        error: .lmk_dynamic(lightHex: 0xD70015, darkHex: 0xFF5C52),
        info: .lmk_dynamic(lightHex: 0x6FAFCF, darkHex: 0x8FCFEF),
        // On the accent fills: light 0xFAFAFA on 0x0068D9 is 5.1:1; dark
        // 0x0A0A0A on 0x4DA3FF is 7.5:1 (0xE6E6E6 there was 2.1:1).
        onAccent: .lmk_dynamic(lightHex: 0xFAFAFA, darkHex: 0x0A0A0A),

        backgroundPrimary: .lmk_dynamic(lightHex: 0xF0F3F7, darkHex: 0x1D1E1F),
        backgroundSecondary: .lmk_dynamic(lightHex: 0xF7F9FA, darkHex: 0x292A2B),
        backgroundTertiary: .lmk_dynamic(lightHex: 0xE9EDF2, darkHex: 0x242526),

        divider: .lmk_dynamic(lightHex: 0xD7DADE, darkHex: 0x3B3C3D),
        fill: .lmk_dynamic(lightHex: 0xD9D9D9, darkHex: 0x595959),
        fillStrong: .lmk_dynamic(lightHex: 0xBFBFBF, darkHex: 0x737373),

        // The dimming base stays dark in both modes (the 0.x `black` role
        // flipped to near-white in dark mode, which a scrim must not).
        scrim: UIColor(lmk_hex: 0x1A1A1A)
    )
}
