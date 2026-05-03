# labs_system.gd
# Attach to a Control node (full rect anchors) in a new scene: labs_popup.tscn
# Add labs_popup.tscn as a child of ClinicalEncounter root node (visible = false by default).
# This script builds all UI programmatically — no manual node setup needed beyond the root Control.

extends Control

# ============================================================
# SIGNALS
# ============================================================
signal order_confirmed(results: Array, total_ap: int)
signal popup_closed

# ============================================================
# INJECTED DATA — set by clinical_engine before calling open()
# ============================================================
var master_labs_data: Dictionary = {}
var condition_labs_data: Dictionary = {}
var current_patient_state: String = "stable"
var elapsed_seconds: float = 0.0

# ============================================================
# INTERNAL STATE
# ============================================================
var all_labs: Array = []
var all_panels: Array = []
var lab_lookup: Dictionary = {}    # lab_id -> lab dict
var panel_lookup: Dictionary = {}  # panel_id -> panel dict

var selected_lab_ids: Dictionary = {}          # lab_id -> true
var ordered_panels_this_encounter: Dictionary = {}  # panel_id -> true (for repeat warning)
var encounter_results: Array = []              # all results ordered so far this encounter

var current_category_id: String = ""
var sort_mode: String = "time"
var confirm_mode: bool = false  # true when showing "Confirm / Cancel" row
var llm_searching: bool = false
var expanded_panels: Dictionary = {}  # panel_name -> bool
var name_section_expanded: Dictionary = {"panels": false, "labs": false}  # default collapsed
var order_counter: int = 0  # increments each time _execute_order() runs
var result_cache: Dictionary = {}  # key: "lab_id|state" -> cached result value
								   # cleared only on patient state change

# ============================================================
# UI REFERENCES
# ============================================================
var main_panel: PanelContainer
var tab_container: TabContainer

# Name search tab
var name_search_field: LineEdit
var name_results_list: VBoxContainer

# Description search tab
var desc_search_field: LineEdit
var desc_search_btn: Button
var desc_status_label: Label
var desc_results_list: VBoxContainer

# Category browser tab
var cat_list: VBoxContainer
var cat_labs_list: VBoxContainer
var cat_header_label: Label

# Selection section
var selected_label: Label
var selected_flow: HFlowContainer

# Bottom bar
var ap_cost_label: Label
var see_results_btn: Button
var order_btn: Button
var cancel_order_btn: Button
var repeat_warning_label: Label

# Results view
var results_view: PanelContainer
var results_list: VBoxContainer
var sort_name_btn: Button
var sort_time_btn: Button

# LLM request for description search
var http_request: HTTPRequest

# ============================================================
# COLORS & STYLE
# ============================================================
const C_BG        = Color(0.05, 0.05, 0.08, 0.96)
const C_PANEL     = Color(0.10, 0.12, 0.16)
const C_HEADER    = Color(0.13, 0.15, 0.21)
const C_ROW_ALT   = Color(0.12, 0.14, 0.18)
const C_SELECTED  = Color(0.15, 0.35, 0.60)
const C_CHIP      = Color(0.20, 0.45, 0.75)
const C_ABNORMAL  = Color(0.85, 0.25, 0.25)
const C_NORMAL    = Color(0.25, 0.70, 0.40)
const C_ACCENT    = Color(0.25, 0.55, 0.90)
const C_TEXT      = Color(0.90, 0.92, 0.95)
const C_DIM       = Color(0.55, 0.58, 0.65)
const C_WARN      = Color(0.90, 0.70, 0.20)
const C_CONFIRM   = Color(0.20, 0.65, 0.30)

# ============================================================
# ENTRY POINT
# ============================================================
# Called by clinical_engine whenever patient state changes (stable->perforated etc)
# or when a specific intervention warrants new lab values (e.g. blood transfusion)
func invalidate_result_cache() -> void:
	result_cache.clear()
	print("Lab result cache cleared — patient state or intervention changed")

func _center_panel() -> void:
	# Delegates to the shared PopupLayout helper so all popups (imaging, labs,
	# meds, etc.) use one source of truth for edge offsets. To adjust the size
	# or position of labs popups, edit popup_layout.gd, not here.
	PopupLayout.apply_layout(main_panel, "labs")

func open(master_labs: Dictionary, condition_labs: Dictionary,
		patient_state: String, elapsed: float, prior_results: Array) -> void:
	master_labs_data = master_labs
	condition_labs_data = condition_labs
	current_patient_state = patient_state
	elapsed_seconds = elapsed
	encounter_results = prior_results.duplicate(true)

	all_labs   = master_labs_data.get("labs", [])
	all_panels = master_labs_data.get("panels", [])

	# Build lookup dicts
	lab_lookup.clear()
	for lab in all_labs:
		lab_lookup[lab["id"]] = lab

	panel_lookup.clear()
	for panel in all_panels:
		panel_lookup[panel["id"]] = panel

	selected_lab_ids.clear()
	confirm_mode = false
	current_category_id = ""

	# Reset Search-by-Name section expand state so Panels and Labs both
	# start collapsed every time the popup is opened.
	name_section_expanded = {"panels": false, "labs": false}
	if name_search_field:
		name_search_field.text = ""  # Clear any leftover search text
	if desc_search_field:
		desc_search_field.text = ""  # Clear MEDDY's search text
	if desc_status_label:
		desc_status_label.text = ""  # Clear MEDDY's status message
	if desc_results_list:
		for c in desc_results_list.get_children():
			c.queue_free()  # Clear MEDDY's previous result rows

	_populate_categories()
	_refresh_name_results("")
	_refresh_selected_display()
	_refresh_results_view()

	if results_view:
		results_view.visible = false

	visible = true
	_center_panel()


# ============================================================
# _READY — build entire UI
# ============================================================
func _ready() -> void:
	# HTTP for description search
	http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(_on_desc_llm_response)

	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Main panel — sizing/positioning handled by PopupLayout (see popup_layout.gd).
	# We size the PanelContainer directly via position+size+custom_minimum_size
	# instead of using anchors, which don't reliably work under CanvasLayer parents.
	main_panel = PanelContainer.new()
	_style_panel(main_panel, C_PANEL)
	add_child(main_panel)
	_center_panel()

	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 6)
	main_panel.add_child(root_vbox)

	# --- Title bar ---
	var title_bar := _make_hbox(8)
	title_bar.custom_minimum_size.y = 38
	_bg_rect(title_bar, C_HEADER)
	var title_lbl := _make_label("🧪  Order Labs", 17)
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_bar.add_child(title_lbl)
	var close_btn := _make_btn("✕", 30)
	close_btn.pressed.connect(_on_close_pressed)
	title_bar.add_child(close_btn)
	root_vbox.add_child(title_bar)

	# --- Tab container ---
	tab_container = TabContainer.new()
	tab_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab_container.custom_minimum_size.y = 320
	root_vbox.add_child(tab_container)

	_build_name_search_tab()
	_build_category_tab()
	_build_desc_search_tab()

	# --- Selected section ---
	var sel_section := VBoxContainer.new()
	sel_section.custom_minimum_size.y = 90
	sel_section.add_theme_constant_override("separation", 4)
	root_vbox.add_child(sel_section)

	var sel_hdr := _make_hbox(8)
	_bg_rect(sel_hdr, C_HEADER)
	sel_hdr.custom_minimum_size.y = 26
	selected_label = _make_label("Selected: none", 13, C_DIM)
	selected_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sel_hdr.add_child(selected_label)
	var clear_btn := _make_btn("Clear All", 80)
	clear_btn.pressed.connect(_on_clear_all_pressed)
	sel_hdr.add_child(clear_btn)
	sel_section.add_child(sel_hdr)

	var sel_scroll := ScrollContainer.new()
	sel_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sel_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	sel_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sel_scroll.custom_minimum_size.y = 52
	sel_section.add_child(sel_scroll)

	selected_flow = HFlowContainer.new()
	selected_flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	selected_flow.add_theme_constant_override("h_separation", 6)
	selected_flow.add_theme_constant_override("v_separation", 4)
	sel_scroll.add_child(selected_flow)

	# --- Repeat warning ---
	repeat_warning_label = _make_label("", 12, C_WARN)
	repeat_warning_label.visible = false
	root_vbox.add_child(repeat_warning_label)

	# --- Bottom bar ---
	var bottom := _make_hbox(10)
	_bg_rect(bottom, C_HEADER)
	bottom.custom_minimum_size.y = 46

	see_results_btn = _make_btn("📋  See Results (0)", 160)
	see_results_btn.pressed.connect(_on_see_results_pressed)
	bottom.add_child(see_results_btn)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(spacer)

	ap_cost_label = _make_label("0 AP", 15, C_DIM)
	ap_cost_label.custom_minimum_size.x = 70
	ap_cost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bottom.add_child(ap_cost_label)

	cancel_order_btn = _make_btn("Cancel Order", 110)
	cancel_order_btn.visible = false
	cancel_order_btn.pressed.connect(_on_cancel_order_pressed)
	bottom.add_child(cancel_order_btn)

	order_btn = _make_btn("Order Selected  →", 150)
	order_btn.pressed.connect(_on_order_btn_pressed)
	bottom.add_child(order_btn)

	root_vbox.add_child(bottom)

	# --- Results overlay (hidden by default) ---
	_build_results_view()

	visible = false


# ============================================================
# TAB: NAME SEARCH
# ============================================================
func _make_results_col_header() -> Control:
	# Header structure must mirror _make_result_row exactly so columns align:
	#   [8px outer pad] [42px badge col] [8px sep] [Name (expand)] [8px sep]
	#   [260px panel col] [8px sep] [40px ap col, right-aligned] [8px sep]
	#   [70px sel col] [8px outer pad]
	var hdr := PanelContainer.new()
	hdr.custom_minimum_size.y = 24
	_bg_rect(hdr, Color(C_HEADER.r - 0.02, C_HEADER.g - 0.02, C_HEADER.b - 0.02))

	var inner := HBoxContainer.new()
	inner.add_theme_constant_override("separation", 8)
	hdr.add_child(inner)

	# Outer-left padding so labels sit where data row's labels sit.
	# Note: 2px (not 8px to match data row) because the PanelContainer wrapper
	# adds its own internal margin that we observed shifts the header right by
	# ~6px relative to the data rows. Empirically tuned.
	var lpad := Control.new()
	lpad.custom_minimum_size.x = 2
	inner.add_child(lpad)

	# Type badge column placeholder (42px to match type_lbl)
	var badge_pad := Control.new()
	badge_pad.custom_minimum_size.x = 42
	inner.add_child(badge_pad)

	# Lab Name — expands like the data row's name_lbl
	var name_hdr := _make_label("Lab Name", 11, C_DIM)
	name_hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_child(name_hdr)

	# Panel column (260px to match panel_lbl)
	var panel_hdr := _make_label("Returns Full Panel", 11, C_DIM)
	panel_hdr.custom_minimum_size.x = 260
	inner.add_child(panel_hdr)

	# AP Cost column — right-aligned, same 40px width as ap_lbl
	var ap_hdr := _make_label("AP Cost", 11, C_DIM)
	ap_hdr.custom_minimum_size.x = 40
	ap_hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	inner.add_child(ap_hdr)

	# Selection indicator spacer (70px to match sel_lbl)
	var sel_pad := Control.new()
	sel_pad.custom_minimum_size.x = 70
	inner.add_child(sel_pad)

	# Outer-right padding
	var rpad := Control.new()
	rpad.custom_minimum_size.x = 8
	inner.add_child(rpad)

	return hdr

func _build_name_search_tab() -> void:
	var tab := VBoxContainer.new()
	tab.name = "SearchByName"
	tab.add_theme_constant_override("separation", 6)
	tab_container.add_child(tab)
	tab_container.set_tab_title(tab_container.get_tab_count() - 1, "Search by Name")

	var search_row := _make_hbox(6)
	# Small leading spacer so the input's text aligns with the tab title text above it.
	var name_search_lpad := Control.new()
	name_search_lpad.custom_minimum_size.x = 9
	search_row.add_child(name_search_lpad)
	name_search_field = LineEdit.new()
	name_search_field.placeholder_text = "Type a lab name or abbreviation... (e.g. BMP, troponin, CBC)"
	name_search_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_search_field.text_changed.connect(_on_name_search_changed)
	search_row.add_child(name_search_field)
	tab.add_child(search_row)
	tab.add_child(_make_results_col_header())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab.add_child(scroll)

	name_results_list = VBoxContainer.new()
	name_results_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_results_list.add_theme_constant_override("separation", 2)
	scroll.add_child(name_results_list)


func _on_name_search_changed(text: String) -> void:
	_refresh_name_results(text)


func _refresh_name_results(query: String) -> void:
	for c in name_results_list.get_children():
		c.queue_free()

	var lower_q := query.to_lower().strip_edges()

	# --- Panels section ---
	var panel_matches: Array = []
	for panel in all_panels:
		if _panel_matches(panel, lower_q):
			panel_matches.append({"type": "panel", "data": panel})
	panel_matches.sort_custom(func(a, b): return a["data"]["name"] < b["data"]["name"])

	# --- Labs section ---
	var lab_matches: Array = []
	for lab in all_labs:
		if _lab_matches(lab, lower_q):
			lab_matches.append({"type": "lab", "data": lab})
	lab_matches.sort_custom(func(a, b): return a["data"]["name"] < b["data"]["name"])

	# --- Panels collapsible group ---
	var panels_expanded: bool = name_section_expanded.get("panels", lower_q != "")
	var panels_header := _make_section_header(
		"Panels (%d)" % panel_matches.size(), panels_expanded, "panels"
	)
	name_results_list.add_child(panels_header)

	if panels_expanded:
		var row_idx := 0
		for match_item in panel_matches:
			name_results_list.add_child(_make_result_row(match_item, row_idx))
			row_idx += 1

	# --- Labs collapsible group ---
	var labs_expanded: bool = name_section_expanded.get("labs", lower_q != "")
	var labs_header := _make_section_header(
		"Labs (%d)" % lab_matches.size(), labs_expanded, "labs"
	)
	name_results_list.add_child(labs_header)

	if labs_expanded:
		var row_idx := 0
		for match_item in lab_matches:
			name_results_list.add_child(_make_result_row(match_item, row_idx))
			row_idx += 1


func _panel_matches(panel: Dictionary, q: String) -> bool:
	if q == "":
		return true
	if q in panel.get("name", "").to_lower():
		return true
	for alias in panel.get("aliases", []):
		if q in alias.to_lower():
			return true
	return false


func _lab_matches(lab: Dictionary, q: String) -> bool:
	if q == "":
		return true
	if q in lab.get("name", "").to_lower():
		return true
	for alias in lab.get("aliases", []):
		if q in alias.to_lower():
			return true
	return false


# ============================================================
# TAB: DESCRIPTION SEARCH
# ============================================================
func _build_desc_search_tab() -> void:
	var tab := VBoxContainer.new()
	tab.name = "AskMeddy"
	tab.add_theme_constant_override("separation", 6)
	tab_container.add_child(tab)
	tab_container.set_tab_title(tab_container.get_tab_count() - 1, "Ask MEDDY! Describe what lab(s) you want to order")

	var search_row := _make_hbox(6)
	# Small leading spacer so the input's text aligns with the tab title text above it.
	var desc_search_lpad := Control.new()
	desc_search_lpad.custom_minimum_size.x = 9
	search_row.add_child(desc_search_lpad)
	desc_search_field = LineEdit.new()
	desc_search_field.placeholder_text = "Describe what you're looking for... (e.g. 'infection markers', 'check liver')"
	desc_search_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_search_field.text_submitted.connect(_on_desc_search_submitted)
	search_row.add_child(desc_search_field)
	desc_search_btn = _make_btn("Search", 80)
	desc_search_btn.pressed.connect(_on_desc_search_pressed)
	search_row.add_child(desc_search_btn)
	tab.add_child(search_row)

	desc_status_label = _make_label("", 12, C_DIM)
	# Wrap status label in an HBox with a leading spacer so its text aligns
	# under the search bar's text (and the tab title's "S") above.
	var status_row := HBoxContainer.new()
	status_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var status_lpad := Control.new()
	status_lpad.custom_minimum_size.x = 11
	status_row.add_child(status_lpad)
	desc_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_row.add_child(desc_status_label)
	tab.add_child(status_row)
	tab.add_child(_make_results_col_header())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab.add_child(scroll)

	desc_results_list = VBoxContainer.new()
	desc_results_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc_results_list.add_theme_constant_override("separation", 2)
	scroll.add_child(desc_results_list)


func _on_desc_search_submitted(_text: String) -> void:
	_on_desc_search_pressed()


func _on_desc_search_pressed() -> void:
	if llm_searching:
		return
	var query := desc_search_field.text.strip_edges()
	if query == "":
		return

	llm_searching = true
	desc_search_btn.text = "Searching..."
	desc_search_btn.disabled = true
	desc_status_label.text = "Asking MEDDY..."

	# Build compact lab list for LLM context (id + name + aliases)
	var lab_list_lines: PackedStringArray = []
	for panel in all_panels:
		var aliases: String = ", ".join(panel.get("aliases", []).slice(0, 4))
		lab_list_lines.append('PANEL|%s|%s|%s' % [panel["id"], panel["name"], aliases])
	for lab in all_labs:
		if lab.get("panel_memberships", []).is_empty():
			var aliases: String = ", ".join(lab.get("aliases", []).slice(0, 3))
			lab_list_lines.append('LAB|%s|%s|%s' % [lab["id"], lab["name"], aliases])

	var lab_context := "\n".join(lab_list_lines)

	var system_prompt := """You are a medical lab search assistant for a medical education game called MedRPG.
Given a player's search description, return a JSON array of matching lab/panel IDs.
Each entry in the list is: TYPE|id|name|aliases
Return ONLY a raw JSON array of IDs, no markdown, no explanation.
Example output: ["cbc","crp","procalcitonin"]
If nothing matches, return [].
Available labs and panels:
""" + lab_context

	var body := JSON.stringify({
		"prompt": "Player is searching for: " + query,
		"system": system_prompt,
		"max_tokens": 200
	})

	var headers := ["Content-Type: application/json"]
	http_request.request("http://localhost:3000/llm", headers, HTTPClient.METHOD_POST, body)


func _on_desc_llm_response(_result: int, _response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	llm_searching = false
	desc_search_btn.text = "Search"
	desc_search_btn.disabled = false

	for c in desc_results_list.get_children():
		c.queue_free()

	var response_text := body.get_string_from_utf8()
	var json := JSON.new()
	if json.parse(response_text) != OK:
		desc_status_label.text = "Parse error. Try again."
		return

	var data = json.get_data()
	if not (data is Dictionary) or not data.has("response"):
		desc_status_label.text = "Unexpected response. Try again."
		return

	var raw: String = data["response"].strip_edges()
	# Strip markdown fences if present
	raw = raw.replace("```json", "").replace("```", "").strip_edges()

	var id_json := JSON.new()
	if id_json.parse(raw) != OK:
		desc_status_label.text = "Could not parse lab list. Try rephrasing."
		return

	var ids = id_json.get_data()
	if not (ids is Array):
		desc_status_label.text = "No matches found."
		return

	desc_status_label.text = "%d result(s) found." % ids.size()

	var row_idx := 0
	for id_val in ids:
		var id_str: String = str(id_val)
		# Try panels first
		if panel_lookup.has(id_str):
			var row := _make_result_row({"type": "panel", "data": panel_lookup[id_str]}, row_idx)
			desc_results_list.add_child(row)
			row_idx += 1
		elif lab_lookup.has(id_str):
			var row := _make_result_row({"type": "lab", "data": lab_lookup[id_str]}, row_idx)
			desc_results_list.add_child(row)
			row_idx += 1


# ============================================================
# TAB: CATEGORY BROWSER
# ============================================================
func _build_category_tab() -> void:
	var tab := HBoxContainer.new()
	tab.name = "BrowseCategories"
	tab.add_theme_constant_override("separation", 0)
	tab_container.add_child(tab)
	tab_container.set_tab_title(tab_container.get_tab_count() - 1, "Browse Categories")

	# Left: category list
	var cat_scroll := ScrollContainer.new()
	cat_scroll.custom_minimum_size.x = 220
	cat_scroll.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	tab.add_child(cat_scroll)

	cat_list = VBoxContainer.new()
	cat_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cat_list.add_theme_constant_override("separation", 2)
	cat_scroll.add_child(cat_list)

	# Divider
	var div := ColorRect.new()
	div.custom_minimum_size.x = 2
	div.color = C_HEADER
	div.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab.add_child(div)

	# Right: labs in selected category
	var right_vbox := VBoxContainer.new()
	right_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_vbox.add_theme_constant_override("separation", 4)
	tab.add_child(right_vbox)

	cat_header_label = _make_label("Select a category →", 13, C_DIM)
	right_vbox.add_child(cat_header_label)
	right_vbox.add_child(_make_results_col_header())

	var labs_scroll := ScrollContainer.new()
	labs_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_vbox.add_child(labs_scroll)

	cat_labs_list = VBoxContainer.new()
	cat_labs_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cat_labs_list.add_theme_constant_override("separation", 2)
	labs_scroll.add_child(cat_labs_list)


func _populate_categories() -> void:
	for c in cat_list.get_children():
		c.queue_free()

	var categories: Array = master_labs_data.get("ui_categories", [])
	for i in categories.size():
		var cat: Dictionary = categories[i]
		var btn := Button.new()
		btn.text = cat["name"]
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.toggle_mode = true
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# Add left padding so text aligns with content on the right panel
		var style := StyleBoxFlat.new()
		style.bg_color = C_ROW_ALT if i % 2 == 0 else C_PANEL
		style.set_corner_radius_all(3)
		style.content_margin_left = 10
		btn.add_theme_stylebox_override("normal", style)
		var hover_style := StyleBoxFlat.new()
		hover_style.bg_color = Color(style.bg_color.r + 0.08, style.bg_color.g + 0.08, style.bg_color.b + 0.10)
		hover_style.set_corner_radius_all(3)
		hover_style.content_margin_left = 10
		btn.add_theme_stylebox_override("hover", hover_style)
		btn.pressed.connect(_on_category_selected.bind(cat["id"], btn))
		cat_list.add_child(btn)


func _on_category_selected(cat_id: String, btn: Button) -> void:
	current_category_id = cat_id

	# Deselect other category buttons visually
	for c in cat_list.get_children():
		if c is Button:
			c.button_pressed = (c == btn)

	# Find category name
	for cat in master_labs_data.get("ui_categories", []):
		if cat["id"] == cat_id:
			cat_header_label.text = cat["name"]
			break

	# Populate right panel with labs + panels in this category
	for c in cat_labs_list.get_children():
		c.queue_free()

	var row_idx := 0

	# Panels in this category
	for panel in all_panels:
		var cats: Array = panel.get("ui_categories", [])
		if cat_id in cats:
			var row := _make_result_row({"type": "panel", "data": panel}, row_idx)
			cat_labs_list.add_child(row)
			row_idx += 1

	# Standalone labs in this category
	for lab in all_labs:
		if lab.get("panel_memberships", []).is_empty():
			var cats: Array = lab.get("ui_categories", [])
			if cat_id in cats:
				var row := _make_result_row({"type": "lab", "data": lab}, row_idx)
				cat_labs_list.add_child(row)
				row_idx += 1


# ============================================================
# RESULT ROW — shared across all three tabs
# ============================================================
func _make_section_header(label_text: String, is_expanded: bool, section_key: String) -> Button:
	var btn := Button.new()
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.custom_minimum_size.y = 34
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_style_btn_bg(btn, C_HEADER)
	# Nudge text 2 pixels right of the panel's left edge so the arrow and
	# section name don't sit flush against the panel's left margin.
	_set_btn_left_padding(btn, 2)
	var icon := "▼ " if is_expanded else "▶ "
	btn.text = icon + label_text
	var captured_key := section_key
	btn.pressed.connect(func():
		name_section_expanded[captured_key] = not name_section_expanded.get(captured_key, false)
		_refresh_name_results(name_search_field.text if name_search_field else "")
	)
	return btn

func _make_result_row(match_item: Dictionary, row_idx: int) -> Button:
	var is_panel: bool = match_item["type"] == "panel"
	var data: Dictionary = match_item["data"]
	var item_id: String = data["id"]

	var is_selected: bool = selected_lab_ids.has(item_id)
	var bg_color := C_SELECTED if is_selected else (C_ROW_ALT if row_idx % 2 == 0 else C_PANEL)

	# Outer Button — gives us native hover styling for free (same as category buttons)
	var row := Button.new()
	row.custom_minimum_size.y = 32
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.focus_mode = Control.FOCUS_NONE
	_style_btn_bg(row, bg_color)
	# Clicking anywhere on the row also toggles selection
	row.pressed.connect(_on_result_row_toggle.bind(item_id, is_panel))

	# Inner HBoxContainer holds all visible content
	var inner := HBoxContainer.new()
	inner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	inner.offset_left = 8
	inner.offset_right = -8
	inner.add_theme_constant_override("separation", 8)
	inner.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(inner)

	# Type badge
	var type_lbl := _make_label("PANEL" if is_panel else "LAB", 10,
			Color(0.9, 0.75, 0.3) if is_panel else Color(0.5, 0.8, 0.9))
	type_lbl.custom_minimum_size.x = 42
	inner.add_child(type_lbl)

	# Name
	var name_lbl := _make_label(data.get("name", item_id), 13)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_child(name_lbl)

	# Column order: Panel (260px) → AP Cost (40px)
	var panel_cell_text := ""
	var ap_cost_text := ""

	if is_panel:
		# Panel row: AP cost from its own data, Panel column blank
		ap_cost_text = str(int(data.get("ap_cost", 1))) + " AP"
	else:
		# Individual lab: search all_panels directly for cheapest covering panel
		var memberships: Array = data.get("panel_memberships", [])
		print("DEBUG row: ", data.get("name","?"), " | memberships: ", memberships, " | all_panels.size: ", all_panels.size())
		var best_cost := 999
		for p in all_panels:
			if p["id"] in memberships:
				var c: int = p.get("ap_cost", 1)
				if c < best_cost:
					best_cost = c
					panel_cell_text = p.get("name", "")
					ap_cost_text = str(c) + " AP"
		if ap_cost_text == "":
			ap_cost_text = "1 AP"

	# Panel cell — always present to hold column alignment
	var panel_lbl := _make_label(panel_cell_text, 10, C_DIM)
	panel_lbl.custom_minimum_size.x = 260
	panel_lbl.clip_text = true
	inner.add_child(panel_lbl)

	# AP Cost cell
	var ap_lbl := _make_label(ap_cost_text, 12, C_ACCENT)
	ap_lbl.custom_minimum_size.x = 40
	ap_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	inner.add_child(ap_lbl)

	# Selected indicator label (right side) — non-interactive, just visual
	var sel_lbl := _make_label("✓ Added" if is_selected else "+ Add", 12,
			C_CHIP if is_selected else C_DIM)
	sel_lbl.custom_minimum_size.x = 70
	sel_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	sel_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(sel_lbl)

	return row


func _on_result_row_toggle(item_id: String, _is_panel: bool) -> void:
	if selected_lab_ids.has(item_id):
		selected_lab_ids.erase(item_id)
	else:
		# If it's a panel id, add directly
		# If it's a lab id, add directly
		selected_lab_ids[item_id] = true

	_refresh_name_results(name_search_field.text if name_search_field else "")
	_refresh_selected_display()
	_refresh_ap_cost()
	_refresh_repeat_warning()
	_reset_confirm_mode()


# ============================================================
# SELECTED DISPLAY
# ============================================================
func _refresh_selected_display() -> void:
	for c in selected_flow.get_children():
		c.queue_free()

	if selected_lab_ids.is_empty():
		selected_label.text = "Selected: none"
		order_btn.disabled = true
		ap_cost_label.text = "0 AP"
		ap_cost_label.add_theme_color_override("font_color", C_DIM)
		return

	var count := selected_lab_ids.size()
	selected_label.text = "Selected: %d item(s)" % count
	order_btn.disabled = false

	for item_id in selected_lab_ids:
		var chip := _make_chip(item_id)
		selected_flow.add_child(chip)


func _make_chip(item_id: String) -> HBoxContainer:
	var chip := HBoxContainer.new()
	chip.add_theme_constant_override("separation", 4)
	_bg_rect(chip, C_CHIP)

	# Resolve display name
	var display_name := item_id
	if panel_lookup.has(item_id):
		display_name = panel_lookup[item_id]["name"]
		# Add AP cost
		var ap: int = panel_lookup[item_id].get("ap_cost", 1)
		display_name += " (%d AP)" % ap
	elif lab_lookup.has(item_id):
		display_name = lab_lookup[item_id]["name"]
		# Show which panel it triggers
		var memberships: Array = lab_lookup[item_id].get("panel_memberships", [])
		if not memberships.is_empty():
			var cheapest_panel = _get_cheapest_panel(memberships)
			if cheapest_panel:
				display_name += " → %s (1 AP)" % cheapest_panel["name"]
			else:
				display_name += " (1 AP)"
		else:
			display_name += " (1 AP)"

	var lbl := _make_label(display_name, 11)
	chip.add_child(lbl)

	var remove_btn := _make_btn("×", 20)
	remove_btn.pressed.connect(_on_chip_remove.bind(item_id))
	chip.add_child(remove_btn)

	return chip


func _on_chip_remove(item_id: String) -> void:
	selected_lab_ids.erase(item_id)
	_refresh_selected_display()
	_refresh_ap_cost()
	_refresh_repeat_warning()
	_reset_confirm_mode()
	# Refresh current tab results
	_refresh_name_results(name_search_field.text if name_search_field else "")


func _on_clear_all_pressed() -> void:
	selected_lab_ids.clear()
	_refresh_name_results(name_search_field.text if name_search_field else "")
	_refresh_selected_display()
	_refresh_ap_cost()
	repeat_warning_label.visible = false
	_reset_confirm_mode()


# ============================================================
# AP COST CALCULATION
# ============================================================
func _refresh_ap_cost() -> void:
	var panels_to_charge := _resolve_panels_for_selected()
	var total_ap := 0
	for panel_id in panels_to_charge:
		if panel_lookup.has(panel_id):
			total_ap += panel_lookup[panel_id].get("ap_cost", 1)
		else:
			total_ap += 1  # standalone

	if total_ap == 0:
		ap_cost_label.text = "0 AP"
		ap_cost_label.add_theme_color_override("font_color", C_DIM)
	else:
		ap_cost_label.text = "%d AP" % total_ap
		ap_cost_label.add_theme_color_override("font_color", C_ACCENT)


func _resolve_panels_for_selected() -> Array:
	# Returns array of panel_ids (or "standalone_LABID") to charge.
	# Groups individual labs into cheapest covering panel.
	var panels_to_charge: Dictionary = {}  # panel_id -> true

	for item_id in selected_lab_ids:
		if panel_lookup.has(item_id):
			# Directly selected a panel
			panels_to_charge[item_id] = true
		elif lab_lookup.has(item_id):
			# Individual lab — find cheapest covering panel
			var lab: Dictionary = lab_lookup[item_id]
			var memberships: Array = lab.get("panel_memberships", [])

			if memberships.is_empty():
				# Standalone lab
				panels_to_charge["_standalone_" + item_id] = true
			else:
				# Check if already covered by a selected panel
				var already_covered := false
				for pid in panels_to_charge:
					if pid.begins_with("_standalone_"):
						continue
					if panel_lookup.has(pid):
						var comps: Array = panel_lookup[pid].get("component_lab_ids", [])
						if item_id in comps:
							already_covered = true
							break
				if not already_covered:
					var cheapest = _get_cheapest_panel(memberships)
					if cheapest:
						panels_to_charge[cheapest["id"]] = true
					else:
						panels_to_charge["_standalone_" + item_id] = true

	return panels_to_charge.keys()


func _get_cheapest_panel(panel_ids: Array):
	var best = null
	var best_cost := 999
	for pid in panel_ids:
		if panel_lookup.has(pid):
			var cost: int = panel_lookup[pid].get("ap_cost", 1)
			if cost < best_cost:
				best_cost = cost
				best = panel_lookup[pid]
	return best


func _get_total_ap() -> int:
	var panels := _resolve_panels_for_selected()
	var total := 0
	for pid in panels:
		if panel_lookup.has(pid):
			total += panel_lookup[pid].get("ap_cost", 1)
		else:
			total += 1
	return total


# ============================================================
# REPEAT WARNING
# ============================================================
func _refresh_repeat_warning() -> void:
	var repeats: Array = []
	var panels := _resolve_panels_for_selected()
	for pid in panels:
		if ordered_panels_this_encounter.has(pid):
			var pname: String = str(panel_lookup[pid]["name"]) if panel_lookup.has(pid) else str(pid)
			repeats.append(pname)

	if repeats.is_empty():
		repeat_warning_label.visible = false
	else:
		repeat_warning_label.text = "⚠  Already ordered this encounter: " + ", ".join(repeats) + "  — can re-order for updated results."
		repeat_warning_label.visible = true


# ============================================================
# ORDER FLOW
# ============================================================
func _on_order_btn_pressed() -> void:
	if selected_lab_ids.is_empty():
		return

	if not confirm_mode:
		# Switch to confirm mode
		confirm_mode = true
		var total := _get_total_ap()
		order_btn.text = "✓  Confirm Order (%d AP)" % total
		_style_btn_bg(order_btn, C_CONFIRM)
		cancel_order_btn.visible = true
	else:
		_execute_order()


func _on_cancel_order_pressed() -> void:
	_reset_confirm_mode()


func _reset_confirm_mode() -> void:
	confirm_mode = false
	order_btn.text = "Order Selected  →"
	_style_btn_bg(order_btn, Color(0.18, 0.20, 0.28))
	cancel_order_btn.visible = false


func _execute_order() -> void:
	var panels_to_charge := _resolve_panels_for_selected()
	var total_ap := _get_total_ap()

	# Increment order counter — unique ID for this batch of results
	order_counter += 1
	var this_order_index := order_counter
	# Snapshot elapsed time from engine if available, else use stored value
	var this_elapsed := elapsed_seconds
	var engine = get_node_or_null("/root/ClinicalEncounter")
	if engine and engine.has_method("_get_state_name"):
		this_elapsed = engine.elapsed_seconds

	# Generate results
	var new_results: Array = []

	for pid in panels_to_charge:
		var lab_ids_to_return: Array = []

		if pid.begins_with("_standalone_"):
			var lab_id: String = pid.substr(12)
			lab_ids_to_return = [lab_id]
		elif panel_lookup.has(pid):
			lab_ids_to_return = panel_lookup[pid].get("component_lab_ids", [])
			# Special case: bilirubin panel also triggers liver panel labs
			if pid == "bilirubin_panel":
				for liver_lab in panel_lookup.get("liver_panel", {}).get("component_lab_ids", []):
					if not liver_lab in lab_ids_to_return:
						lab_ids_to_return.append(liver_lab)

		for lab_id in lab_ids_to_return:
			var result = _generate_single_result(lab_id, pid)
			if result:
				result["timestamp_seconds"] = this_elapsed
				result["order_index"] = this_order_index
				new_results.append(result)

		# Mark as ordered
		if not pid.begins_with("_standalone_"):
			ordered_panels_this_encounter[pid] = true

	# Add to encounter results
	encounter_results.append_array(new_results)

	# Emit to clinical_engine
	order_confirmed.emit(new_results, total_ap)

	# Reset selection
	selected_lab_ids.clear()
	_refresh_selected_display()
	_refresh_ap_cost()
	repeat_warning_label.visible = false
	_reset_confirm_mode()

	# Show results immediately
	_refresh_results_view()
	_show_results_view()

	see_results_btn.text = "📋  See Results (%d)" % encounter_results.size()


# ============================================================
# RESULT GENERATION
# ============================================================
func _generate_single_result(lab_id: String, panel_id: String):
	if not lab_lookup.has(lab_id):
		return null

	var lab: Dictionary = lab_lookup[lab_id]
	var display_type: String = lab.get("display_type", "numeric")

	# Get result range: condition_labs first, then master_labs adult
	var condition_ranges: Dictionary = condition_labs_data.get("result_ranges", {})
	var master_ranges: Dictionary = lab.get("reference_ranges", {})
	var adult_ref: Dictionary = master_ranges.get("adult", {})

	var result_range: Dictionary = {}
	if condition_ranges.has(lab_id) and condition_ranges[lab_id].has(current_patient_state):
		result_range = condition_ranges[lab_id][current_patient_state]
	else:
		result_range = adult_ref

	# Check cache — same lab in same patient state always returns same value
	var cache_key := lab_id + "|" + current_patient_state
	var value = null
	if result_cache.has(cache_key):
		value = result_cache[cache_key]
		# Reconstruct display_type from cached value type
		if value is String:
			display_type = "qualitative"
	else:
		# Generate value fresh and cache it
		if display_type == "qualitative" or result_range.has("qualitative"):
			value = result_range.get("qualitative", adult_ref.get("qualitative", "—"))
			display_type = "qualitative"
		else:
			var mn := float(result_range.get("min", 0.0))
			var mx := float(result_range.get("max", 0.0))
			if mx <= mn:
				value = mn
			else:
				value = randf_range(mn, mx)
			# Round to display_decimals
			var decimals: int = lab.get("display_decimals", 1)
			var factor := pow(10.0, decimals)
			value = round(float(value) * factor) / factor
		result_cache[cache_key] = value

	# Determine abnormal vs adult ref range
	var is_abnormal := false
	if display_type == "qualitative":
		var expected_qual: String = adult_ref.get("qualitative", "")
		if expected_qual != "" and str(value) != expected_qual:
			is_abnormal = true
	else:
		var ref_min := float(adult_ref.get("min", -INF))
		var ref_max := float(adult_ref.get("max", INF))
		is_abnormal = float(value) < ref_min or float(value) > ref_max

	# Build ref range display string
	var ref_str := ""
	if display_type == "qualitative":
		ref_str = adult_ref.get("qualitative", "")
	else:
		var rmin = adult_ref.get("min", null)
		var rmax = adult_ref.get("max", null)
		if rmin != null and rmax != null:
			ref_str = "%s – %s" % [str(rmin), str(rmax)]

	# Panel name
	var panel_name := ""
	if panel_id.begins_with("_standalone_"):
		panel_name = "Standalone"
	elif panel_lookup.has(panel_id):
		panel_name = panel_lookup[panel_id]["name"]

	return {
		"lab_id":        lab_id,
		"lab_name":      lab.get("name", lab_id),
		"value":         value,
		"unit":          lab.get("unit", ""),
		"ref_range_str": ref_str,
		"ref_min":       adult_ref.get("min", null),
		"ref_max":       adult_ref.get("max", null),
		"is_abnormal":   is_abnormal,
		"display_type":  display_type,
		"display_decimals": lab.get("display_decimals", 1),
		"panel_id":      panel_id,
		"panel_name":    panel_name,
		"timestamp_seconds": 0.0,  # set by caller
	}


# ============================================================
# RESULTS VIEW
# ============================================================
func _build_results_view() -> void:
	results_view = PanelContainer.new()
	results_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	results_view.anchor_right = 1.0
	results_view.anchor_bottom = 1.0
	results_view.offset_left = 0
	results_view.offset_top = 0
	results_view.offset_right = 0
	results_view.offset_bottom = 0
	results_view.visible = false
	_style_panel(results_view, C_PANEL)
	main_panel.add_child(results_view)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	results_view.add_child(vbox)

	# Header
	var hdr := _make_hbox(8)
	_bg_rect(hdr, C_HEADER)
	hdr.custom_minimum_size.y = 42

	var title := _make_label("📋  Lab Results — This Encounter", 16)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_child(title)

	sort_name_btn = _make_btn("Sort: A-Z", 90)
	sort_name_btn.pressed.connect(_on_sort_name.bind())
	hdr.add_child(sort_name_btn)

	sort_time_btn = _make_btn("Sort: Newest", 100)
	sort_time_btn.pressed.connect(_on_sort_time.bind())
	sort_time_btn.disabled = true  # default sort is time
	hdr.add_child(sort_time_btn)

	var back_btn := _make_btn("← Back to Order", 130)
	back_btn.pressed.connect(_on_back_from_results)
	hdr.add_child(back_btn)

	var close_r := _make_btn("✕", 30)
	close_r.pressed.connect(_on_close_pressed)
	hdr.add_child(close_r)

	vbox.add_child(hdr)

	# Column headers (shown inside expanded panels)
	var col_hdr := _make_hbox(0)
	col_hdr.custom_minimum_size.y = 22
	_bg_rect(col_hdr, C_HEADER)
	col_hdr.add_child(_make_col_header("", 28))
	col_hdr.add_child(_make_col_header("Lab", 280))
	col_hdr.add_child(_make_col_header("Result", 160))
	col_hdr.add_child(_make_col_header("Reference Range", 180))
	vbox.add_child(col_hdr)

	# Scrollable results
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	results_list = VBoxContainer.new()
	results_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	results_list.add_theme_constant_override("separation", 1)
	scroll.add_child(results_list)


func _make_col_header(text: String, min_w: int) -> Label:
	var l := _make_label(text, 11, C_DIM)
	l.custom_minimum_size.x = min_w
	return l


func _refresh_results_view() -> void:
	if not results_list:
		return
	for c in results_list.get_children():
		c.queue_free()

	if encounter_results.is_empty():
		results_list.add_child(_make_label("No labs ordered yet.", 14, C_DIM))
		return

	# --- Build structure ---
	# panel_name -> Array of orders, each order = Array of result dicts (same timestamp)
	var panel_order: Array = []              # ordered list of panel names seen
	var panel_instances: Dictionary = {}     # panel_name -> Array of {timestamp, results[], abnormal_count}

	for r in encounter_results:
		var pname: String = r.get("panel_name", "Standalone")
		var ts: float = float(r.get("timestamp_seconds", 0.0))
		var oidx: int = r.get("order_index", 0)

		if not panel_instances.has(pname):
			panel_instances[pname] = []
			panel_order.append(pname)

		# Find existing instance by order_index (unique per _execute_order call)
		var matched := false
		for inst in panel_instances[pname]:
			if inst["order_index"] == oidx:
				inst["results"].append(r)
				if r.get("is_abnormal", false):
					inst["abnormal_count"] += 1
				matched = true
				break
		if not matched:
			panel_instances[pname].append({
				"order_index": oidx,
				"timestamp": ts,
				"results": [r],
				"abnormal_count": 1 if r.get("is_abnormal", false) else 0
			})

	# Sort panel list
	if sort_mode == "name":
		panel_order.sort()
	else:
		panel_order.sort_custom(func(a, b):
			var latest_a: float = 0.0
			for inst in panel_instances[a]:
				if float(inst["timestamp"]) > latest_a:
					latest_a = float(inst["timestamp"])
			var latest_b: float = 0.0
			for inst in panel_instances[b]:
				if float(inst["timestamp"]) > latest_b:
					latest_b = float(inst["timestamp"])
			return latest_a > latest_b
		)

	for pname in panel_order:
		results_list.add_child(_make_panel_top(pname, panel_instances[pname]))


# Top-level: panel name row — expands to show individual order instances
func _make_panel_top(pname: String, instances: Array) -> VBoxContainer:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 1)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var total_results := 0
	var total_abnormal := 0
	var latest_ts: float = 0.0
	for inst in instances:
		total_results += inst["results"].size()
		total_abnormal += inst["abnormal_count"]
		if float(inst["timestamp"]) > latest_ts:
			latest_ts = float(inst["timestamp"])

	var is_expanded: bool = expanded_panels.get(pname, false)
	var icon := "\u25bc " if is_expanded else "\u25b6 "
	var abn_str := "   \ud83d\udd34 %d abnormal" % total_abnormal if total_abnormal > 0 else ""
	var order_word := "order" if instances.size() == 1 else "orders"

	var header := Button.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.custom_minimum_size.y = 38
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_style_btn_bg(header, C_HEADER)
	header.text = "%s%s   (%d %s%s)" % [icon, pname, instances.size(), order_word, abn_str]
	vbox.add_child(header)

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 1)
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.visible = is_expanded
	vbox.add_child(inner)

	for i in instances.size():
		var inst_key := pname + "|" + str(i)
		inner.add_child(_make_panel_instance(pname, i + 1, instances[i], inst_key))

	var captured_pname := pname
	header.pressed.connect(func():
		expanded_panels[captured_pname] = not expanded_panels.get(captured_pname, false)
		_refresh_results_view()
	)
	return vbox


# Second-level: a single ordered instance — expands to show individual lab rows
func _make_panel_instance(pname: String, order_num: int, inst: Dictionary, inst_key: String) -> VBoxContainer:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 0)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var results: Array = inst["results"]
	var abnormal_count: int = inst["abnormal_count"]
	var ts: float = float(inst["timestamp"])
	var is_expanded: bool = expanded_panels.get(inst_key, false)

	var icon := "  \u25bc " if is_expanded else "  \u25b6 "
	var label_text := ""
	if order_num == 1 and true:
		# Check if there's only one instance total — no numbering needed
		pass
	var abn_str := "  \ud83d\udd34 %d abnormal" % abnormal_count if abnormal_count > 0 else ""
	label_text = "%s%s #%d   \u2014   %s%s" % [icon, pname, order_num, _format_timestamp(ts), abn_str]

	var header := Button.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.custom_minimum_size.y = 32
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_style_btn_bg(header, Color(C_HEADER.r - 0.02, C_HEADER.g - 0.02, C_HEADER.b - 0.02))
	header.text = label_text
	vbox.add_child(header)

	var labs_vbox := VBoxContainer.new()
	labs_vbox.add_theme_constant_override("separation", 0)
	labs_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	labs_vbox.visible = is_expanded
	vbox.add_child(labs_vbox)

	# Column headers inside expanded instance
	var col_hdr := _make_hbox(0)
	col_hdr.custom_minimum_size.y = 22
	_bg_rect(col_hdr, Color(C_HEADER.r - 0.03, C_HEADER.g - 0.03, C_HEADER.b - 0.03))
	var spacer := Control.new()
	spacer.custom_minimum_size.x = 36
	col_hdr.add_child(spacer)
	var name_hdr := _make_label("Lab Name", 10, C_DIM)
	name_hdr.custom_minimum_size.x = 280
	col_hdr.add_child(name_hdr)
	var result_hdr := _make_label("Result", 10, C_DIM)
	result_hdr.custom_minimum_size.x = 160
	col_hdr.add_child(result_hdr)
	var ref_hdr := _make_label("Reference Range", 10, C_DIM)
	ref_hdr.custom_minimum_size.x = 180
	col_hdr.add_child(ref_hdr)
	labs_vbox.add_child(col_hdr)

	for i in results.size():
		labs_vbox.add_child(_make_result_display_row(results[i], i))

	var captured_key := inst_key
	header.pressed.connect(func():
		expanded_panels[captured_key] = not expanded_panels.get(captured_key, false)
		_refresh_results_view()
	)
	return vbox


func _make_result_display_row(r: Dictionary, row_idx: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.custom_minimum_size.y = 26
	row.add_theme_constant_override("separation", 0)
	_bg_rect(row, C_ROW_ALT if row_idx % 2 == 0 else C_PANEL)

	var is_abn: bool = r.get("is_abnormal", false)

	var flag_lbl := _make_label("\ud83d\udd34" if is_abn else "  ", 11, C_ABNORMAL if is_abn else C_NORMAL)
	flag_lbl.custom_minimum_size.x = 36
	row.add_child(flag_lbl)

	var name_lbl := _make_label(r.get("lab_name", ""), 12)
	name_lbl.custom_minimum_size.x = 280
	row.add_child(name_lbl)

	var val_str := ""
	if r.get("display_type", "numeric") == "qualitative":
		val_str = str(r.get("value", "\u2014"))
	else:
		var decimals: int = r.get("display_decimals", 1)
		val_str = ("%." + str(decimals) + "f") % float(r.get("value", 0.0))
	var unit_str: String = r.get("unit", "")
	if unit_str != "":
		val_str += "  " + unit_str
	var val_lbl := _make_label(val_str, 12, C_ABNORMAL if is_abn else C_TEXT)
	val_lbl.custom_minimum_size.x = 160
	row.add_child(val_lbl)

	var ref_lbl := _make_label(r.get("ref_range_str", ""), 11, C_DIM)
	ref_lbl.custom_minimum_size.x = 180
	row.add_child(ref_lbl)

	return row


func _format_timestamp(seconds: float) -> String:
	var total_s := int(seconds)
	var mins := total_s / 60
	var secs := total_s % 60
	return "%d:%02d into case" % [mins, secs]


func _on_sort_name() -> void:
	sort_mode = "name"
	sort_name_btn.disabled = true
	sort_time_btn.disabled = false
	_refresh_results_view()


func _on_sort_time() -> void:
	sort_mode = "time"
	sort_time_btn.disabled = true
	sort_name_btn.disabled = false
	_refresh_results_view()


func _show_results_view() -> void:
	_refresh_results_view()
	results_view.visible = true


func _on_back_from_results() -> void:
	results_view.visible = false


func _on_see_results_pressed() -> void:
	_show_results_view()


# ============================================================
# CLOSE
# ============================================================
func _on_close_pressed() -> void:
	visible = false
	popup_closed.emit()


# ============================================================
# INPUT — Escape key to close
# ============================================================
func _unhandled_input(event: InputEvent) -> void:
	if visible and event is InputEventKey:
		if event.pressed and event.keycode == KEY_ESCAPE:
			if results_view and results_view.visible:
				results_view.visible = false
			else:
				_on_close_pressed()
			get_viewport().set_input_as_handled()


# ============================================================
# UI HELPER BUILDERS
# ============================================================
func _make_label(text: String, font_size: int = 13, color: Color = C_TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.clip_text = true
	return l


func _make_hbox(sep: int = 8) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return h


func _make_btn(text: String, min_w: int = 80) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size.x = min_w
	return b


func _bg_rect(parent: Control, color: Color) -> void:
	# Sets a colored background on a container via a child ColorRect behind everything
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(3)
	if parent is PanelContainer:
		parent.add_theme_stylebox_override("panel", style)
	elif parent is Button:
		parent.add_theme_stylebox_override("normal", style)
	else:
		# Use a child ColorRect that fills the parent
		parent.ready.connect(func():
			var cr := ColorRect.new()
			cr.color = color
			cr.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			cr.z_index = -1
			parent.add_child(cr)
			parent.move_child(cr, 0)
		, CONNECT_ONE_SHOT)


func _style_panel(panel: Control, color: Color) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", style)


func _style_btn_bg(btn: Button, color: Color) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(3)
	btn.add_theme_stylebox_override("normal", style)
	var hover := StyleBoxFlat.new()
	hover.bg_color = Color(color.r + 0.08, color.g + 0.08, color.b + 0.08)
	hover.set_corner_radius_all(3)
	btn.add_theme_stylebox_override("hover", hover)


# Adds a left content margin to a button's existing styleboxes so the text is
# nudged right by `pixels`. Applied to both "normal" and "hover" so the text
# doesn't shift when the cursor enters/leaves the button.
func _set_btn_left_padding(btn: Button, pixels: int) -> void:
	for state in ["normal", "hover"]:
		var sb: StyleBox = btn.get_theme_stylebox(state)
		if sb is StyleBoxFlat:
			sb.content_margin_left = float(pixels)
