# medications_system.gd
# Attach to a Control node (full rect anchors) in medications_popup.tscn.
# Add medications_popup.tscn as a child of clinical_encounter.tscn's PopupLayer node
# (visible = false by default).
#
# Mirrors labs_system.gd / imaging_system.gd architecture:
#   - Three tabs: Search by Name, Browse Categories, Ask MEDDY
#   - Medication picker → optional allergy warning → route picker → AP confirm
#   - Single-medication-at-a-time (NOT a multi-cart like labs/imaging)
#
# v1 scope notes (see PROJECT_NOTES.md "Medications system" section):
#   - Anaphylaxis state DEFERRED — we set anaphylaxis_triggered flag and emit signal,
#     engine handles state transition when that ships
#   - IV Stage F extravasation roll DEFERRED — peripheral_extravasation_risk field read
#     but not enforced
#   - IO and central line procedures DEFERRED — vascular_access_points input is the
#     forward-compatible point of extension

extends Control

# ============================================================
# SIGNALS
# ============================================================
signal medication_ordered(canonical_id: String, route: String, ap_spent: int)
signal allergy_warning_shown(canonical_id: String, allergy_class: String)
signal anaphylaxis_triggered_signal(canonical_id: String)
signal popup_closed

# ============================================================
# INJECTED DATA — set by clinical_engine before calling open()
# ============================================================
var medications_catalog: Array = []        # full master_medications.json medications array
var patient_allergies: Array = []          # e.g. ["nsaids"]
var medications_given: Array = []          # log of what's been ordered this encounter (informational)
var vascular_access_points: Array = []     # array of dicts: {site_id: "left_ac", display_name: "Left AC"}
var available_ap: int = 0
var meddy_filter_system_prompt: String = ""  # injected from appendicitis_system_prompts.json

# ============================================================
# INTERNAL STATE
# ============================================================
var current_tab: int = 0   # 0=Search, 1=Browse, 2=MEDDY
var current_category_id: String = ""
var meddy_searching: bool = false
var meddy_filtered_ids: Array = []   # canonical_ids from last MEDDY call

# Modal state machine
var pending_med: Dictionary = {}     # the medication dict being ordered
var pending_route: String = ""

# ============================================================
# UI REFERENCES (built in _ready / _build_ui)
# ============================================================
var main_panel: PanelContainer
var content_root: VBoxContainer

# Tab switcher
var tab_btn_search: Button
var tab_btn_browse: Button
var tab_btn_meddy: Button

# Tab content roots — only one visible at a time
var search_tab: VBoxContainer
var browse_tab: HBoxContainer
var meddy_tab: VBoxContainer

# Search tab
var search_input: LineEdit
var search_btn: Button
var search_results_vbox: VBoxContainer

# Browse tab
var category_list_vbox: VBoxContainer
var category_results_vbox: VBoxContainer
var category_header_label: Label

# MEDDY tab
var meddy_input: LineEdit
var meddy_btn: Button
var meddy_status_label: Label
var meddy_results_vbox: VBoxContainer

# Modals
var allergy_modal: Control
var allergy_modal_body_label: Label
var route_modal: Control
var route_modal_title_label: Label
var route_modal_routes_vbox: VBoxContainer
var route_modal_order_btn: Button
var route_modal_selected_label: Label
var ap_modal: Control
var ap_modal_body_label: Label
var no_iv_modal: Control

# HTTPRequest for Ask MEDDY
var http_request: HTTPRequest

# ============================================================
# CONSTANTS
# ============================================================
const C_BG        = Color(0.05, 0.05, 0.08, 0.96)
const C_PANEL     = Color(0.10, 0.12, 0.16)
const C_HEADER    = Color(0.13, 0.15, 0.21)
const C_ROW_ALT   = Color(0.12, 0.14, 0.18)
const C_SELECTED  = Color(0.15, 0.35, 0.60)
const C_CHIP      = Color(0.20, 0.45, 0.75)
const C_ACCENT    = Color(0.25, 0.55, 0.90)
const C_TEXT      = Color(0.90, 0.92, 0.95)
const C_DIM       = Color(0.55, 0.58, 0.65)
const C_WARN      = Color(0.90, 0.70, 0.20)
const C_DANGER    = Color(0.85, 0.25, 0.25)
const C_CONFIRM   = Color(0.20, 0.65, 0.30)

# Display order for Browse Categories tab (mirrors v1 catalog scope)
const CATEGORY_DISPLAY_ORDER: Array = [
	{"id": "antibiotics",            "label": "Antibiotics"},
	{"id": "analgesics",             "label": "Analgesics"},
	{"id": "gi",                     "label": "GI / Antiemetics"},
	{"id": "fluids_electrolytes",    "label": "Fluids & Electrolytes"},
	{"id": "vasopressors_inotropes", "label": "Vasopressors & Inotropes"},
	{"id": "anesthetics",            "label": "Anesthetics & Sedatives"},
	{"id": "paralytics",             "label": "Paralytics"},
	{"id": "reversal_antidotes",     "label": "Reversal & Antidotes"},
	{"id": "endocrine",              "label": "Endocrine"},
]

# Routes that do NOT require vascular access. Anything else is treated as IV-class
# and only renders if vascular_access_points is non-empty.
# (Future: epidural, ET, intrauterine, subdermal will get their own infrastructure
# gating; for v1 only IV is gated.)
const NON_IV_ROUTES: Array = [
	"PO", "IM", "SQ", "intranasal", "inhaled", "topical", "sublingual", "ODT",
	"transdermal", "ophthalmic", "otic", "PR", "buccal", "epidural", "ET",
	"vaginal", "intrauterine", "subdermal", "wound infiltration", "injection",
	"spinal", "nebulized"
]

# ============================================================
# LIFECYCLE
# ============================================================
func _ready() -> void:
	# HTTPRequest for Ask MEDDY filter
	http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(_on_meddy_llm_response)

	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	visible = false


# ============================================================
# ENTRY POINT — engine calls this each time popup opens
# ============================================================
func open(catalog: Array, allergies: Array, given: Array,
		vap: Array, ap: int, meddy_prompt: String) -> void:
	medications_catalog = catalog
	patient_allergies = allergies
	medications_given = given.duplicate()
	vascular_access_points = vap
	available_ap = ap
	meddy_filter_system_prompt = meddy_prompt

	# Reset transient UI state
	current_tab = 0
	current_category_id = ""
	meddy_searching = false
	meddy_filtered_ids = []
	pending_med = {}
	pending_route = ""

	if search_input:
		search_input.text = ""
	if meddy_input:
		meddy_input.text = ""
	if meddy_status_label:
		meddy_status_label.text = ""

	_hide_all_modals()
	_switch_tab(0)
	_apply_layout()
	visible = true


func _close() -> void:
	visible = false
	emit_signal("popup_closed")


func _apply_layout() -> void:
	if main_panel:
		PopupLayout.apply_layout(main_panel, "medications")


# ============================================================
# UI CONSTRUCTION
# ============================================================
func _build_ui() -> void:
	main_panel = PanelContainer.new()
	main_panel.add_theme_stylebox_override("panel", _panel_style(C_PANEL))
	add_child(main_panel)
	_apply_layout()

	content_root = VBoxContainer.new()
	content_root.add_theme_constant_override("separation", 6)
	main_panel.add_child(content_root)

	_build_titlebar()
	_build_tab_buttons()
	_build_tab_contents()
	_build_modals()


func _build_titlebar() -> void:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	content_root.add_child(bar)

	var title := _make_label("💊  Order Medications", 17, C_TEXT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(title)

	var close_btn := _make_btn("✕", 32)
	close_btn.pressed.connect(_close)
	bar.add_child(close_btn)


func _build_tab_buttons() -> void:
	var tab_bar := HBoxContainer.new()
	tab_bar.add_theme_constant_override("separation", 4)
	content_root.add_child(tab_bar)

	tab_btn_search = _make_btn("Search by Name", 0)
	tab_btn_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_btn_search.pressed.connect(_switch_tab.bind(0))
	tab_bar.add_child(tab_btn_search)

	tab_btn_browse = _make_btn("Browse Categories", 0)
	tab_btn_browse.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_btn_browse.pressed.connect(_switch_tab.bind(1))
	tab_bar.add_child(tab_btn_browse)

	tab_btn_meddy = _make_btn("Ask MEDDY!", 0)
	tab_btn_meddy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_btn_meddy.pressed.connect(_switch_tab.bind(2))
	tab_bar.add_child(tab_btn_meddy)


func _build_tab_contents() -> void:
	# Container that holds whichever tab is active
	var tab_area := PanelContainer.new()
	tab_area.add_theme_stylebox_override("panel", _panel_style(C_HEADER))
	tab_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_root.add_child(tab_area)

	var tab_holder := VBoxContainer.new()
	tab_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab_area.add_child(tab_holder)

	_build_search_tab(tab_holder)
	_build_browse_tab(tab_holder)
	_build_meddy_tab(tab_holder)


# ---------- SEARCH BY NAME TAB ----------
func _build_search_tab(parent: Container) -> void:
	search_tab = VBoxContainer.new()
	search_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search_tab.size_flags_vertical = Control.SIZE_EXPAND_FILL
	search_tab.add_theme_constant_override("separation", 6)
	parent.add_child(search_tab)

	var input_row := HBoxContainer.new()
	input_row.add_theme_constant_override("separation", 6)
	search_tab.add_child(input_row)

	search_input = LineEdit.new()
	search_input.placeholder_text = "Type drug name (generic or brand)... e.g. 'tor' finds Toradol"
	search_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search_input.text_submitted.connect(_on_search_submitted)
	input_row.add_child(search_input)

	search_btn = _make_btn("Search", 90)
	search_btn.pressed.connect(_on_search_pressed)
	input_row.add_child(search_btn)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	search_tab.add_child(scroll)

	search_results_vbox = VBoxContainer.new()
	search_results_vbox.add_theme_constant_override("separation", 2)
	search_results_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(search_results_vbox)


func _on_search_submitted(_text: String) -> void:
	_on_search_pressed()


func _on_search_pressed() -> void:
	var query := search_input.text.strip_edges().to_lower()
	_clear_children(search_results_vbox)

	if query.is_empty():
		var hint := _make_label("Type a name and press Search.", 12, C_DIM)
		search_results_vbox.add_child(hint)
		return

	var hits: Array = []
	for med in medications_catalog:
		if _name_matches_query(med, query):
			hits.append(med)

	if hits.is_empty():
		var none := _make_label("No medications match \"%s\"." % query, 12, C_DIM)
		search_results_vbox.add_child(none)
		return

	for med in hits:
		search_results_vbox.add_child(_build_med_row(med))


# Returns true if any of the drug's name tokens (generic or brand) start with query.
# "tor" matches "Toradol". "vanc" matches "Vancomycin". Case-insensitive.
func _name_matches_query(med: Dictionary, query: String) -> bool:
	var name: String = String(med.get("name", "")).to_lower()
	# Tokenize: split on whitespace, slash, parens, commas
	var cleaned := name.replace("(", " ").replace(")", " ").replace("/", " ").replace(",", " ")
	for token in cleaned.split(" ", false):
		if token.begins_with(query):
			return true
	return false


# ---------- BROWSE CATEGORIES TAB ----------
func _build_browse_tab(parent: Container) -> void:
	browse_tab = HBoxContainer.new()
	browse_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	browse_tab.size_flags_vertical = Control.SIZE_EXPAND_FILL
	browse_tab.add_theme_constant_override("separation", 6)
	parent.add_child(browse_tab)

	# Left: category list
	var left_panel := PanelContainer.new()
	left_panel.add_theme_stylebox_override("panel", _panel_style(C_PANEL))
	left_panel.custom_minimum_size.x = 220
	left_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	browse_tab.add_child(left_panel)

	var left_scroll := ScrollContainer.new()
	left_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_panel.add_child(left_scroll)

	category_list_vbox = VBoxContainer.new()
	category_list_vbox.add_theme_constant_override("separation", 2)
	category_list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.add_child(category_list_vbox)

	for cat in CATEGORY_DISPLAY_ORDER:
		var cat_id: String = cat["id"]
		var cat_label: String = cat["label"]
		var btn := _make_btn(cat_label, 0)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.pressed.connect(_on_category_clicked.bind(cat_id))
		category_list_vbox.add_child(btn)

	# Right: results for selected category
	var right_panel := PanelContainer.new()
	right_panel.add_theme_stylebox_override("panel", _panel_style(C_PANEL))
	right_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	browse_tab.add_child(right_panel)

	var right_vbox := VBoxContainer.new()
	right_vbox.add_theme_constant_override("separation", 4)
	right_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_panel.add_child(right_vbox)

	category_header_label = _make_label("Select a category from the left.", 13, C_DIM)
	right_vbox.add_child(category_header_label)

	var right_scroll := ScrollContainer.new()
	right_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_vbox.add_child(right_scroll)

	category_results_vbox = VBoxContainer.new()
	category_results_vbox.add_theme_constant_override("separation", 2)
	category_results_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_scroll.add_child(category_results_vbox)


func _on_category_clicked(cat_id: String) -> void:
	current_category_id = cat_id
	_clear_children(category_results_vbox)

	var cat_label: String = ""
	for cat in CATEGORY_DISPLAY_ORDER:
		if cat["id"] == cat_id:
			cat_label = cat["label"]
			break
	category_header_label.text = cat_label

	var meds_in_cat: Array = []
	for med in medications_catalog:
		if String(med.get("category_id", "")) == cat_id:
			meds_in_cat.append(med)

	if meds_in_cat.is_empty():
		category_results_vbox.add_child(_make_label("(none in v1 catalog)", 12, C_DIM))
		return

	for med in meds_in_cat:
		category_results_vbox.add_child(_build_med_row(med))


# ---------- ASK MEDDY TAB ----------
func _build_meddy_tab(parent: Container) -> void:
	meddy_tab = VBoxContainer.new()
	meddy_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	meddy_tab.size_flags_vertical = Control.SIZE_EXPAND_FILL
	meddy_tab.add_theme_constant_override("separation", 6)
	parent.add_child(meddy_tab)

	var input_row := HBoxContainer.new()
	input_row.add_theme_constant_override("separation", 6)
	meddy_tab.add_child(input_row)

	meddy_input = LineEdit.new()
	meddy_input.placeholder_text = "Ask MEDDY... e.g. 'what should I give for nausea', 'broad spectrum antibiotic'"
	meddy_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	meddy_input.text_submitted.connect(_on_meddy_submitted)
	input_row.add_child(meddy_input)

	meddy_btn = _make_btn("Ask", 90)
	meddy_btn.pressed.connect(_on_meddy_pressed)
	input_row.add_child(meddy_btn)

	meddy_status_label = _make_label("", 11, C_DIM)
	meddy_tab.add_child(meddy_status_label)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	meddy_tab.add_child(scroll)

	meddy_results_vbox = VBoxContainer.new()
	meddy_results_vbox.add_theme_constant_override("separation", 2)
	meddy_results_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(meddy_results_vbox)


func _on_meddy_submitted(_text: String) -> void:
	_on_meddy_pressed()


func _on_meddy_pressed() -> void:
	if meddy_searching:
		return
	var query := meddy_input.text.strip_edges()
	if query.is_empty():
		return

	meddy_searching = true
	meddy_btn.text = "Asking..."
	meddy_btn.disabled = true
	meddy_status_label.text = "MEDDY is thinking..."
	_clear_children(meddy_results_vbox)

	# Build inline catalog snippet for the LLM (id + name + class + tags)
	var catalog_summary: Array = []
	for med in medications_catalog:
		catalog_summary.append({
			"id": med.get("canonical_id", med.get("id", "")),
			"name": med.get("name", ""),
			"class": med.get("class", ""),
			"tags": med.get("semantic_tags", []),
		})

	var system_prompt: String = meddy_filter_system_prompt
	if system_prompt.is_empty():
		# Fallback if engine didn't inject one — minimal viable prompt
		system_prompt = (
			"You are MEDDY, helping a doctor pick medications. " +
			"Given the doctor's question and a JSON medication catalog, " +
			"return a JSON object: {\"canonical_ids\": [list of relevant ids]}. " +
			"Pick only medications that genuinely fit the question. " +
			"No prose, JSON only."
		)

	var user_prompt := JSON.stringify({
		"question": query,
		"catalog": catalog_summary,
	})

	var url := "http://localhost:3000/llm"
	var headers := ["Content-Type: application/json"]
	var body := JSON.stringify({
		"prompt": user_prompt,
		"system": system_prompt,
		"max_tokens": 400,
	})
	http_request.request(url, headers, HTTPClient.METHOD_POST, body)


func _on_meddy_llm_response(_result: int, response_code: int,
		_headers: PackedStringArray, body: PackedByteArray) -> void:
	meddy_searching = false
	meddy_btn.text = "Ask"
	meddy_btn.disabled = false

	if response_code != 200:
		meddy_status_label.text = "MEDDY couldn't reach the server (code %d)." % response_code
		return

	var json := JSON.new()
	json.parse(body.get_string_from_utf8())
	var data = json.get_data()
	if data == null or not data.has("response"):
		meddy_status_label.text = "MEDDY returned an empty response."
		return

	var raw_text: String = String(data["response"]).strip_edges()
	# Strip code fences if present
	raw_text = raw_text.replace("```json", "").replace("```", "").strip_edges()

	var inner := JSON.new()
	var err := inner.parse(raw_text)
	if err != OK:
		meddy_status_label.text = "MEDDY returned malformed JSON. Try rephrasing."
		print("[meds Ask MEDDY] parse failure on: ", raw_text)
		return

	var inner_data = inner.get_data()
	var ids = inner_data.get("canonical_ids", []) if inner_data is Dictionary else []
	if not (ids is Array) or ids.is_empty():
		meddy_status_label.text = "MEDDY didn't suggest any medications for that question."
		return

	meddy_filtered_ids = ids
	meddy_status_label.text = "MEDDY suggests these medications:"
	_clear_children(meddy_results_vbox)
	for med in medications_catalog:
		if String(med.get("canonical_id", med.get("id", ""))) in ids:
			meddy_results_vbox.add_child(_build_med_row(med))


# ============================================================
# TAB SWITCHING
# ============================================================
func _switch_tab(idx: int) -> void:
	current_tab = idx
	if search_tab:
		search_tab.visible = (idx == 0)
	if browse_tab:
		browse_tab.visible = (idx == 1)
	if meddy_tab:
		meddy_tab.visible = (idx == 2)
	# Visual indication on tab buttons
	_set_tab_button_active(tab_btn_search, idx == 0)
	_set_tab_button_active(tab_btn_browse, idx == 1)
	_set_tab_button_active(tab_btn_meddy, idx == 2)


func _set_tab_button_active(btn: Button, active: bool) -> void:
	if btn == null:
		return
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_SELECTED if active else C_HEADER
	sb.set_corner_radius_all(3)
	sb.set_content_margin_all(6)
	btn.add_theme_stylebox_override("normal", sb)


# ============================================================
# MEDICATION ROW (clickable button leading to order flow)
# ============================================================
func _build_med_row(med: Dictionary) -> Button:
	var btn := Button.new()
	var name: String = String(med.get("name", "?"))
	var med_class: String = String(med.get("class", ""))
	var ap: int = int(med.get("ap_cost", 1))
	var routes: Array = med.get("routes", [])
	var route_str := ", ".join(routes)
	btn.text = "  %s  —  %s   [%s]   (%d AP)" % [name, med_class, route_str, ap]
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.add_theme_color_override("font_color", C_TEXT)
	btn.add_theme_font_size_override("font_size", 12)

	var sb := StyleBoxFlat.new()
	sb.bg_color = C_ROW_ALT
	sb.set_corner_radius_all(3)
	sb.set_content_margin_all(6)
	btn.add_theme_stylebox_override("normal", sb)

	# Hover highlight
	var sb_hover := StyleBoxFlat.new()
	sb_hover.bg_color = C_SELECTED
	sb_hover.set_corner_radius_all(3)
	sb_hover.set_content_margin_all(6)
	btn.add_theme_stylebox_override("hover", sb_hover)

	btn.pressed.connect(_on_medication_clicked.bind(med))
	return btn


# ============================================================
# ORDER FLOW — entry
# ============================================================
func _on_medication_clicked(med: Dictionary) -> void:
	pending_med = med
	pending_route = ""

	# Step 1: feasibility check — does this drug have ANY currently-feasible route?
	if not _drug_has_any_feasible_route(med):
		_show_no_iv_modal(med)
		return

	# Step 2: allergy check
	var allergy_class = med.get("allergy_class", null)
	if allergy_class != null and String(allergy_class) in patient_allergies:
		_show_allergy_modal(med, String(allergy_class))
		return

	# Step 3: route selection
	_show_route_modal(med)


# A drug is feasible if any of its routes is non-IV, OR (route is IV and we have access).
func _drug_has_any_feasible_route(med: Dictionary) -> bool:
	var routes: Array = med.get("routes", [])
	for r in routes:
		if String(r) in NON_IV_ROUTES:
			return true
		# Otherwise treat as IV-class — only feasible if vascular access exists
		if String(r) == "IV" and not vascular_access_points.is_empty():
			return true
	return false


# ============================================================
# NO IV ACCESS MODAL — for IV-only drugs with no vascular access
# ============================================================
func _show_no_iv_modal(med: Dictionary) -> void:
	_hide_all_modals()
	no_iv_modal.visible = true
	# Body label is set during build — it's static text. Nothing to inject per-drug
	# beyond what's already there. (If we later want drug-specific text, set it here.)


func _on_no_iv_modal_ok() -> void:
	no_iv_modal.visible = false
	pending_med = {}


# ============================================================
# ALLERGY MODAL — fires 1 harm point on display, +1 more if proceed
# ============================================================
func _show_allergy_modal(med: Dictionary, allergy_class: String) -> void:
	_hide_all_modals()
	var name = String(med.get("name", "?"))
	allergy_modal_body_label.text = (
		"⚠  ALLERGY WARNING\n\n" +
		"This patient has a documented allergy to %s.\n\n" % allergy_class +
		"Giving %s could trigger an allergic reaction or anaphylaxis.\n\n" % name +
		"You receive 1 harm point for considering this. " +
		"If you proceed anyway, you receive an additional harm point and the patient " +
		"will likely have an anaphylactic reaction."
	)
	allergy_modal.visible = true
	# Engine handles the harm point assignment via this signal
	emit_signal("allergy_warning_shown",
		String(med.get("canonical_id", med.get("id", ""))),
		allergy_class)


func _on_allergy_proceed() -> void:
	allergy_modal.visible = false
	# Engine handles the second harm point + flag setting
	emit_signal("anaphylaxis_triggered_signal",
		String(pending_med.get("canonical_id", pending_med.get("id", ""))))
	# Continue to route selection
	_show_route_modal(pending_med)


func _on_allergy_cancel() -> void:
	allergy_modal.visible = false
	pending_med = {}


# ============================================================
# ROUTE SELECTION MODAL
# ============================================================
func _show_route_modal(med: Dictionary) -> void:
	_hide_all_modals()
	pending_route = ""
	route_modal_title_label.text = "Give: %s" % String(med.get("name", "?"))
	route_modal_selected_label.text = "Select a route below."
	route_modal_order_btn.disabled = true
	_clear_children(route_modal_routes_vbox)

	var routes: Array = med.get("routes", [])
	var any_route_added := false

	# Non-IV routes — always render (one button each)
	for r in routes:
		var rs := String(r)
		if rs in NON_IV_ROUTES:
			var btn := _make_route_btn(rs)
			btn.set_meta("route_token", rs)
			btn.pressed.connect(_on_route_picked.bind(rs))
			route_modal_routes_vbox.add_child(btn)
			any_route_added = true

	# IV routes — one button per vascular access point
	if "IV" in routes:
		if vascular_access_points.is_empty():
			# Drug has IV but no access. We already gated against THIS being the only
			# route at _drug_has_any_feasible_route; if we got here, the drug also has
			# non-IV routes that are listed above, so just show a disabled note.
			var disabled_note := _make_label(
				"  (IV not available — no vascular access placed)", 11, C_DIM)
			route_modal_routes_vbox.add_child(disabled_note)
		else:
			for vap in vascular_access_points:
				var label := "IV via %s" % String(vap.get("display_name", vap.get("site_id", "?")))
				var btn := _make_route_btn(label)
				# Encode as "IV|left_ac" so engine knows site
				var encoded := "IV|%s" % String(vap.get("site_id", ""))
				btn.set_meta("route_token", encoded)
				btn.pressed.connect(_on_route_picked.bind(encoded))
				route_modal_routes_vbox.add_child(btn)
				any_route_added = true

	if not any_route_added:
		# Should be impossible after _drug_has_any_feasible_route gate, but safety net
		route_modal_routes_vbox.add_child(_make_label(
			"  (no available routes — close and place IV access)", 11, C_DIM))

	route_modal.visible = true


func _make_route_btn(label: String) -> Button:
	var btn := _make_btn(label, 0)
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return btn


func _on_route_picked(route_token: String) -> void:
	# Toggle: clicking the already-selected route deselects it
	if route_token == pending_route:
		pending_route = ""
		route_modal_selected_label.text = "Select a route below."
		route_modal_order_btn.disabled = true
		_refresh_route_button_styles()
		return

	pending_route = route_token
	# Display friendly version (strip the "|left_ac" suffix for IV routes)
	var pretty := route_token
	if route_token.begins_with("IV|"):
		var site_id := route_token.substr(3)
		pretty = "IV via %s" % _vap_display_name(site_id)
	route_modal_selected_label.text = "Route selected: %s" % pretty
	route_modal_order_btn.disabled = false
	_refresh_route_button_styles()

# Highlight the currently-selected route button in C_SELECTED, others in default style.
# Called after every route button click.
func _refresh_route_button_styles() -> void:
	# Slightly lighter than C_HEADER for hover affordance on unselected buttons
	var c_hover_light := Color(0.18, 0.20, 0.27)

	for child in route_modal_routes_vbox.get_children():
		if not (child is Button):
			continue
		var btn: Button = child
		var btn_token: String = String(btn.get_meta("route_token", ""))
		var is_selected: bool = (btn_token == pending_route and not pending_route.is_empty())

		if is_selected:
			# Selected: blue across all states so hover/click don't override
			btn.add_theme_stylebox_override("normal",  _route_btn_style(C_SELECTED))
			btn.add_theme_stylebox_override("hover",   _route_btn_style(C_SELECTED))
			btn.add_theme_stylebox_override("pressed", _route_btn_style(C_SELECTED))
			btn.add_theme_stylebox_override("focus",   _route_btn_style(C_SELECTED))
		else:
			# Unselected: dark default, slightly-lighter dark on hover (no blue)
			btn.add_theme_stylebox_override("normal",  _route_btn_style(C_HEADER))
			btn.add_theme_stylebox_override("hover",   _route_btn_style(c_hover_light))
			btn.add_theme_stylebox_override("pressed", _route_btn_style(c_hover_light))
			btn.add_theme_stylebox_override("focus",   _route_btn_style(C_HEADER))


# Small helper so we don't repeat the StyleBoxFlat boilerplate four times above.
func _route_btn_style(color: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(3)
	sb.set_content_margin_all(6)
	return sb
		
func _vap_display_name(site_id: String) -> String:
	for vap in vascular_access_points:
		if String(vap.get("site_id", "")) == site_id:
			return String(vap.get("display_name", site_id))
	return site_id


func _on_route_order_pressed() -> void:
	if pending_route.is_empty():
		return
	route_modal.visible = false
	_show_ap_modal()


func _on_route_cancel() -> void:
	route_modal.visible = false
	pending_med = {}
	pending_route = ""


# ============================================================
# AP CONFIRMATION MODAL
# ============================================================
func _show_ap_modal() -> void:
	_hide_all_modals()
	var name = String(pending_med.get("name", "?"))
	var ap: int = int(pending_med.get("ap_cost", 1))
	var pretty_route := pending_route
	if pending_route.begins_with("IV|"):
		pretty_route = "IV via %s" % _vap_display_name(pending_route.substr(3))

	ap_modal_body_label.text = (
		"Give %s\nRoute: %s\n\nCost: %d AP\nAP available: %d" %
		[name, pretty_route, ap, available_ap]
	)
	ap_modal.visible = true


func _on_ap_confirm() -> void:
	ap_modal.visible = false
	var ap: int = int(pending_med.get("ap_cost", 1))
	var canonical_id: String = String(pending_med.get("canonical_id",
		pending_med.get("id", "")))

	# Engine spends AP, applies effects, increments turn — popup just signals
	emit_signal("medication_ordered", canonical_id, pending_route, ap)

	# Update local log so subsequent opens within this encounter reflect what's been given
	medications_given.append({
		"canonical_id": canonical_id,
		"route": pending_route,
		"ap_spent": ap,
	})

	pending_med = {}
	pending_route = ""
	# Per spec: return to medication popup main view
	_switch_tab(current_tab)


func _on_ap_cancel() -> void:
	ap_modal.visible = false
	pending_med = {}
	pending_route = ""


# ============================================================
# MODAL BUILD + HELPERS
# ============================================================
func _build_modals() -> void:
	allergy_modal = _build_modal_layer()
	add_child(allergy_modal)
	var allergy_box := _build_modal_box(allergy_modal,
		"⚠  Allergy Warning",
		C_WARN)
	allergy_modal_body_label = _make_label("", 12, C_TEXT)
	allergy_modal_body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	allergy_modal_body_label.custom_minimum_size = Vector2(420, 0)
	allergy_box.add_child(allergy_modal_body_label)
	var allergy_btns := HBoxContainer.new()
	allergy_btns.add_theme_constant_override("separation", 12)
	allergy_btns.alignment = BoxContainer.ALIGNMENT_CENTER
	allergy_box.add_child(allergy_btns)
	var allergy_proceed := _make_btn("Proceed Anyway", 160)
	allergy_proceed.add_theme_color_override("font_color", C_DANGER)
	allergy_proceed.pressed.connect(_on_allergy_proceed)
	allergy_btns.add_child(allergy_proceed)
	var allergy_cancel := _make_btn("Cancel", 120)
	allergy_cancel.pressed.connect(_on_allergy_cancel)
	allergy_btns.add_child(allergy_cancel)

	route_modal = _build_modal_layer()
	add_child(route_modal)
	var route_box := _build_modal_box(route_modal,
		"Select Route",
		C_ACCENT)
	route_modal_title_label = _make_label("Give: ?", 14, C_TEXT)
	route_box.add_child(route_modal_title_label)
	var route_scroll := ScrollContainer.new()
	route_scroll.custom_minimum_size = Vector2(420, 200)
	route_box.add_child(route_scroll)
	route_modal_routes_vbox = VBoxContainer.new()
	route_modal_routes_vbox.add_theme_constant_override("separation", 4)
	route_modal_routes_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	route_scroll.add_child(route_modal_routes_vbox)
	route_modal_selected_label = _make_label("Select a route below.", 11, C_DIM)
	route_box.add_child(route_modal_selected_label)
	var route_btns := HBoxContainer.new()
	route_btns.add_theme_constant_override("separation", 12)
	route_btns.alignment = BoxContainer.ALIGNMENT_CENTER
	route_box.add_child(route_btns)
	route_modal_order_btn = _make_btn("Order", 120)
	route_modal_order_btn.disabled = true
	route_modal_order_btn.pressed.connect(_on_route_order_pressed)
	route_btns.add_child(route_modal_order_btn)
	var route_cancel := _make_btn("Cancel", 120)
	route_cancel.pressed.connect(_on_route_cancel)
	route_btns.add_child(route_cancel)

	ap_modal = _build_modal_layer()
	add_child(ap_modal)
	var ap_box := _build_modal_box(ap_modal,
		"Confirm Medication Order",
		C_CONFIRM)
	ap_modal_body_label = _make_label("", 13, C_TEXT)
	ap_modal_body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ap_modal_body_label.custom_minimum_size = Vector2(360, 0)
	ap_box.add_child(ap_modal_body_label)
	var ap_btns := HBoxContainer.new()
	ap_btns.add_theme_constant_override("separation", 12)
	ap_btns.alignment = BoxContainer.ALIGNMENT_CENTER
	ap_box.add_child(ap_btns)
	var ap_confirm := _make_btn("Confirm", 120)
	ap_confirm.pressed.connect(_on_ap_confirm)
	ap_btns.add_child(ap_confirm)
	var ap_cancel := _make_btn("Cancel", 120)
	ap_cancel.pressed.connect(_on_ap_cancel)
	ap_btns.add_child(ap_cancel)

	no_iv_modal = _build_modal_layer()
	add_child(no_iv_modal)
	var no_iv_box := _build_modal_box(no_iv_modal,
		"No IV Access",
		C_WARN)
	var no_iv_body := _make_label(
		"This medication can only be given IV, but the patient has no IV access.\n\n" +
		"Close this menu, click the IV button, and place an IV first. " +
		"Then return here to order the medication.",
		12, C_TEXT)
	no_iv_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	no_iv_body.custom_minimum_size = Vector2(360, 0)
	no_iv_box.add_child(no_iv_body)
	var no_iv_btns := HBoxContainer.new()
	no_iv_btns.alignment = BoxContainer.ALIGNMENT_CENTER
	no_iv_box.add_child(no_iv_btns)
	var no_iv_ok := _make_btn("OK", 120)
	no_iv_ok.pressed.connect(_on_no_iv_modal_ok)
	no_iv_btns.add_child(no_iv_ok)


# Builds a full-screen dimmed layer that hosts a modal box
func _build_modal_layer() -> Control:
	var layer := Control.new()
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.visible = false
	# Dim background
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(dim)
	return layer


# Builds a centered modal panel inside a layer, returns the inner VBox to populate
func _build_modal_box(layer: Control, title_text: String, accent: Color) -> VBoxContainer:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)

	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", _panel_style(C_PANEL))
	center.add_child(box)

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 12)
	box.add_child(inner)

	# Title bar
	var title_panel := PanelContainer.new()
	title_panel.add_theme_stylebox_override("panel", _panel_style(accent))
	var title_lbl := _make_label("  " + title_text, 14, C_TEXT)
	title_panel.add_child(title_lbl)
	inner.add_child(title_panel)

	return inner


func _hide_all_modals() -> void:
	if allergy_modal:
		allergy_modal.visible = false
	if route_modal:
		route_modal.visible = false
	if ap_modal:
		ap_modal.visible = false
	if no_iv_modal:
		no_iv_modal.visible = false


# ============================================================
# UTILITY
# ============================================================
func _make_label(text: String, font_size: int, color: Color = C_TEXT) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_font_size_override("font_size", font_size)
	return lbl


func _make_btn(text: String, min_width: int) -> Button:
	var btn := Button.new()
	btn.text = text
	if min_width > 0:
		btn.custom_minimum_size.x = min_width
	btn.add_theme_color_override("font_color", C_TEXT)
	btn.add_theme_font_size_override("font_size", 12)
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_HEADER
	sb.set_corner_radius_all(3)
	sb.set_content_margin_all(6)
	btn.add_theme_stylebox_override("normal", sb)
	return btn


func _panel_style(color: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(8)
	return sb


func _clear_children(node: Node) -> void:
	for c in node.get_children():
		c.queue_free()
