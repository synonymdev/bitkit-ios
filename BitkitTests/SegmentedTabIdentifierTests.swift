@testable import Bitkit
import XCTest

@MainActor
final class SegmentedTabIdentifierTests: XCTestCase {
    override func setUp() {
        super.setUp()
        snapshotAppDefaults("selectedLanguageCode")
        snapshotAppGroupDefaults("selectedLanguageCode")
    }

    func testTabIdentifiersStayEnglishInAnotherLanguage() {
        selectLanguage("fr")
        let items = SettingsTab.allCases.map { TabItem($0) }

        XCTAssertEqual(items.map(\.title), ["Général", "Sécurité et vie privée", "Avancé"])
        XCTAssertEqual(items.map(\.resolvedAccessibilityIdentifier), ["Tab-general", "Tab-security", "Tab-advanced"])
    }

    func testTabIdentifiersAreUnchangedInEnglish() {
        selectLanguage("en")
        let identifiers = SettingsTab.allCases.map { TabItem($0).resolvedAccessibilityIdentifier }

        XCTAssertEqual(identifiers, ["Tab-general", "Tab-security", "Tab-advanced"])
    }

    func testLabelAndExplicitIdentifierStillWin() {
        selectLanguage("fr")

        XCTAssertEqual(TabItem(SettingsTab.general, label: "Trezor").resolvedAccessibilityIdentifier, "Tab-trezor")
        XCTAssertEqual(TabItem(SettingsTab.general, accessibilityIdentifier: "Custom").resolvedAccessibilityIdentifier, "Custom")
    }

    func testEnglishOverrideEndsWithItsScope() {
        selectLanguage("fr")

        XCTAssertEqual(LocalizationHelper.inEnglish { t("settings__advanced_title") }, "Advanced")
        XCTAssertEqual(t("settings__advanced_title"), "Avancé")
    }

    private func selectLanguage(_ code: String) {
        UserDefaults.standard.set(code, forKey: "selectedLanguageCode")
        UserDefaults(suiteName: "group.bitkit")?.set(code, forKey: "selectedLanguageCode")
    }
}
