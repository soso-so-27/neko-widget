"""11/22 (three moments, presentation only): no new feature, no new words.

A. The birthday and the day a cat came home: on the day, the この子 hero's
   line leads with `birthday.cake` / `house` at the text's size and colour, a
   little heavier; a departed cat has no mark. The Widget's cloudy tag leads
   with the day's symbol (a closed book on a work's day) and drops it first
   when space is short; the hand alone stays the last form.
B. A newly delivered work's cover is under the Widget's 「くもり」 until it is
   opened once (the existing AlbumPrototype.openedKey); one tap clears it with
   the Widget's 1.9 s and then opens it (or the Plus screen) as before.
C. 「置けました」: the first found cat in the Widget's shape, frosted, clears
   once; Reduce Motion shows it clear; no photo: the check as before.
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def section(text, start, end):
    a = text.index(start)
    return text[a:text.index(end, a + len(start))]


HOME = read("NekoWidget/Views/CatHomeView.swift")
WIDGET = read("NekoWidgetWidget/NekoWidgetView.swift")
STORE = read("Shared/Storage/CloudyWindowStore.swift")
ALBUM = read("NekoWidget/Views/AlbumPrototypeView.swift")
ONBOARDING = read("NekoWidget/Views/OnboardingView.swift")
VERIFY = read("ci/verify-cloudy-window.swift")


class HeroDayMarkTests(unittest.TestCase):
    def test_the_symbol_follows_the_same_day_as_the_line(self):
        facts = section(HOME, "struct CatHomeFacts {", "/// The five tools, in the order of the page.")
        self.assertIn("var daySymbol: String? = nil", facts)
        self.assertIn("CatHomeCareCore.heroDayLine(", facts)
        self.assertIn("CatHomeCareCore.heroDay(birthday: birthdayDay", facts)
        self.assertIn('case .birthday?: "birthday.cake"', facts)
        self.assertIn('case .adoption?: "house"', facts)
        # A departed cat returns before any day is worked out: no mark.
        self.assertLess(facts.index('line: "旅立った日　" + day'), facts.index("daySymbol: symbol"))
        departed = section(facts, "if let farewell {", "let birthday: Date?")
        self.assertNotIn("daySymbol", departed)

    def test_the_line_keeps_its_look_and_only_gains_the_mark(self):
        words = section(HOME, "private var words: some View {", "private func nameFit(")
        line = section(words, "if let line = facts.line {", "if pageCount > 1 {")
        self.assertIn("if let symbol = facts.daySymbol {\n                        Image(systemName: symbol)", line)
        self.assertIn(".font(.subheadline.weight(facts.daySymbol == nil ? .semibold : .bold))", line)
        self.assertIn(".foregroundStyle(.white.opacity(0.92))", line)
        self.assertIn(".lineLimit(typeSize.isAccessibilitySize ? 3 : 2)", line)
        self.assertIn(".minimumScaleFactor(0.85)", line)
        # The existing shadow covers the mark too.
        self.assertIn(".shadow(color: .black.opacity(0.45), radius: 8, y: 1)", words)


class WidgetTagSymbolTests(unittest.TestCase):
    def test_the_symbol_comes_from_the_tag_model(self):
        symbol = section(STORE, "static func tagSymbol(_ selection: CloudyWindowSelection) -> String {", "\n    }\n")
        self.assertIn('static let tapSymbol = "hand.tap.fill"', STORE)
        self.assertIn('"birthday.cake.fill" : "house.fill"', symbol)
        self.assertIn('selection.albumPeriod == nil ? tapSymbol : "book.closed.fill"', symbol)
        self.assertIn("if let milestone = milestoneOf(selection) {", symbol)
        self.assertIn('"the tag\'s symbol: hand, cake, house, closed book"', VERIFY)

    def test_the_day_symbol_goes_first_when_space_is_short(self):
        capsule = section(WIDGET, "Button(intent: RevealCloudyWindowIntent(selection: selection)) {", ".buttonStyle(.plain)")
        self.assertIn("let symbol = CloudyWindowDayText.tagSymbol(selection)", capsule)
        forms = capsule.index("revealCapsule(forms[$0], symbol: symbol)")
        bare = capsule.index("revealCapsuleChrome(Text(forms[forms.count - 1])")
        reduced = capsule.index("ReducedRevealLabel(text: forms[forms.count - 1], showsSymbol: !daySymbol)")
        hand = capsule.index('revealCapsuleChrome(Image(systemName: "hand.tap.fill")')
        self.assertLess(forms, bare)
        self.assertLess(bare, reduced)
        self.assertLess(reduced, hand)
        reveal = section(WIDGET, "private func revealCapsule(", "/// Used only inside")
        self.assertIn("symbol: String = CloudyWindowDayText.tapSymbol", reveal)
        self.assertIn("Label(text, systemImage: symbol)", reveal)
        self.assertIn(".font(.caption.weight(.semibold))", reveal)


class AlbumArrivalFrostTests(unittest.TestCase):
    def test_the_frost_uses_the_widgets_values(self):
        look = section(ALBUM, "enum CloudyFrostLook {", "/// A photo under the Widget's")
        self.assertIn("static let clearDuration: Double = 1.9", look)
        self.assertIn("static let photo = Animation.easeInOut(duration: 1.9)", look)
        self.assertIn("static let fog = Animation.easeInOut(duration: 1.7)", look)
        self.assertIn("static let puffOpacity = 0.42", look)
        self.assertIn("static let puffBlurShare: CGFloat = 0.12", look)
        self.assertIn("CGFloat(CloudyWindowStrength.strong.radius) * width / 500", look)
        # The same numbers as the Widget's own fog and reveal.
        self.assertIn("static let photo = Animation.easeInOut(duration: 1.9)", WIDGET)
        self.assertIn("static let fog = Animation.easeInOut(duration: 1.7)", WIDGET)
        self.assertIn(".fill(Color.white.opacity(0.42))", WIDGET)
        self.assertIn("var strength: CloudyWindowStrength = .strong", STORE)
        photo = section(ALBUM, "struct CloudyFrostPhoto<Photo: View>: View {", "\n}\n")
        self.assertIn(".blur(radius: isCloudy ? CloudyFrostLook.blurRadius(width: size.width) : 0, opaque: true)", photo)
        self.assertIn(".animation(reduceMotion ? nil : CloudyFrostLook.photo, value: isCloudy)", photo)
        self.assertIn(".animation(reduceMotion ? nil : CloudyFrostLook.fog, value: isCloudy)", photo)
        self.assertIn(".allowsHitTesting(false)", photo)

    def test_only_an_unopened_cover_is_frosted_and_one_tap_clears_then_opens(self):
        card = section(ALBUM, "private func arrivalCard(", "/// One tap: a frosted cover clears")
        self.assertIn("let frosted = wrapped && cover != nil && !clearedCovers.contains(id)", card)
        self.assertIn("Button { clearThenOpen(id: id, frosted: frosted, open: open) } label: {", card)
        self.assertIn("CloudyFrostPhoto(isCloudy: frosted, reduceMotion: reduceMotion) {", card)
        # 「とどきました」 and the Plus mark are drawn over the photo, as before.
        self.assertLess(card.index("CloudyFrostPhoto("), card.index('Text("とどきました")'))
        self.assertIn('Text("Plusでひらく")', card)
        # 「opened once」 is the existing key, not a new one.
        self.assertIn("@AppStorage(AlbumPrototype.openedKey) private var openedJSON", ALBUM)
        self.assertIn("guard !opened.contains(letter.periodIdentifier), enabledAt > 0,", ALBUM)
        self.assertIn("wrapped: !opened.contains(id)", ALBUM)
        clear = section(ALBUM, "private func clearThenOpen(", "\n    }\n")
        self.assertIn("guard clearingCover == nil else { return }", clear)
        self.assertIn("guard frosted else { open(); return }", clear)
        self.assertIn("guard !reduceMotion else { open(); return }", clear)
        self.assertIn("try? await Task.sleep(for: .seconds(CloudyFrostLook.openAfter))", clear)
        self.assertLess(clear.index("Task.sleep"), clear.rindex("open()"))
        self.assertNotIn("UserDefaults", clear)


class PlacedPhotoTests(unittest.TestCase):
    def test_the_first_found_cat_in_the_widgets_shape(self):
        self.assertIn("OnboardingWidgetPlacedPage(photo: resultPhotos.first, close: finish)", ONBOARDING)
        page = section(ONBOARDING, "private struct OnboardingWidgetPlacedPage: View {", "/// The optional Plus page")
        self.assertIn("CloudyFrostPhoto(isCloudy: !cleared && !reduceMotion, reduceMotion: reduceMotion) {", page)
        self.assertIn(".clipShape(RoundedRectangle(cornerRadius: NekoRadius.hero, style: .continuous))", page)
        self.assertIn("networkAccessAllowed: false", page)
        self.assertIn("guard photoLoaded, !cleared, !reduceMotion else { return }", page)
        # No photo, or one that cannot load: the check as before.
        self.assertIn("if let photo, !photoFailed {", page)
        self.assertIn('Image(systemName: "checkmark.circle.fill")\n                    .font(.system(size: 56, weight: .regular))', page)
        # Title, sentence, button and the haptic stay.
        for kept in ("OnboardingPresentationCopy.widgetPlacedTitle", "OnboardingPresentationCopy.widgetPlacedBody",
                     "OnboardingPresentationCopy.widgetPlacedAction", '.accessibilityIdentifier("onboarding-widget-placed-close")',
                     '.accessibilityIdentifier("onboarding-widget-placed")'):
            self.assertIn(kept, page)
        self.assertIn(".sensoryFeedback(.success, trigger: page == .widgetGuide && isWidgetPlaced)", ONBOARDING)


class RestraintTests(unittest.TestCase):
    def test_no_emoji_confetti_or_sparkles(self):
        for text in (section(ALBUM, "enum CloudyFrostLook {", "\n}\n"),
                     section(ONBOARDING, "private struct OnboardingWidgetPlacedPage: View {", "/// The optional Plus page"),
                     section(HOME, "private var words: some View {", "private func nameFit(")):
            for banned in ("sparkle", "confetti", "LinearGradient", "おめでとう"):
                self.assertNotIn(banned, text)


if __name__ == "__main__":
    unittest.main()
