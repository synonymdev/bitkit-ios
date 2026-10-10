@testable import Bitkit
import XCTest

@MainActor
final class LocalizationPluralTests: XCTestCase {
    override func setUp() {
        super.setUp()
        snapshotAppDefaults("selectedLanguageCode")
        snapshotAppGroupDefaults("selectedLanguageCode")
    }

    func testAffectedActivityTranslationsResolveSingularAndPluralLabels() {
        let cases = [
            ("cs", "INPUT", "VSTUPY (2)", "VÝSTUP", "VÝSTUPY (2)"),
            ("es", "ENTRADA", "ENTRADAS (2)", "SALIDA", "SALIDAS (2)"),
            ("es-419", "ENTRADA", "ENTRADAS (2)", "SALIDA", "SALIDAS (2)"),
            ("fr", "ENTRÉE", "ENTRÉES (2)", "SORTIE", "SORTIES (2)"),
            ("pl", "WEJŚCIE", "WEJŚCIA (2)", "WYJŚCIE", "WYJŚCIA (2)"),
            ("pt-BR", "ENTRADA", "ENTRADAS (2)", "SAÍDA", "SAÍDAS (2)"),
            ("ru", "ВВОД", "ВВОДЫ (2)", "ВЫХОД", "ВЫХОДЫ (2)"),
        ]
        for (language, inputOne, inputOther, outputOne, outputOther) in cases {
            selectLanguage(language)
            XCTAssertEqual(tPlural("wallet__activity_input", arguments: ["count": 1]), inputOne, language)
            XCTAssertEqual(tPlural("wallet__activity_input", arguments: ["count": 2]), inputOther, language)
            XCTAssertEqual(tPlural("wallet__activity_output", arguments: ["count": 1]), outputOne, language)
            XCTAssertEqual(tPlural("wallet__activity_output", arguments: ["count": 2]), outputOther, language)
        }
    }

    func testRussianAndPolishUseDifferentRulesForTwentyOne() {
        selectLanguage("ru")
        XCTAssertEqual(tPlural("wallet__activity_input", arguments: ["count": 21]), "ВВОД")
        XCTAssertEqual(tPlural("wallet__activity_input", arguments: ["count": 22]), "ВВОДЫ (22)")
        selectLanguage("pl")
        XCTAssertEqual(tPlural("wallet__activity_input", arguments: ["count": 21]), "WEJŚCIA (21)")
        XCTAssertEqual(tPlural("wallet__activity_input", arguments: ["count": 22]), "WEJŚCIA (22)")
    }

    func testFrenchAndBrazilianPortugueseUseSingularForZero() {
        selectLanguage("fr")
        XCTAssertEqual(tPlural("wallet__activity_input", arguments: ["count": 0]), "ENTRÉE")
        selectLanguage("pt-BR")
        XCTAssertEqual(tPlural("wallet__activity_input", arguments: ["count": 0]), "ENTRADA")
    }

    func testRussianBackupMessageResolvesEveryIntegerCategory() {
        selectLanguage("ru")
        for (count, suffix) in [(1, "1 минуту."), (2, "2 минуты."), (5, "5 минут."), (11, "11 минут."), (21, "21 минуту."), (22, "22 минуты.")] {
            let message = tPlural("settings__backup__failed_message", arguments: ["interval": count])
            XCTAssertTrue(message.hasSuffix(suffix), message)
            XCTAssertFalse(message.contains("{interval"), message)
        }
    }

    func testEnglishAndGreekContinueToResolveSimplePlurals() {
        selectLanguage("en")
        XCTAssertEqual(tPlural("wallet__activity_input", arguments: ["count": 0]), "INPUTS (0)")
        XCTAssertEqual(tPlural("wallet__activity_input", arguments: ["count": 1]), "INPUT")
        XCTAssertEqual(tPlural("wallet__activity_output", arguments: ["count": 5]), "OUTPUTS (5)")
        selectLanguage("el")
        XCTAssertEqual(tPlural("wallet__activity_input", arguments: ["count": 2]), "ΕΙΣΟΔΟΙ (2)")
    }

    func testEnglishFallbackUsesEnglishPluralRulesForMissingTranslations() {
        for language in ["ar", "pt", "unsupported"] {
            selectLanguage(language)
            XCTAssertEqual(tPlural("wallet__activity_input", arguments: ["count": 0]), "INPUTS (0)", language)
            XCTAssertEqual(tPlural("wallet__activity_input", arguments: ["count": 1]), "INPUT", language)
            XCTAssertEqual(tPlural("wallet__activity_input", arguments: ["count": 21]), "INPUTS (21)", language)
        }
    }

    func testSelectedAppLanguageOverridesDeviceLocaleAndStandardDefaults() {
        UserDefaults.standard.set("en", forKey: "selectedLanguageCode")
        UserDefaults(suiteName: "group.bitkit")?.set("pl", forKey: "selectedLanguageCode")
        XCTAssertEqual(tPlural("wallet__activity_input", arguments: ["count": 2]), "WEJŚCIA (2)")
    }

    func testNestedArgumentAndTextOutsidePluralArePreserved() {
        selectLanguage("ru")
        XCTAssertEqual(
            tPlural("settings__addr__spend_number", arguments: ["count": 2, "fundsToSpend": "100"]),
            "Потратить ₿ 100 с 2 адресов"
        )
        selectLanguage("en")
        XCTAssertEqual(
            tPlural("settings__backup__failed_message", arguments: ["interval": 2]),
            "Bitkit failed to back up wallet data. Retrying in 2 minutes."
        )
    }

    func testNumericStringAndUnsignedCountsAreSupported() {
        selectLanguage("pl")
        for count: Any in ["2", UInt32(2), UInt64(2), Double(2)] {
            XCTAssertEqual(tPlural("wallet__activity_input", arguments: ["count": count]), "WEJŚCIA (2)")
        }
    }

    func testNonPluralVariableSubstitutionRemainsSupported() {
        selectLanguage("en")
        XCTAssertEqual(tPlural("cards__transferPending__description", arguments: ["duration": "5 minutes"]), "Ready in 5 minutes")
        XCTAssertEqual(t("wallet__activity_input"), LocalizationHelper.getString(for: "wallet__activity_input"))
    }

    func testMissingOrInvalidArgumentsDoNotCrashOrInventACount() {
        selectLanguage("en")
        let source = LocalizationHelper.getString(for: "wallet__activity_input")
        XCTAssertEqual(tPlural("wallet__activity_input"), source)
        for count: Any in ["invalid", Double.nan, Double.infinity, UInt64.max] {
            XCTAssertEqual(tPlural("wallet__activity_input", arguments: ["count": count]), source)
        }
        XCTAssertEqual(tPlural("missing_plural_translation", arguments: ["count": 2]), "missing_plural_translation")
    }

    func testEveryAvailableActivityTranslationResolvesRepresentativeCounts() throws {
        for language in ["ca", "cs", "de", "el", "en", "es", "es-419", "fr", "it", "nl", "pl", "pt-BR", "ru"] {
            selectLanguage(language)
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            XCTAssertNotNil(bundle.url(forResource: "LocalizablePlurals", withExtension: "stringsdict"), language)
            XCTAssertNotNil(bundle.url(forResource: "PluralArguments", withExtension: "plist"), language)
            for key in ["wallet__activity_input", "wallet__activity_output"] {
                for count in [0, 1, 2, 5, 11, 21, 22, 1_000_000] {
                    let result = tPlural(key, arguments: ["count": count])
                    XCTAssertFalse(result.contains("{count"), "\(language): \(result)")
                    XCTAssertFalse(result.contains("%#@"), "\(language): \(result)")
                    XCTAssertNotEqual(result, key, language)
                }
            }
        }
    }

    private func selectLanguage(_ code: String) {
        UserDefaults.standard.set(code, forKey: "selectedLanguageCode")
        UserDefaults(suiteName: "group.bitkit")?.set(code, forKey: "selectedLanguageCode")
    }
}
