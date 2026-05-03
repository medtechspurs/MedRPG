# imaging_system.gd
# Attach to a Control node (full rect anchors) in a new scene: imaging_popup.tscn
# Add imaging_popup.tscn as a child of ClinicalEncounter root node (visible = false by default).
# This script builds all UI programmatically — no manual node setup needed beyond the root Control.
#
# Mirrors labs_system.gd architecture, adapted for imaging:
#   - No panels (each study is individual)
#   - Result text (findings + impression) instead of numeric values
#   - Pending state with dual delays (real-time AND turn delay)
#   - IV contrast confirmation popup
#   - Stability / pediatric / IV-access ordering blocks
#   - Modality color coding for badges

extends Control

# ============================================================
# SIGNALS
# ============================================================
signal order_confirmed(orders: Array, total_ap: int, used_iv_contrast: bool)
signal popup_closed

# ============================================================
# INJECTED DATA — set by clinical_engine before calling open()
# ============================================================
var master_imaging_data: Dictionary = {}
var condition_imaging_data: Dictionary = {}
var current_patient_state: String = "stable"
var elapsed_seconds: float = 0.0
var current_turn: int = 0

# Patient flags relevant to ordering eligibility
var patient_has_iv: bool = false
var patient_has_contrast_allergy: bool = false
var patient_creatinine: float = 1.0   # default normal; engine can override
var patient_age: int = 22              # demographics for pediatric filter

# States in which MRI (and other requires_stable studies) are blocked
var unstable_states: Array = ["septic_shock", "coma_fail"]

# ============================================================
# INTERNAL STATE
# ============================================================
var all_studies: Array = []
var study_lookup: Dictionary = {}      # study_id -> study dict

var selected_study_ids: Dictionary = {}                # study_id -> true
var ordered_studies_this_encounter: Dictionary = {}    # study_id -> true (for repeat warning)
var encounter_orders: Array = []                       # all orders this encounter (pending + resolved)

var sort_mode: String = "time"
var confirm_mode: bool = false                         # true when showing "Confirm / Cancel"
var llm_searching: bool = false
# Tree expand state — keys are "<tab>|<category_id>" or "<tab>|<category_id>|<subcat_id>"
# tab is "name" or "browse". Defaults to collapsed (false) when key absent.
var tree_expanded: Dictionary = {}
var expanded_orders: Dictionary = {}                   # order_uid -> bool (per-row expand state)
var order_counter: int = 0                             # increments each _execute_order()

# Cache: key "study_id|state" -> Dictionary {findings, impression, is_abnormal}
var result_cache: Dictionary = {}

# Pending refresh timer
var pending_tick_timer: Timer

# ============================================================
# UI REFERENCES
# ============================================================
var main_panel: PanelContainer
var tab_container: TabContainer

# Name search tab
var name_search_field: LineEdit
var name_results_list: VBoxContainer

# Description search tab (Ask MEDDY)
var desc_search_field: LineEdit
var desc_search_btn: Button
var desc_status_label: Label
var desc_results_list: VBoxContainer

# Modality browser tab
var browse_tree_list: VBoxContainer

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

# Modal popup layer (for IV contrast confirm + block popups)
var modal_layer: Control
var modal_content: VBoxContainer  # direct ref to content VBox inside the modal card

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
const C_CHIP_CONTRAST = Color(0.65, 0.45, 0.20)  # amber chip for contrast studies
const C_ABNORMAL  = Color(0.85, 0.25, 0.25)
const C_NORMAL    = Color(0.25, 0.70, 0.40)
const C_PENDING   = Color(0.85, 0.70, 0.25)
const C_ACCENT    = Color(0.25, 0.55, 0.90)
const C_TEXT      = Color(0.90, 0.92, 0.95)
const C_DIM       = Color(0.55, 0.58, 0.65)
const C_WARN      = Color(0.90, 0.70, 0.20)
const C_DANGER    = Color(0.90, 0.30, 0.30)
const C_CONFIRM   = Color(0.20, 0.65, 0.30)

# Modality color palette — used for badges in result rows + result view
const MODALITY_COLORS = {
	"xray":        Color(0.70, 0.72, 0.78),  # silver / plain film
	"ultrasound":  Color(0.30, 0.78, 0.78),  # teal
	"ct":          Color(0.40, 0.65, 0.95),  # blue
	"cta":         Color(0.30, 0.85, 0.95),  # cyan
	"mri":         Color(0.75, 0.50, 0.95),  # purple
	"mra":         Color(0.95, 0.45, 0.85),  # magenta
	"nuclear":     Color(0.95, 0.70, 0.30),  # orange/yellow
	"fluoroscopy": Color(0.55, 0.85, 0.45),  # green
}

const MODALITY_BADGE_TEXT = {
	"xray":        "X-RAY",
	"ultrasound":  "US",
	"ct":          "CT",
	"cta":         "CTA",
	"mri":         "MRI",
	"mra":         "MRA",
	"nuclear":     "NUC MED",
	"fluoroscopy": "FLUORO",
}

# ============================================================
# ENTRY POINT
# ============================================================
# Called by clinical_engine whenever patient state changes OR when a specific
# intervention warrants new imaging (e.g. abscess drained → repeat CT will differ).
func invalidate_result_cache() -> void:
	result_cache.clear()
	print("Imaging result cache cleared — patient state or intervention changed")


func _center_panel() -> void:
	# Delegates to the shared PopupLayout helper so all popups (imaging, labs,
	# meds, etc.) use one source of truth for edge offsets. To adjust the size
	# or position of imaging popups, edit popup_layout.gd, not here.
	PopupLayout.apply_layout(main_panel, "imaging")


func open(master_imaging: Dictionary,
		condition_imaging: Dictionary,
		patient_state: String,
		elapsed: float,
		turn: int,
		prior_orders: Array,
		has_iv: bool,
		demographics: Dictionary = {},
		clinical_flags: Dictionary = {}) -> void:

	master_imaging_data    = master_imaging
	condition_imaging_data = condition_imaging
	current_patient_state  = patient_state
	elapsed_seconds        = elapsed
	current_turn           = turn
	encounter_orders       = prior_orders.duplicate(true)
	patient_has_iv         = has_iv

	# Demographics (age for pediatric filter)
	patient_age = int(demographics.get("age", 22))

	# Optional clinical flags for contrast safety warnings
	patient_has_contrast_allergy = bool(clinical_flags.get("contrast_allergy", false))
	patient_creatinine = float(clinical_flags.get("creatinine", 1.0))

	# Allow per-condition override of unstable_states
	if condition_imaging.has("unstable_states"):
		unstable_states = condition_imaging["unstable_states"]

	all_studies = master_imaging_data.get("studies", [])

	# Build lookup dict
	study_lookup.clear()
	for study in all_studies:
		study_lookup[study["id"]] = study

	selected_study_ids.clear()
	confirm_mode = false
	tree_expanded.clear()  # All categories collapsed on every open
	if name_search_field:
		name_search_field.text = ""  # Clear any leftover search text
	if desc_search_field:
		desc_search_field.text = ""  # Clear MEDDY's search text
	if desc_status_label:
		desc_status_label.text = ""  # Clear MEDDY's status message
	if desc_results_list:
		for c in desc_results_list.get_children():
			c.queue_free()  # Clear MEDDY's previous result rows

	# Resolve any pending whose delays elapsed while popup was closed
	_resolve_ready_pending()

	_refresh_browse_tree()
	_refresh_name_results("")
	_refresh_selected_display()
	_refresh_ap_cost()
	_refresh_results_view()
	_refresh_see_results_btn()

	if results_view:
		results_view.visible = false

	visible = true
	_center_panel()
	_set_pending_tick_active(true)


# ============================================================
# _READY — build entire UI
# ============================================================
func _ready() -> void:
	# HTTP for description search
	http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.request_completed.connect(_on_desc_llm_response)

	# Pending refresh timer — keeps "results in X turns / Y seconds" countdowns live
	pending_tick_timer = Timer.new()
	pending_tick_timer.wait_time = 1.0
	pending_tick_timer.one_shot = false
	pending_tick_timer.autostart = false
	pending_tick_timer.timeout.connect(_on_pending_tick)
	add_child(pending_tick_timer)

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
	var title_lbl := _make_label("🩻  Order Imaging", 17)
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
	_build_modality_tab()
	_build_desc_search_tab()

	# --- Selected section ---
	var sel_section := VBoxContainer.new()
	sel_section.custom_minimum_size.y = 90
	# Cap how tall the section can grow before scrolling kicks in (about 4 rows of chips).
	sel_section.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
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
	sel_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sel_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Vertical scroll only — chips wrap horizontally inside the HFlowContainer,
	# new rows stack downward, scrollbar appears when the stack is too tall.
	sel_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sel_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	sel_scroll.custom_minimum_size.y = 60
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

	# --- Modal layer (hidden by default) — used for IV contrast confirm + block popups ---
	_build_modal_layer()

	visible = false


# ============================================================
# TAB: NAME SEARCH
# ============================================================
func _make_results_col_header() -> Control:
	# Header structure must mirror _make_result_row exactly so columns align:
	#   [8px outer pad] [62px badge col] [8px sep] [Name (expand)] [8px sep]
	#   [240px modality col] [8px sep] [50px ap col, right-aligned] [8px sep]
	#   [70px sel col, right-aligned] [8px outer pad]
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

	# Badge column placeholder (62px to match badge_lbl)
	var badge_pad := Control.new()
	badge_pad.custom_minimum_size.x = 62
	inner.add_child(badge_pad)

	# Study Name — expands like the data row's name_lbl
	var name_hdr := _make_label("Study Name", 11, C_DIM)
	name_hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_child(name_hdr)

	# Notes column (240px to match notes_lbl)
	var notes_hdr := _make_label("Notes", 11, C_DIM)
	notes_hdr.custom_minimum_size.x = 240
	inner.add_child(notes_hdr)

	# AP Cost column — right-aligned, same 50px width as ap_lbl
	var ap_hdr := _make_label("AP Cost", 11, C_DIM)
	ap_hdr.custom_minimum_size.x = 50
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
	name_search_field.placeholder_text = "Type a study name... (e.g. CT abdomen, RUQ ultrasound, head CT)"
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
	if not name_results_list:
		return
	for c in name_results_list.get_children():
		c.queue_free()

	var lower_q: String = query.to_lower().strip_edges()

	# When searching, show a flat alphabetical list of matches.
	if lower_q != "":
		var matches: Array = []
		for study in _visible_studies():
			if _study_matches(study, lower_q):
				matches.append(study)
		_sort_studies_with_lr_pairing(matches)

		# Single header showing match count
		var hdr := _make_label("  %d match(es) for '%s'" % [matches.size(), query], 12, C_DIM)
		hdr.custom_minimum_size.y = 24
		name_results_list.add_child(hdr)

		var row_idx: int = 0
		for study in matches:
			name_results_list.add_child(_make_result_row(study, row_idx))
			row_idx += 1
		return

	# No search query — render the full collapsible tree.
	_render_study_tree(name_results_list, "name")


func _study_matches(study: Dictionary, q: String) -> bool:
	if q == "":
		return true
	if q in study.get("name", "").to_lower():
		return true
	for alias in study.get("aliases", []):
		if q in alias.to_lower():
			return true
	for tag in study.get("tags", []):
		if q in tag.to_lower():
			return true
	# Match on body region words too (e.g. "abdomen" -> CT abdomen)
	if q in study.get("body_region", "").to_lower():
		return true
	return false


func _visible_studies() -> Array:
	# Filter pediatric_only studies for adult cases.
	var out: Array = []
	var is_pediatric := patient_age < 18
	for s in all_studies:
		if s.get("pediatric_only", false) and not is_pediatric:
			continue
		out.append(s)
	return out


# ============================================================
# STUDY TREE — shared structure for Search by Name + Browse Modalities
# ============================================================
# Returns an Array of category dicts in display order:
# [
#   {
#     "id": "xray", "name": "X-Ray",
#     "subcategories": [    # may be empty for flat categories
#       {"id": "head", "name": "Head", "studies": [studyDict, ...]},
#       ...
#     ],
#     "studies": [...]      # only used when subcategories is empty
#   },
#   ...
# ]
func _build_study_tree() -> Array:
	# Define top-level categories in display order.
	# Each entry has an "id", a "name", and a function (or rule) for grouping/filtering studies.
	var tree: Array = []
	var visible: Array = _visible_studies()

	# X-Ray — body region subcategories
	var xray_studies: Array = []
	for s in visible:
		if s.get("modality", "") == "xray":
			xray_studies.append(s)
	tree.append({
		"id": "xray",
		"name": "X-Ray",
		"subcategories": _build_xray_subcategories(xray_studies),
		"studies": [],
	})

	# Ultrasound — flat
	tree.append(_make_flat_category("ultrasound", "Ultrasound", visible))

	# CT — split with/without contrast
	var ct_studies: Array = []
	for s in visible:
		if s.get("modality", "") == "ct":
			ct_studies.append(s)
	tree.append({
		"id": "ct",
		"name": "CT",
		"subcategories": _build_contrast_split_subcategories(ct_studies),
		"studies": [],
	})

	# CTA — flat
	tree.append(_make_flat_category("cta", "CT Angiogram", visible))

	# MRI — split with/without contrast (excluding fast MRI brain)
	var mri_studies: Array = []
	for s in visible:
		if s.get("modality", "") == "mri" and s.get("id", "") != "mri_brain_fast":
			mri_studies.append(s)
	tree.append({
		"id": "mri",
		"name": "MRI",
		"subcategories": _build_contrast_split_subcategories(mri_studies),
		"studies": [],
	})

	# MRA — flat
	tree.append(_make_flat_category("mra", "MR Angiogram", visible))

	# Fast MRI Brain — its own top-level (single study expected, but generalize)
	var fast_mri_studies: Array = []
	for s in visible:
		if s.get("id", "") == "mri_brain_fast":
			fast_mri_studies.append(s)
	_sort_studies_with_lr_pairing(fast_mri_studies)
	tree.append({
		"id": "mri_fast",
		"name": "Fast MRI Brain",
		"subcategories": [],
		"studies": fast_mri_studies,
	})

	# Nuclear Medicine — flat
	tree.append(_make_flat_category("nuclear", "Nuclear Medicine", visible))

	# Fluoroscopy — flat
	tree.append(_make_flat_category("fluoroscopy", "Fluoroscopy", visible))

	return tree


func _make_flat_category(modality_id: String, display_name: String, visible: Array) -> Dictionary:
	var studies: Array = []
	for s in visible:
		if s.get("modality", "") == modality_id:
			studies.append(s)
	_sort_studies_with_lr_pairing(studies)
	return {
		"id": modality_id,
		"name": display_name,
		"subcategories": [],
		"studies": studies,
	}


func _build_contrast_split_subcategories(studies: Array) -> Array:
	# Splits a list of CT or MRI studies into "With Contrast" and "Without Contrast".
	# Any study with requires_iv_contrast=true goes under With Contrast; everything else under Without.
	var with_contrast: Array = []
	var without_contrast: Array = []
	for s in studies:
		if s.get("requires_iv_contrast", false):
			with_contrast.append(s)
		else:
			without_contrast.append(s)
	_sort_studies_with_lr_pairing(with_contrast)
	_sort_studies_with_lr_pairing(without_contrast)

	var out: Array = []
	if not with_contrast.is_empty():
		out.append({"id": "with_contrast", "name": "With Contrast", "studies": with_contrast})
	if not without_contrast.is_empty():
		out.append({"id": "without_contrast", "name": "Without Contrast", "studies": without_contrast})
	return out


func _build_xray_subcategories(studies: Array) -> Array:
	# Buckets X-Ray studies by body region into the eight subcategories.
	# body_region values seen: head, neck, chest, abdomen, lumbar_spine, thoracic_spine, cervical_spine,
	#   left_upper_extremity, right_upper_extremity, left_lower_extremity, right_lower_extremity, etc.
	var buckets: Dictionary = {
		"head":   [],
		"neck":   [],
		"spine":  [],
		"chest":  [],
		"abdomen": [],
		"upper":  [],
		"lower":  [],
		"other":  [],
	}
	for s in studies:
		var region: String = s.get("body_region", "")
		var bucket: String = _xray_bucket_for_region(region)
		buckets[bucket].append(s)

	# Display order — matches what the user requested.
	var ordered: Array = [
		{"id": "head",    "name": "Head",              "key": "head"},
		{"id": "neck",    "name": "Neck",              "key": "neck"},
		{"id": "spine",   "name": "Spine",             "key": "spine"},
		{"id": "chest",   "name": "Chest",             "key": "chest"},
		{"id": "abdomen", "name": "Abdomen",           "key": "abdomen"},
		{"id": "upper",   "name": "Upper Extremities", "key": "upper"},
		{"id": "lower",   "name": "Lower Extremities", "key": "lower"},
		{"id": "other",   "name": "Other",             "key": "other"},
	]

	var out: Array = []
	for entry in ordered:
		var k: String = entry["key"]
		var arr: Array = buckets[k]
		if arr.is_empty():
			continue
		_sort_studies_with_lr_pairing(arr)
		out.append({"id": entry["id"], "name": entry["name"], "studies": arr})
	return out


func _xray_bucket_for_region(region: String) -> String:
	var r: String = region.to_lower()
	if r == "head" or r == "skull" or r == "face" or r == "facial" or r == "sinus" or r == "sinuses" or r == "mandible":
		return "head"
	if r == "neck":
		return "neck"
	if "spine" in r or r == "lumbar" or r == "thoracic" or r == "cervical" or r == "sacrum" or r == "coccyx":
		return "spine"
	if r == "chest" or r == "ribs" or r == "sternum" or r == "clavicle":
		return "chest"
	if r == "abdomen" or r == "pelvis" or r == "kub" or r == "abdomen_pelvis":
		return "abdomen"
	if "upper_extremity" in r or r == "shoulder" or r == "arm" or r == "elbow" or r == "forearm" or r == "wrist" or r == "hand" or r == "finger" or r == "fingers":
		return "upper"
	if "lower_extremity" in r or r == "hip" or r == "thigh" or r == "femur" or r == "knee" or r == "leg" or r == "tibia" or r == "fibula" or r == "ankle" or r == "foot" or r == "toe" or r == "toes" or r == "calcaneus":
		return "lower"
	return "other"


# Sort studies alphabetically, keeping left/right pairs grouped (left first).
# Strategy: derive a "base name" by stripping "Left "/"Right " from the study name,
# then sort by base name. Within a tie, Left sorts before Right.
func _sort_studies_with_lr_pairing(studies: Array) -> void:
	studies.sort_custom(func(a, b):
		var an: Array = _lr_sort_key(a.get("name", ""))
		var bn: Array = _lr_sort_key(b.get("name", ""))
		var a_base: String = an[0]
		var b_base: String = bn[0]
		if a_base != b_base:
			return a_base < b_base
		var a_rank: int = an[1]
		var b_rank: int = bn[1]
		return a_rank < b_rank  # 0 = left, 1 = right, 2 = neither
	)


func _lr_sort_key(name: String) -> Array:
	# Returns [base_name_lower, lr_rank].
	# lr_rank: 0 = Left variant, 1 = Right variant, 2 = no L/R designation.
	var base: String = name
	var rank: int = 2
	# Look for " Left " or " Right " (case-sensitive markers as they appear in study names)
	# Examples: "X-Ray Left Hand 3 View", "MRI Left Knee with and without Contrast"
	var idx_left: int = base.find(" Left ")
	var idx_right: int = base.find(" Right ")
	if idx_left >= 0:
		rank = 0
		base = base.replace(" Left ", " ")
	elif idx_right >= 0:
		rank = 1
		base = base.replace(" Right ", " ")
	return [base.to_lower(), rank]


# ============================================================
# TREE RENDERER — shared by Search by Name and Browse Modalities
# ============================================================
# Renders the full tree into the given container. tab_key is "name" or "browse" —
# used so the two tabs maintain independent expand/collapse state.
func _render_study_tree(container: VBoxContainer, tab_key: String) -> void:
	var tree: Array = _build_study_tree()
	for cat in tree:
		container.add_child(_make_category_block(cat, tab_key))


func _make_category_block(cat: Dictionary, tab_key: String) -> VBoxContainer:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 1)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var cat_id: String = cat["id"]
	var cat_name: String = cat["name"]
	var subcats: Array = cat.get("subcategories", [])
	var studies: Array = cat.get("studies", [])
	var total_count: int = 0
	if subcats.is_empty():
		total_count = studies.size()
	else:
		for sub in subcats:
			total_count += sub.get("studies", []).size()

	var key: String = tab_key + "|" + cat_id
	var is_expanded: bool = tree_expanded.get(key, false)

	# Top-level header
	var header := Button.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.custom_minimum_size.y = 34
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_style_btn_bg(header, C_HEADER)
	# Nudge text 2 pixels right of the panel's left edge so the arrow and
	# category name don't sit flush against the panel's left margin.
	_set_btn_left_padding(header, 2)
	var icon: String = "▼ " if is_expanded else "▶ "
	header.text = "%s%s   (%d)" % [icon, cat_name, total_count]
	var captured_key: String = key
	var captured_tab: String = tab_key
	header.pressed.connect(func():
		tree_expanded[captured_key] = not tree_expanded.get(captured_key, false)
		_refresh_tab(captured_tab)
	)
	vbox.add_child(header)

	if not is_expanded:
		return vbox

	# Body — either subcategory headers or direct study rows
	if not subcats.is_empty():
		for sub in subcats:
			vbox.add_child(_make_subcategory_block(cat_id, sub, tab_key))
	else:
		var row_idx: int = 0
		for study in studies:
			vbox.add_child(_make_result_row(study, row_idx))
			row_idx += 1

	return vbox


func _make_subcategory_block(cat_id: String, sub: Dictionary, tab_key: String) -> VBoxContainer:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 1)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var sub_id: String = sub["id"]
	var sub_name: String = sub["name"]
	var studies: Array = sub.get("studies", [])

	var key: String = tab_key + "|" + cat_id + "|" + sub_id
	var is_expanded: bool = tree_expanded.get(key, false)

	# Subcategory header — slightly indented + slightly different shade
	var header := Button.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.custom_minimum_size.y = 30
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_style_btn_bg(header, Color(C_HEADER.r - 0.02, C_HEADER.g - 0.02, C_HEADER.b - 0.02))
	# Nudge text 2 pixels right of the panel's left edge so the arrow and
	# subcategory name don't sit flush against the panel's left margin.
	_set_btn_left_padding(header, 2)
	var icon: String = "▼ " if is_expanded else "▶ "
	header.text = "    %s%s   (%d)" % [icon, sub_name, studies.size()]
	var captured_key: String = key
	var captured_tab: String = tab_key
	header.pressed.connect(func():
		tree_expanded[captured_key] = not tree_expanded.get(captured_key, false)
		_refresh_tab(captured_tab)
	)
	vbox.add_child(header)

	if not is_expanded:
		return vbox

	var row_idx: int = 0
	for study in studies:
		vbox.add_child(_make_result_row(study, row_idx))
		row_idx += 1

	return vbox


# Refresh the right tab after a tree node was toggled.
func _refresh_tab(tab_key: String) -> void:
	if tab_key == "name":
		_refresh_name_results(name_search_field.text if name_search_field else "")
	elif tab_key == "browse":
		_refresh_browse_tree()


# ============================================================
# TAB: ASK MEDDY (description search)
# ============================================================
func _build_desc_search_tab() -> void:
	var tab := VBoxContainer.new()
	tab.name = "AskMeddy"
	tab.add_theme_constant_override("separation", 6)
	tab_container.add_child(tab)
	tab_container.set_tab_title(tab_container.get_tab_count() - 1, "Ask MEDDY! Describe what imaging you want")

	var search_row := _make_hbox(6)
	# Small leading spacer so the input's text aligns with the tab title text above it.
	var desc_search_lpad := Control.new()
	desc_search_lpad.custom_minimum_size.x = 9
	search_row.add_child(desc_search_lpad)
	desc_search_field = LineEdit.new()
	desc_search_field.placeholder_text = "Describe what you're looking for... (e.g. 'rule out PE', 'check for stroke', 'look at the appendix')"
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

	# Build compact study list for LLM context (id + name + modality + aliases)
	var lines: PackedStringArray = []
	for s in _visible_studies():
		var aliases: String = ", ".join(s.get("aliases", []).slice(0, 3))
		lines.append('STUDY|%s|%s|%s|%s' % [s["id"], s["name"], s.get("modality", ""), aliases])
	var ctx := "\n".join(lines)

	var system_prompt := """You are a medical imaging search assistant for a medical education game called MedRPG.
Given a player's search description, return a JSON array of matching study IDs.
Each entry in the list is: STUDY|id|name|modality|aliases
Return ONLY a raw JSON array of IDs, no markdown, no explanation.
Example output: ["ct_abdpel_with_without","us_appendix"]
If nothing matches, return [].
Available studies:
""" + ctx

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
	raw = raw.replace("```json", "").replace("```", "").strip_edges()

	var id_json := JSON.new()
	if id_json.parse(raw) != OK:
		desc_status_label.text = "Could not parse study list. Try rephrasing."
		return

	var ids = id_json.get_data()
	if not (ids is Array):
		desc_status_label.text = "No matches found."
		return

	desc_status_label.text = "%d result(s) found." % ids.size()

	var row_idx := 0
	for id_val in ids:
		var id_str: String = str(id_val)
		if study_lookup.has(id_str):
			var study: Dictionary = study_lookup[id_str]
			# Hide pediatric-only for adult cases
			if study.get("pediatric_only", false) and patient_age >= 18:
				continue
			desc_results_list.add_child(_make_result_row(study, row_idx))
			row_idx += 1


# ============================================================
# TAB: BROWSE MODALITIES (tree view, no search box)
# ============================================================
func _build_modality_tab() -> void:
	var tab := VBoxContainer.new()
	tab.name = "BrowseModalities"
	tab.add_theme_constant_override("separation", 6)
	tab_container.add_child(tab)
	tab_container.set_tab_title(tab_container.get_tab_count() - 1, "Browse Modalities")

	tab.add_child(_make_results_col_header())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab.add_child(scroll)

	browse_tree_list = VBoxContainer.new()
	browse_tree_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	browse_tree_list.add_theme_constant_override("separation", 2)
	scroll.add_child(browse_tree_list)


func _refresh_browse_tree() -> void:
	if not browse_tree_list:
		return
	for c in browse_tree_list.get_children():
		c.queue_free()
	_render_study_tree(browse_tree_list, "browse")


# ============================================================
# RESULT ROW — shared across all three tabs
# ============================================================
func _make_result_row(study: Dictionary, row_idx: int) -> Button:
	var study_id: String = study["id"]
	var modality: String = study.get("modality", "xray")
	var is_selected: bool = selected_study_ids.has(study_id)
	var bg_color := C_SELECTED if is_selected else (C_ROW_ALT if row_idx % 2 == 0 else C_PANEL)

	var row := Button.new()
	row.custom_minimum_size.y = 32
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.focus_mode = Control.FOCUS_NONE
	_style_btn_bg(row, bg_color)
	row.pressed.connect(_on_result_row_toggle.bind(study_id))

	var inner := HBoxContainer.new()
	inner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	inner.offset_left = 8
	inner.offset_right = -8
	inner.add_theme_constant_override("separation", 8)
	inner.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(inner)

	# Modality badge — color coded
	var badge_text: String = MODALITY_BADGE_TEXT.get(modality, modality.to_upper())
	var badge_color: Color = MODALITY_COLORS.get(modality, C_DIM)
	var badge_lbl := _make_label(badge_text, 10, badge_color)
	badge_lbl.custom_minimum_size.x = 62
	inner.add_child(badge_lbl)

	# Study name
	var name_text: String = study.get("name", study_id)
	# Inline contrast/stable hints next to name
	var hints: PackedStringArray = []
	if study.get("requires_iv_contrast", false):
		hints.append("IV contrast")
	if study.get("requires_oral_contrast", false):
		hints.append("oral contrast")
	var name_lbl := _make_label(name_text, 13)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_child(name_lbl)

	# Notes column — shows contrast/oral hints; empty for studies with none
	var notes_text: String = ""
	if not hints.is_empty():
		notes_text = ", ".join(hints)
	# Amber color for any row that has notes — these are clinically important
	# preconditions (need IV first, oral prep, etc) that should catch the eye.
	var notes_color: Color = C_WARN if notes_text != "" else C_DIM
	var notes_lbl := _make_label(notes_text, 10, notes_color)
	notes_lbl.custom_minimum_size.x = 240
	notes_lbl.clip_text = true
	inner.add_child(notes_lbl)

	# AP cost
	var ap_text := str(int(study.get("ap_cost", 1))) + " AP"
	var ap_lbl := _make_label(ap_text, 12, C_ACCENT)
	ap_lbl.custom_minimum_size.x = 50
	ap_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	inner.add_child(ap_lbl)

	# Selection indicator (right side)
	var sel_lbl := _make_label("✓ Added" if is_selected else "+ Add", 12,
			C_CHIP if is_selected else C_DIM)
	sel_lbl.custom_minimum_size.x = 70
	sel_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	sel_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(sel_lbl)

	return row


func _on_result_row_toggle(study_id: String) -> void:
	if selected_study_ids.has(study_id):
		selected_study_ids.erase(study_id)
		_refresh_all_lists()
		_refresh_selected_display()
		_refresh_ap_cost()
		_refresh_repeat_warning()
		_reset_confirm_mode()
		return

	# Adding — eligibility checks
	if not study_lookup.has(study_id):
		return
	var study: Dictionary = study_lookup[study_id]

	# Check 1: stability
	if study.get("requires_stable", false) and current_patient_state in unstable_states:
		_show_block_modal(
			"Patient Too Unstable",
			"Patient too unstable for [color=#%s]%s[/color].\n\n[color=#aaaaaa]They cannot lie still in the MRI scanner. Stabilize first or choose an alternative imaging modality.[/color]" % [
				_color_to_hex(MODALITY_COLORS.get(study.get("modality", "xray"), C_TEXT)),
				study.get("name", study_id)
			]
		)
		return

	# Check 2: IV contrast availability
	if study.get("requires_iv_contrast", false) and not patient_has_iv:
		_show_block_modal(
			"IV Access Required",
			"Cannot order [color=#%s]%s[/color].\n\n[color=#aaaaaa]This study requires IV contrast. Place IV access first using the Tx button.[/color]" % [
				_color_to_hex(MODALITY_COLORS.get(study.get("modality", "xray"), C_TEXT)),
				study.get("name", study_id)
			]
		)
		return

	# Passed — add
	selected_study_ids[study_id] = true
	_refresh_all_lists()
	_refresh_selected_display()
	_refresh_ap_cost()
	_refresh_repeat_warning()
	_reset_confirm_mode()


func _refresh_all_lists() -> void:
	_refresh_name_results(name_search_field.text if name_search_field else "")
	_refresh_browse_tree()


# ============================================================
# SELECTED DISPLAY
# ============================================================
func _refresh_selected_display() -> void:
	if not selected_flow:
		return
	for c in selected_flow.get_children():
		c.queue_free()

	if selected_study_ids.is_empty():
		selected_label.text = "Selected: none"
		order_btn.disabled = true
		ap_cost_label.text = "0 AP"
		ap_cost_label.add_theme_color_override("font_color", C_DIM)
		return

	var count := selected_study_ids.size()
	if count == 1:
		selected_label.text = "Selected: 1 study"
	else:
		selected_label.text = "Selected: %d studies" % count
	order_btn.disabled = false

	for study_id in selected_study_ids:
		var chip := _make_chip(study_id)
		selected_flow.add_child(chip)


func _make_chip(study_id: String) -> PanelContainer:
	# A chip is a small rounded pill containing the study name + AP cost + an × button.
	# Built as a PanelContainer so the colored background is a stylebox (not a child
	# node fighting for layout space inside the chip).
	var is_contrast := false
	var display_name := study_id
	var ap := 1
	if study_lookup.has(study_id):
		var s: Dictionary = study_lookup[study_id]
		display_name = s.get("name", study_id)
		ap = int(s.get("ap_cost", 1))
		is_contrast = bool(s.get("requires_iv_contrast", false))

	var chip := PanelContainer.new()
	# Amber background for IV-contrast studies, blue otherwise
	var bg_color: Color = C_CHIP_CONTRAST if is_contrast else C_CHIP
	var style := StyleBoxFlat.new()
	style.bg_color = bg_color
	style.set_corner_radius_all(4)
	style.content_margin_left = 8
	style.content_margin_right = 4
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	chip.add_theme_stylebox_override("panel", style)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 4)
	chip.add_child(hbox)

	var label_str := display_name + " (%d AP)" % ap
	if is_contrast:
		label_str += "  💉"
	# Build the label directly (not via _make_label) so we can disable clipping —
	# a chip should grow to fit its text, not clip it to zero width inside an HBox.
	var lbl := Label.new()
	lbl.text = label_str
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", C_TEXT)
	lbl.clip_text = false
	hbox.add_child(lbl)

	var remove_btn := _make_btn("×", 20)
	remove_btn.pressed.connect(_on_chip_remove.bind(study_id))
	hbox.add_child(remove_btn)

	return chip


func _on_chip_remove(study_id: String) -> void:
	selected_study_ids.erase(study_id)
	_refresh_selected_display()
	_refresh_ap_cost()
	_refresh_repeat_warning()
	_reset_confirm_mode()
	_refresh_all_lists()


func _on_clear_all_pressed() -> void:
	selected_study_ids.clear()
	_refresh_all_lists()
	_refresh_selected_display()
	_refresh_ap_cost()
	repeat_warning_label.visible = false
	_reset_confirm_mode()


# ============================================================
# AP COST CALCULATION
# ============================================================
func _refresh_ap_cost() -> void:
	var total := _get_total_ap()
	if total == 0:
		ap_cost_label.text = "0 AP"
		ap_cost_label.add_theme_color_override("font_color", C_DIM)
	else:
		ap_cost_label.text = "%d AP" % total
		ap_cost_label.add_theme_color_override("font_color", C_ACCENT)


func _get_total_ap() -> int:
	var total := 0
	for sid in selected_study_ids:
		if study_lookup.has(sid):
			total += int(study_lookup[sid].get("ap_cost", 1))
	return total


# ============================================================
# REPEAT WARNING
# ============================================================
func _refresh_repeat_warning() -> void:
	var repeats: PackedStringArray = []
	for sid in selected_study_ids:
		if ordered_studies_this_encounter.has(sid):
			var sname: String = study_lookup[sid].get("name", sid) if study_lookup.has(sid) else sid
			repeats.append(sname)

	if repeats.is_empty():
		repeat_warning_label.visible = false
	else:
		repeat_warning_label.text = "⚠  Already ordered this encounter: " + ", ".join(repeats) + "  — re-ordering will return updated findings if state has changed."
		repeat_warning_label.visible = true


# ============================================================
# ORDER FLOW
# ============================================================
func _on_order_btn_pressed() -> void:
	if selected_study_ids.is_empty():
		return

	if not confirm_mode:
		# Switch to confirm mode
		confirm_mode = true
		var total := _get_total_ap()
		order_btn.text = "✓  Confirm Order (%d AP)" % total
		_style_btn_bg(order_btn, C_CONFIRM)
		cancel_order_btn.visible = true
	else:
		# Already in confirm mode — check IV contrast first if needed
		var contrast_studies: Array = _selected_contrast_studies()
		if not contrast_studies.is_empty():
			_show_iv_contrast_modal(contrast_studies)
		else:
			_execute_order(false)


func _selected_contrast_studies() -> Array:
	var out: Array = []
	for sid in selected_study_ids:
		if study_lookup.has(sid) and study_lookup[sid].get("requires_iv_contrast", false):
			out.append(study_lookup[sid])
	return out


func _on_cancel_order_pressed() -> void:
	_reset_confirm_mode()


func _reset_confirm_mode() -> void:
	confirm_mode = false
	order_btn.text = "Order Selected  →"
	_style_btn_bg(order_btn, Color(0.18, 0.20, 0.28))
	cancel_order_btn.visible = false


func _execute_order(used_iv_contrast: bool) -> void:
	var total_ap := _get_total_ap()

	order_counter += 1
	var this_order_index := order_counter

	# Snapshot current time/turn from engine if available
	var this_elapsed := elapsed_seconds
	var this_turn := current_turn
	var engine = get_node_or_null("/root/ClinicalEncounter")
	if engine:
		if "elapsed_seconds" in engine:
			this_elapsed = engine.elapsed_seconds
		if "turn_count" in engine:
			this_turn = int(engine.turn_count)

	var new_orders: Array = []

	for sid in selected_study_ids:
		if not study_lookup.has(sid):
			continue
		var study: Dictionary = study_lookup[sid]

		var delay_seconds: float = float(study.get("result_delay_seconds", 30))
		# Oral contrast adds ~30 sec real-time
		if study.get("requires_oral_contrast", false):
			delay_seconds += 30.0
		var delay_turns: int = int(study.get("result_delay_turns", 1))

		var order_uid := "%s|%d|%d" % [sid, this_order_index, randi()]

		var entry: Dictionary = {
			"order_uid":          order_uid,
			"order_index":        this_order_index,
			"study_id":           sid,
			"study_name":         study.get("name", sid),
			"modality":           study.get("modality", "xray"),
			"used_iv_contrast":   used_iv_contrast and study.get("requires_iv_contrast", false),
			"used_oral_contrast": study.get("requires_oral_contrast", false),
			"ordered_at_seconds": this_elapsed,
			"ordered_at_turn":    this_turn,
			"ready_at_seconds":   this_elapsed + delay_seconds,
			"ready_at_turn":      this_turn + delay_turns,
			"status":              "pending",
			# Findings/impression filled in when resolved
			"findings":           "",
			"impression":         "",
			"is_abnormal":        false,
			"resolved_state":     "",
		}
		new_orders.append(entry)

		ordered_studies_this_encounter[sid] = true

	encounter_orders.append_array(new_orders)

	# Try resolving any that are immediately ready (e.g. dev mode w/ 0 delay).
	_resolve_ready_pending()

	# Emit to clinical_engine
	order_confirmed.emit(new_orders, total_ap, used_iv_contrast)

	# Reset selection
	selected_study_ids.clear()
	_refresh_selected_display()
	_refresh_ap_cost()
	repeat_warning_label.visible = false
	_reset_confirm_mode()

	# Show results immediately
	_refresh_results_view()
	_show_results_view()
	_refresh_see_results_btn()


# ============================================================
# IV CONTRAST CONFIRMATION MODAL
# ============================================================
func _show_iv_contrast_modal(contrast_studies: Array) -> void:
	if not modal_layer or not modal_content:
		return

	# Clear previous content (modal is reused for both this and block popups)
	for c in modal_content.get_children():
		c.queue_free()

	# Title
	var title := _make_label("💉  Confirm IV Contrast", 16)
	modal_content.add_child(title)

	# Body — list studies
	var body_lbl := RichTextLabel.new()
	body_lbl.bbcode_enabled = true
	body_lbl.fit_content = true
	body_lbl.scroll_active = false
	body_lbl.custom_minimum_size.x = 460
	body_lbl.add_theme_color_override("default_color", C_TEXT)
	body_lbl.add_theme_font_size_override("normal_font_size", 12)
	var list_md: String = "[color=#bbbbbb]The following studies will receive IV contrast:[/color]\n"
	for s in contrast_studies:
		var col: Color = MODALITY_COLORS.get(s.get("modality", "xray"), C_TEXT)
		list_md += "  • [color=#%s]%s[/color]\n" % [_color_to_hex(col), s.get("name", "")]
	body_lbl.text = list_md
	modal_content.add_child(body_lbl)

	# Safety warnings
	var warnings: PackedStringArray = []
	if patient_has_contrast_allergy:
		warnings.append("⚠  Documented contrast allergy — risk of anaphylaxis. Pre-medication recommended.")
	if patient_creatinine > 2.0:
		warnings.append("⚠  Creatinine %.1f mg/dL — risk of contrast-induced nephropathy." % patient_creatinine)

	if not warnings.is_empty():
		var warn_lbl := _make_label("\n".join(warnings), 12, C_DANGER)
		warn_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		warn_lbl.custom_minimum_size.x = 460
		modal_content.add_child(warn_lbl)

	# Buttons
	var btn_row := _make_hbox(8)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	var cancel := _make_btn("Cancel", 100)
	cancel.pressed.connect(_on_iv_contrast_cancel)
	btn_row.add_child(cancel)
	var confirm := _make_btn("Give Contrast", 140)
	_style_btn_bg(confirm, C_CONFIRM)
	confirm.pressed.connect(_on_iv_contrast_confirm)
	btn_row.add_child(confirm)
	modal_content.add_child(btn_row)

	modal_layer.visible = true
	confirm.grab_focus()


func _on_iv_contrast_confirm() -> void:
	_hide_modal()
	_execute_order(true)


func _on_iv_contrast_cancel() -> void:
	_hide_modal()
	# Stay in confirm mode so user can review / change selection


# ============================================================
# BLOCK MODAL — used for stability + IV-access blocks
# ============================================================
func _show_block_modal(title_text: String, body_bbcode: String) -> void:
	if not modal_layer or not modal_content:
		return

	for c in modal_content.get_children():
		c.queue_free()

	var title := _make_label("🚫  " + title_text, 16, C_DANGER)
	modal_content.add_child(title)

	var body := RichTextLabel.new()
	body.bbcode_enabled = true
	body.fit_content = true
	body.scroll_active = false
	body.custom_minimum_size.x = 460
	body.add_theme_color_override("default_color", C_TEXT)
	body.add_theme_font_size_override("normal_font_size", 13)
	body.text = body_bbcode
	modal_content.add_child(body)

	var btn_row := _make_hbox(8)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	var ok := _make_btn("OK", 100)
	_style_btn_bg(ok, C_CONFIRM)
	ok.pressed.connect(_hide_modal)
	btn_row.add_child(ok)
	modal_content.add_child(btn_row)

	modal_layer.visible = true
	ok.grab_focus()


func _build_modal_layer() -> void:
	modal_layer = Control.new()
	modal_layer.name = "ModalLayer"
	modal_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	modal_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	modal_layer.visible = false
	add_child(modal_layer)

	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	modal_layer.add_child(dim)

	var card := PanelContainer.new()
	card.name = "Card"
	card.custom_minimum_size = Vector2(520, 200)
	card.set_anchors_preset(Control.PRESET_CENTER)
	# Center within parent — anchors + offset by half size after layout
	card.anchor_left = 0.5
	card.anchor_top = 0.5
	card.anchor_right = 0.5
	card.anchor_bottom = 0.5
	card.offset_left = -260
	card.offset_top = -110
	card.offset_right = 260
	card.offset_bottom = 110
	_style_panel(card, C_PANEL)
	modal_layer.add_child(card)

	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 16)
	pad.add_theme_constant_override("margin_right", 16)
	pad.add_theme_constant_override("margin_top", 14)
	pad.add_theme_constant_override("margin_bottom", 14)
	card.add_child(pad)

	# Store direct reference to the content VBox so modal-show functions don't
	# have to walk the node tree to find it (which was buggy + brittle).
	modal_content = VBoxContainer.new()
	modal_content.name = "Content"
	modal_content.add_theme_constant_override("separation", 10)
	pad.add_child(modal_content)


func _hide_modal() -> void:
	if modal_layer:
		modal_layer.visible = false


# ============================================================
# PENDING RESOLUTION — runs every 1s while popup visible,
# also runs on open() and on results-view show.
# ============================================================
func _set_pending_tick_active(active: bool) -> void:
	if not pending_tick_timer:
		return
	if active:
		if pending_tick_timer.is_stopped():
			pending_tick_timer.start()
	else:
		pending_tick_timer.stop()


func _on_pending_tick() -> void:
	if not visible:
		return
	# Read fresh time/turn from engine
	var engine = get_node_or_null("/root/ClinicalEncounter")
	if engine:
		if "elapsed_seconds" in engine:
			elapsed_seconds = engine.elapsed_seconds
		if "turn_count" in engine:
			current_turn = int(engine.turn_count)
	var any_changed := _resolve_ready_pending()
	# Refresh results view if it's currently visible (for live countdowns)
	if results_view and results_view.visible:
		_refresh_results_view()
	if any_changed:
		_refresh_see_results_btn()


# Returns true if at least one pending order was resolved.
func _resolve_ready_pending() -> bool:
	var changed := false
	for entry in encounter_orders:
		if entry.get("status", "ready") != "pending":
			continue
		var ready_s: float = float(entry.get("ready_at_seconds", 0.0))
		var ready_t: int = int(entry.get("ready_at_turn", 0))
		if elapsed_seconds >= ready_s and current_turn >= ready_t:
			_resolve_pending_entry(entry)
			changed = true
	return changed


# Mutates the entry dict in place.
func _resolve_pending_entry(entry: Dictionary) -> void:
	var sid: String = entry.get("study_id", "")
	var state := current_patient_state
	var result := _generate_result_text(sid, state)

	entry["status"] = "ready"
	entry["findings"] = result.get("findings", "")
	entry["impression"] = result.get("impression", "")
	entry["is_abnormal"] = bool(result.get("is_abnormal", false))
	entry["resolved_state"] = state
	entry["resolved_at_seconds"] = elapsed_seconds
	entry["resolved_at_turn"] = current_turn


# Generates findings/impression text for a study at a given patient state.
# Uses cache; falls back to "Normal study" template if no condition entry exists.
func _generate_result_text(study_id: String, state: String) -> Dictionary:
	var cache_key := study_id + "|" + state
	if result_cache.has(cache_key):
		return result_cache[cache_key]

	var ranges: Dictionary = condition_imaging_data.get("result_ranges", {})
	var result: Dictionary = {}
	if ranges.has(study_id) and ranges[study_id].has(state):
		var raw: Dictionary = ranges[study_id][state]
		result = {
			"findings":    raw.get("findings", ""),
			"impression":  raw.get("impression", ""),
			"is_abnormal": bool(raw.get("is_abnormal", false)),
		}
	else:
		# Fallback — modality-aware "normal study" template
		result = _fallback_result(study_id)

	result_cache[cache_key] = result
	return result


func _fallback_result(study_id: String) -> Dictionary:
	var modality := "xray"
	if study_lookup.has(study_id):
		modality = study_lookup[study_id].get("modality", "xray")

	var findings := "Examination performed without acute abnormality. No findings to suggest the suspected pathology within the imaged region. Adjacent visualized structures are unremarkable."
	var impression := "No acute findings."
	match modality:
		"xray":
			findings = "No acute fracture, dislocation, or significant osseous abnormality. Soft tissues unremarkable. No radiopaque foreign body."
			impression = "Negative study."
		"ultrasound":
			findings = "Imaged structures appear within normal limits. No focal abnormality, free fluid, or mass-like lesion identified."
			impression = "Negative ultrasound."
		"ct":
			findings = "No acute abnormality identified. Visualized organs are within normal limits without mass, hemorrhage, or focal fluid collection. No free air."
			impression = "Negative CT."
		"cta":
			findings = "Vasculature opacifies normally without evidence of occlusion, dissection, aneurysm, or filling defect. No vascular abnormality identified."
			impression = "Negative CTA."
		"mri":
			findings = "No acute signal abnormality. Visualized structures are within normal limits. No mass, hemorrhage, or restricted diffusion."
			impression = "Negative MRI."
		"mra":
			findings = "Vasculature appears patent without flow-limiting stenosis, occlusion, or aneurysm. No vascular abnormality identified."
			impression = "Negative MRA."
		"nuclear":
			findings = "No abnormal uptake or perfusion defect. Distribution within physiologic limits."
			impression = "Negative scan."
		"fluoroscopy":
			findings = "Normal anatomy and motion observed throughout the study. No structural abnormality, leak, or obstruction."
			impression = "Negative study."

	return {
		"findings":    findings,
		"impression":  impression,
		"is_abnormal": false,
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

	var title := _make_label("📋  Imaging Results — This Encounter", 16)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.add_child(title)

	sort_name_btn = _make_btn("Sort: A-Z", 90)
	sort_name_btn.pressed.connect(_on_sort_name)
	hdr.add_child(sort_name_btn)

	sort_time_btn = _make_btn("Sort: Newest", 100)
	sort_time_btn.pressed.connect(_on_sort_time)
	sort_time_btn.disabled = true  # default
	hdr.add_child(sort_time_btn)

	var back_btn := _make_btn("← Back to Order", 130)
	back_btn.pressed.connect(_on_back_from_results)
	hdr.add_child(back_btn)

	var close_r := _make_btn("✕", 30)
	close_r.pressed.connect(_on_close_pressed)
	hdr.add_child(close_r)

	vbox.add_child(hdr)

	# Column header
	var col_hdr := _make_hbox(8)
	col_hdr.custom_minimum_size.y = 24
	_bg_rect(col_hdr, C_HEADER)
	var lpad := Control.new()
	lpad.custom_minimum_size.x = 8
	col_hdr.add_child(lpad)
	col_hdr.add_child(_make_col_header("", 22))
	col_hdr.add_child(_make_col_header("Modality", 80))
	var name_hdr := _make_col_header("Study", 0)
	name_hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col_hdr.add_child(name_hdr)
	col_hdr.add_child(_make_col_header("Status", 200))
	col_hdr.add_child(_make_col_header("Time", 120))
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
	if min_w > 0:
		l.custom_minimum_size.x = min_w
	return l


func _refresh_results_view() -> void:
	if not results_list:
		return
	for c in results_list.get_children():
		c.queue_free()

	if encounter_orders.is_empty():
		results_list.add_child(_make_label("No imaging ordered yet.", 14, C_DIM))
		return

	# Sort — flat list, one row per ordered study (no panel grouping).
	var sorted: Array = encounter_orders.duplicate()
	if sort_mode == "name":
		sorted.sort_custom(func(a, b): return a.get("study_name", "") < b.get("study_name", ""))
	else:
		sorted.sort_custom(func(a, b):
			# Newest first
			var ai = int(a.get("order_index", 0))
			var bi = int(b.get("order_index", 0))
			if ai != bi:
				return ai > bi
			return float(a.get("ordered_at_seconds", 0.0)) > float(b.get("ordered_at_seconds", 0.0))
		)

	for entry in sorted:
		results_list.add_child(_make_order_row(entry))


# Single-level expansion: each ordered study is one row that expands to show findings.
func _make_order_row(entry: Dictionary) -> VBoxContainer:
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 0)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var uid: String = entry.get("order_uid", "")
	var status: String = entry.get("status", "pending")
	var modality: String = entry.get("modality", "xray")
	var study_name: String = entry.get("study_name", "—")
	var is_abn: bool = bool(entry.get("is_abnormal", false))
	var ordered_s: float = float(entry.get("ordered_at_seconds", 0.0))
	var ready_s: float = float(entry.get("ready_at_seconds", 0.0))
	var ready_t: int = int(entry.get("ready_at_turn", 0))

	var is_expanded: bool = expanded_orders.get(uid, false)
	# Pending rows can't expand — disable expand for pending
	var can_expand := (status == "ready")

	# --- Header row (clickable) ---
	var header := Button.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.custom_minimum_size.y = 36
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_style_btn_bg(header, C_HEADER if not is_expanded else Color(C_HEADER.r + 0.04, C_HEADER.g + 0.04, C_HEADER.b + 0.05))
	if can_expand:
		var captured_uid := uid
		header.pressed.connect(func():
			expanded_orders[captured_uid] = not expanded_orders.get(captured_uid, false)
			_refresh_results_view()
		)
	else:
		header.focus_mode = Control.FOCUS_NONE
		header.disabled = false  # leave clickable but no-op
	vbox.add_child(header)

	# Header inner layout
	var inner := HBoxContainer.new()
	inner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	inner.offset_left = 8
	inner.offset_right = -8
	inner.add_theme_constant_override("separation", 8)
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(inner)

	# Expand chevron
	var chev_text := "  "
	if can_expand:
		chev_text = "▼" if is_expanded else "▶"
	var chev := _make_label(chev_text, 11, C_DIM)
	chev.custom_minimum_size.x = 22
	inner.add_child(chev)

	# Modality badge
	var badge_text: String = MODALITY_BADGE_TEXT.get(modality, modality.to_upper())
	var badge_color: Color = MODALITY_COLORS.get(modality, C_DIM)
	var badge := _make_label(badge_text, 11, badge_color)
	badge.custom_minimum_size.x = 80
	inner.add_child(badge)

	# Study name + abnormal flag inline
	var name_txt := study_name
	if status == "ready" and is_abn:
		name_txt += "   🔴"
	var name_lbl := _make_label(name_txt, 13, C_TEXT)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_child(name_lbl)

	# Status column
	var status_text := ""
	var status_color := C_DIM
	if status == "pending":
		var sec_left: float = max(0.0, ready_s - elapsed_seconds)
		var turn_left: int = max(0, ready_t - current_turn)
		status_text = "⏳ Pending — %s left" % _format_pending_remaining(turn_left, sec_left)
		status_color = C_PENDING
	else:
		status_text = "Abnormal" if is_abn else "Normal"
		status_color = C_ABNORMAL if is_abn else C_NORMAL
	var status_lbl := _make_label(status_text, 12, status_color)
	status_lbl.custom_minimum_size.x = 200
	inner.add_child(status_lbl)

	# Time column
	var time_lbl := _make_label(_format_timestamp(ordered_s), 11, C_DIM)
	time_lbl.custom_minimum_size.x = 120
	inner.add_child(time_lbl)

	# --- Body (findings + impression) — only when expanded + ready ---
	if can_expand and is_expanded:
		var body := PanelContainer.new()
		_style_panel(body, Color(C_PANEL.r + 0.02, C_PANEL.g + 0.02, C_PANEL.b + 0.03))
		var pad := MarginContainer.new()
		pad.add_theme_constant_override("margin_left", 18)
		pad.add_theme_constant_override("margin_right", 18)
		pad.add_theme_constant_override("margin_top", 12)
		pad.add_theme_constant_override("margin_bottom", 12)
		body.add_child(pad)

		var bv := VBoxContainer.new()
		bv.add_theme_constant_override("separation", 10)
		pad.add_child(bv)

		# Contrast / oral notation
		var notes: PackedStringArray = []
		if entry.get("used_iv_contrast", false):
			notes.append("IV contrast administered")
		if entry.get("used_oral_contrast", false):
			notes.append("Oral contrast administered")
		if not notes.is_empty():
			var notes_lbl := _make_label(" • ".join(notes), 11, C_DIM)
			bv.add_child(notes_lbl)

		# FINDINGS
		var f_hdr := _make_label("FINDINGS", 11, C_ACCENT)
		bv.add_child(f_hdr)
		var f_body := Label.new()
		f_body.text = entry.get("findings", "")
		f_body.add_theme_font_size_override("font_size", 12)
		f_body.add_theme_color_override("font_color", C_TEXT)
		f_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		bv.add_child(f_body)

		# IMPRESSION
		var i_hdr := _make_label("IMPRESSION", 11, C_ACCENT)
		bv.add_child(i_hdr)
		var i_body := Label.new()
		i_body.text = entry.get("impression", "")
		i_body.add_theme_font_size_override("font_size", 13)
		i_body.add_theme_color_override("font_color", C_ABNORMAL if is_abn else C_TEXT)
		i_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		bv.add_child(i_body)

		vbox.add_child(body)

	return vbox


func _format_pending_remaining(turns_left: int, secs_left: float) -> String:
	# Show whichever is more restrictive (the larger remaining quantity blocks resolution).
	# Format both pieces for player clarity.
	var t_str := ""
	if turns_left > 0:
		t_str = "%d turn%s" % [turns_left, "" if turns_left == 1 else "s"]
	var s_str := ""
	if secs_left > 0.0:
		var s_int := int(ceil(secs_left))
		if s_int >= 60:
			var m := s_int / 60
			var rem := s_int % 60
			s_str = "%d:%02d" % [m, rem] if rem != 0 else "%d min" % m
		else:
			s_str = "%ds" % s_int

	if t_str != "" and s_str != "":
		return "%s / %s" % [t_str, s_str]
	elif t_str != "":
		return t_str
	elif s_str != "":
		return s_str
	else:
		return "ready"


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
	_resolve_ready_pending()
	_refresh_results_view()
	results_view.visible = true


func _on_back_from_results() -> void:
	results_view.visible = false


func _on_see_results_pressed() -> void:
	_show_results_view()


func _refresh_see_results_btn() -> void:
	if not see_results_btn:
		return
	var total := encounter_orders.size()
	var pending := 0
	for e in encounter_orders:
		if e.get("status", "ready") == "pending":
			pending += 1
	if pending > 0:
		see_results_btn.text = "📋  See Results (%d  •  %d ⏳)" % [total, pending]
	else:
		see_results_btn.text = "📋  See Results (%d)" % total


# ============================================================
# CLOSE
# ============================================================
func _on_close_pressed() -> void:
	# Hide modal first if open, then close popup
	if modal_layer and modal_layer.visible:
		_hide_modal()
		return
	visible = false
	_set_pending_tick_active(false)
	popup_closed.emit()


# ============================================================
# INPUT — Escape key handling
# ============================================================
func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if modal_layer and modal_layer.visible:
			_hide_modal()
		elif results_view and results_view.visible:
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
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(3)
	if parent is PanelContainer:
		parent.add_theme_stylebox_override("panel", style)
	elif parent is Button:
		parent.add_theme_stylebox_override("normal", style)
	else:
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


func _color_to_hex(c: Color) -> String:
	# Returns "RRGGBB" — used inside [color=#...] BBCode
	var r := int(round(c.r * 255.0))
	var g := int(round(c.g * 255.0))
	var b := int(round(c.b * 255.0))
	return "%02x%02x%02x" % [r, g, b]
