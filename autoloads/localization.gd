extends Node
## Discovers and registers this project's UI strings with Godot's TranslationServer,
## then applies the saved locale on startup.
##
## Languages live as data, not code: one JSON file per locale under
## res://localization/locales/, each self-contained ({"locale", "name", "strings"}).
## Adding a language means dropping a new file there — nothing here changes, and
## the language dropdown in SettingsMenu reflects whatever's found at runtime, not
## a hardcoded list. Removing a language is equally just deleting its file.
##
## Fail-safes (each independent, so one broken file can't take down the rest):
## - A locale file that's missing, unreadable, not valid JSON, or missing/wrong-
##   typed "locale"/"strings" fields is skipped with a warning — never crashes
##   the scan or blocks the other files from loading.
## - A locale file with no "name" falls back to showing its locale code instead.
## - If the locale saved in SettingsManager isn't among what actually loaded this
##   run (e.g. its file was deleted), falls back to "en" if available, else
##   whatever DID load, else leaves Godot's own untranslated-key behavior in
##   place — degrades visibly (raw keys on screen) rather than silently or by
##   crashing, which is the honest outcome if content is genuinely missing.
## - No embedded duplicate "emergency" string table: that would just be a second
##   copy of en.json to keep in sync by hand, trading one failure mode for a
##   quieter one. Godot's own tr() already falls back to returning the key
##   unresolved when nothing is registered, which is enough of a visible signal.
##
## Every Control.text/placeholder_text is set to a KEY (whether in a .tscn or
## from a script) and resolved by retranslate_tree() — NOT by relying on Godot's
## built-in Control auto-translate. That built-in mechanism turned out not to
## reliably re-resolve an assigned property value in this project when verified
## headlessly (atr() resolves a key correctly when called explicitly; the stored
## .text property did not update on its own even after several idle frames), and
## since a real windowed run couldn't be visually confirmed either, this project
## does not depend on it at all — retranslate_tree() is explicit, testable, and
## works identically whether it's the first load or a live language switch.
##
## tr() is called explicitly anywhere a string is built manually and never
## passes through a Control's text property — the BBCode chat/system messages
## (lobby.gd/network_manager.gd/voip_network.gd/chat_ui.gd) and anywhere a runtime
## value is interpolated into the result (a string like "Ping: 42ms" can never
## match a translation key itself — see NetworkManager._process()'s ping label).

const LOCALES_DIR := "res://localization/locales/"

## locale -> display name, for whatever actually loaded successfully this run.
## Populated by _scan_locales(); SettingsMenu's language dropdown reads this
## rather than any hardcoded list.
var _available: Dictionary = {}

## Union of every key across every successfully loaded locale — used by
## retranslate_tree() to recognize "this Control.text value is a translation key"
## regardless of which specific locale(s) actually loaded.
var _known_keys: Dictionary = {}

func _ready():
	_scan_locales()
	if _available.is_empty():
		push_error("Localization: no valid locale files found under %s — UI will show raw translation keys instead of text. Check that the folder exists and contains valid {locale, name, strings} JSON files." % LOCALES_DIR)
		return
	var wanted := SettingsManager.get_locale()
	if not _available.has(wanted):
		var fallback: String = "en" if _available.has("en") else _available.keys()[0]
		push_warning("Localization: saved locale '%s' is not available (its file may have been removed) — falling back to '%s'." % [wanted, fallback])
		wanted = fallback
	TranslationServer.set_locale(wanted)

## locale -> display name, e.g. {"en": "English", "pt_BR": "Português (Brasil)"}.
## Reflects whatever loaded successfully this run — see the class doc's fail-safes.
func get_available_locales() -> Dictionary:
	return _available

func _scan_locales():
	var dir := DirAccess.open(LOCALES_DIR)
	if dir == null:
		push_error("Localization: could not open %s (error %d) — no languages will be available." % [LOCALES_DIR, DirAccess.get_open_error()])
		return

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.get_extension() == "json":
			_load_locale_file(LOCALES_DIR + file_name)
		file_name = dir.get_next()
	dir.list_dir_end()

func _load_locale_file(path: String):
	if not FileAccess.file_exists(path):
		push_warning("Localization: %s disappeared mid-scan, skipping." % path)
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("Localization: could not open %s (error %d), skipping." % [path, FileAccess.get_open_error()])
		return
	var text := file.get_as_text()
	file.close()

	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_warning("Localization: %s is not valid JSON (or not a JSON object), skipping." % path)
		return

	var locale = parsed.get("locale")
	if not (locale is String) or locale.is_empty():
		push_warning("Localization: %s has a missing or invalid \"locale\" field, skipping." % path)
		return

	var strings = parsed.get("strings")
	if not (strings is Dictionary) or strings.is_empty():
		push_warning("Localization: %s has a missing, invalid, or empty \"strings\" field, skipping." % path)
		return

	var display_name = parsed.get("name")
	if not (display_name is String) or display_name.is_empty():
		push_warning("Localization: %s has no \"name\" field — showing the locale code '%s' in the language list instead." % [path, locale])
		display_name = locale

	if _available.has(locale):
		push_warning("Localization: locale '%s' is defined by more than one file under %s — keeping the first one found, ignoring %s." % [locale, LOCALES_DIR, path])
		return

	var t := Translation.new()
	t.locale = locale
	for key in strings:
		var value = strings[key]
		if value is String:
			t.add_message(key, value)
			_known_keys[key] = true
		else:
			push_warning("Localization: %s key \"%s\" has a non-string value, skipping that key." % [path, key])
	TranslationServer.add_translation(t)
	_available[locale] = display_name

## Recursively resolves every Control's text/placeholder_text, every OptionButton
## item, and every TabContainer tab title under `root` against the CURRENT
## locale, for any value that is (or was originally) a known translation key.
## Call once per top-level scene in its own _ready() — after any runtime-built
## controls (e.g. SettingsMenu's dynamically-built tabs) already exist — and
## it's called again automatically on every live language switch (see
## SettingsManager.set_locale()), so displayed text never gets stuck in the
## locale that was active when a scene first loaded.
##
## The original key is cached via node metadata the first time a control is
## seen, so repeated calls — which happen on every locale switch — always
## re-resolve from the canonical key rather than trying (and failing) to look up
## already-resolved display text as if it were itself a key. Callers must supply
## the raw KEY as initial text/item text — never pre-resolve with tr() yourself,
## or that first-seen cache will capture the resolved string instead of the key
## and every locale switch after the first will silently no-op.
func retranslate_tree(root: Node):
	if root is Control:
		for prop in ["text", "placeholder_text"]:
			if prop in root:
				_retranslate_property(root, prop)
		if root is OptionButton:
			_retranslate_option_items(root)
		elif root is TabContainer:
			_retranslate_tab_titles(root)
	for child in root.get_children():
		retranslate_tree(child)

func _retranslate_property(control: Control, prop: String):
	var meta_key := "i18n_src_" + prop
	var key: String = control.get_meta(meta_key) if control.has_meta(meta_key) else control.get(prop)
	if _known_keys.has(key):
		control.set_meta(meta_key, key)
		control.set(prop, tr(key))

## OptionButton items aren't a Control.text property — they're entries in an
## internal list — so they need their own cache (one key per item index) and
## their own resolution pass. Items that were never translation keys to begin
## with (device names, per-locale display names in the language dropdown) are
## left untouched, same as a bus/device name is for _retranslate_property.
func _retranslate_option_items(option_button: OptionButton):
	const META_KEY := "i18n_item_keys"
	var keys: Array = option_button.get_meta(META_KEY, [])
	if keys.is_empty():
		for i in range(option_button.item_count):
			keys.append(option_button.get_item_text(i))
		option_button.set_meta(META_KEY, keys)
	for i in range(mini(keys.size(), option_button.item_count)):
		if _known_keys.has(keys[i]):
			option_button.set_item_text(i, tr(keys[i]))

func _retranslate_tab_titles(tabs: TabContainer):
	const META_KEY := "i18n_tab_keys"
	var keys: Array = tabs.get_meta(META_KEY, [])
	if keys.is_empty():
		for i in range(tabs.get_tab_count()):
			keys.append(tabs.get_tab_title(i))
		tabs.set_meta(META_KEY, keys)
	for i in range(mini(keys.size(), tabs.get_tab_count())):
		if _known_keys.has(keys[i]):
			tabs.set_tab_title(i, tr(keys[i]))
