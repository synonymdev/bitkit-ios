# Plural localization

The existing `Localizable.strings` files remain the source of translation text and can be edited
directly. The app's Generate Plural Localizations build phase converts their cardinal plural messages into a separate
native Apple strings dictionary and an argument map in the built app. No generated translation
files are committed, and translation edits require no extra command or translation service.

The shared plural lookup uses the selected app language and delegates category selection and
number formatting to Foundation. A missing translation uses English text and English plural rules,
not the device language or the rules of the untranslated language. Ordinary translation lookup
continues to read the original table.

The converter supports the templates currently used by the app: cardinal category branches,
integer counts, number placeholders, named variables inside/outside branches, and surrounding
text. It is not a complete ICU MessageFormat implementation. Constructs such as offsets, explicit
numeric selectors, ordinal plurals, and select expressions need converter support before they can
be introduced. Malformed or unsupported cardinal templates fail the build with the source file
and translation key instead of silently shipping unformatted text.

The simulator suite `LocalizationPluralTests.swift` checks the built resources and public lookup.
The script `scripts/test-plural-localizations.swift` checks conversion edge cases on macOS, including
Unicode, literal percent signs, named argument positions, Arabic categories, and invalid templates.
The activity journey is `localized-plural-headings.xml`.
