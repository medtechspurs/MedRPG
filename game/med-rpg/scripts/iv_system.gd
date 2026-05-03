# iv_system.gd
# Attach to a Control node (full rect) in iv_popup.tscn.
# Add iv_popup.tscn as a child of clinical_encounter.tscn's PopupLayer node
# (visible = false by default).
#
# Mirrors imaging_system.gd / labs_system.gd architecture, but much simpler:
#   - Single tab (no Search/Browse/MEDDY)
#   - 6 fixed sites (right_hand, left_hand, right_ac, left_ac, right_foot, left_foot)
#   - Each row shows current state and a Place / Remove button
#   - Mini-game is stubbed via _attempt_iv_placement (currently always succeeds)
#   - 1 AP charged on every placement attempt (success OR failure)

extends Control

# ============================================================
# SIGNALS
# ============================================================
signal iv_placed(site: String, success: bool, used_ap: int)
signal iv_removed(site: String)
signal popup_closed

# ============================================================
# STATE — passed in by clinical_engine on open()
# ============================================================
# iv_sites: Dictionary { site_id -> null OR Dictionary{...IV record...} }
# Engine owns the canonical state; popup mutates via signals only.
var iv_sites: Dictionary = {}
var available_ap: int = 0
var elapsed_seconds: float = 0.0
var current_turn: int = 0

# ============================================================
# UI REFERENCES (built in _ready)
# ============================================================
var main_panel: PanelContainer
var rows_vbox: VBoxContainer
var row_widgets: Dictionary = {}   # site_id -> Dictionary {row_panel, status_label, action_button}

# Confirmation modal — shown before placing or removing an IV
var modal_layer: Control
var modal_content: VBoxContainer
var modal_title: Label
var modal_body: Label
var modal_confirm_btn: Button
var modal_cancel_btn: Button
# What action the modal will perform if confirmed: "place" or "remove"
var modal_pending_action: String = ""
var modal_pending_site: String = ""

# ============================================================
# COLORS & STYLE — match imaging/labs palette so popups feel consistent
# ============================================================
const C_PANEL     = Color(0.10, 0.12, 0.16)
const C_HEADER    = Color(0.13, 0.15, 0.21)
const C_ROW_ALT   = Color(0.12, 0.14, 0.18)
const C_TEXT      = Color(0.90, 0.92, 0.95)
const C_DIM       = Color(0.55, 0.58, 0.65)
const C_ACCENT    = Color(0.25, 0.55, 0.90)
const C_GOOD      = Color(0.25, 0.70, 0.40)
const C_DANGER    = Color(0.90, 0.30, 0.30)
const C_WARN      = Color(0.90, 0.70, 0.20)
const C_CONFIRM   = Color(0.20, 0.65, 0.30)

# ============================================================
# SITE CATALOG — display order matches clinical priority:
# AC sites first (preferred for power injection), then hands, then feet.
# Within each pair, left first then right.
# ============================================================
const SITE_ORDER: Array = [
	"left_ac",     "right_ac",
	"left_hand",   "right_hand",
	"left_foot",   "right_foot",
]

const SITE_DISPLAY_NAMES: Dictionary = {
	"left_ac":     "Left AC (antecubital)",
	"right_ac":    "Right AC (antecubital)",
	"left_hand":   "Left Hand",
	"right_hand":  "Right Hand",
	"left_foot":   "Left Foot",
	"right_foot":  "Right Foot",
}

const AP_PER_PLACEMENT: int = 1

# ============================================================
# ENTRY POINT — called by clinical_engine each time the popup opens
# ============================================================
func open(current_iv_sites: Dictionary, ap_available: int,
		elapsed: float, turn: int) -> void:
	iv_sites = current_iv_sites
	available_ap = ap_available
	elapsed_seconds = elapsed
	current_turn = turn

	visible = true
	_center_panel()
	_refresh_rows()


func _center_panel() -> void:
	# Delegates to shared popup layout helper.
	PopupLayout.apply_layout(main_panel, "iv")


# ============================================================
# _READY — build the UI once
# ============================================================
func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Main panel
	main_panel = PanelContainer.new()
	_style_panel(main_panel, C_PANEL)
	add_child(main_panel)

	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 6)
	main_panel.add_child(root_vbox)

	# --- Title bar ---
	var title_bar := _make_hbox(8)
	title_bar.custom_minimum_size.y = 38
	_bg_rect_panel(title_bar, C_HEADER)
	var title_lbl := _make_label("💉  Place IV Access", 17)
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_bar.add_child(title_lbl)
	var close_btn := _make_btn("✕", 30)
	close_btn.pressed.connect(_on_close_pressed)
	title_bar.add_child(close_btn)
	root_vbox.add_child(title_bar)

	# --- Subheading explaining the cost ---
	var info_row := _make_hbox(8)
	info_row.custom_minimum_size.y = 24
	var info_lbl := _make_label("Cost Per Attempt: %d AP" % AP_PER_PLACEMENT, 11, C_DIM)
	info_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_row.add_child(info_lbl)
	root_vbox.add_child(info_row)

	# --- Site rows ---
	var rows_scroll := ScrollContainer.new()
	rows_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rows_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	rows_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	root_vbox.add_child(rows_scroll)

	rows_vbox = VBoxContainer.new()
	rows_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows_vbox.add_theme_constant_override("separation", 4)
	rows_scroll.add_child(rows_vbox)

	# Pre-build the 6 rows once. We'll just update their state on each open.
	for i in SITE_ORDER.size():
		var sid: String = SITE_ORDER[i]
		var row_widget := _build_site_row(sid, i)
		rows_vbox.add_child(row_widget["row"])
		row_widgets[sid] = row_widget

	# --- Bottom bar ---
	var bottom := _make_hbox(8)
	_bg_rect_panel(bottom, C_HEADER)
	bottom.custom_minimum_size.y = 38
	var summary_lbl := _make_label("", 12, C_DIM)
	summary_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	summary_lbl.name = "SummaryLabel"  # for easy lookup in _refresh_rows
	bottom.add_child(summary_lbl)
	var done_btn := _make_btn("Close", 100)
	done_btn.pressed.connect(_on_close_pressed)
	bottom.add_child(done_btn)
	root_vbox.add_child(bottom)

	# Build the confirmation modal (hidden by default, shown when user clicks
	# Place IV or Remove on any site row)
	_build_modal_layer()

	visible = false


# ============================================================
# Build a single site row. Stored widgets are reused across opens.
# ============================================================
func _build_site_row(site_id: String, row_idx: int) -> Dictionary:
	var row_bg: Color = C_ROW_ALT if row_idx % 2 == 0 else C_PANEL

	var row := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = row_bg
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	row.add_theme_stylebox_override("panel", sb)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var inner := HBoxContainer.new()
	inner.add_theme_constant_override("separation", 10)
	row.add_child(inner)

	# Site name
	var name_lbl := _make_label(SITE_DISPLAY_NAMES[site_id], 13, C_TEXT)
	name_lbl.custom_minimum_size.x = 200
	inner.add_child(name_lbl)

	# Status text — updated each refresh
	var status_lbl := _make_label("", 12, C_DIM)
	status_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_child(status_lbl)

	# Action button — Place / Remove, swapped each refresh
	var action_btn := _make_btn("Place IV  (1 AP)", 150)
	# Single handler dispatches based on current state of the site, so we don't
	# need to disconnect/reconnect on every refresh.
	action_btn.pressed.connect(_on_row_action.bind(site_id))
	inner.add_child(action_btn)

	return {
		"row": row,
		"name_lbl": name_lbl,
		"status_lbl": status_lbl,
		"action_btn": action_btn,
		"site_id": site_id,
	}


# ============================================================
# Refresh row visuals based on current iv_sites state
# ============================================================
func _refresh_rows() -> void:
	for sid in SITE_ORDER:
		var w: Dictionary = row_widgets[sid]
		var record = iv_sites.get(sid, null)
		var status_lbl: Label = w["status_lbl"]
		var action_btn: Button = w["action_btn"]

		if record == null:
			# No IV — show Place button
			status_lbl.text = "(no IV)"
			status_lbl.add_theme_color_override("font_color", C_DIM)
			action_btn.text = "Place IV  (%d AP)" % AP_PER_PLACEMENT
			action_btn.disabled = (available_ap < AP_PER_PLACEMENT)
		elif bool(record.get("extravasated", false)):
			# IV present but extravasated — red status, Remove button
			status_lbl.text = "✗ Extravasated — recommend removal"
			status_lbl.add_theme_color_override("font_color", C_DANGER)
			action_btn.text = "Remove"
			action_btn.disabled = false
		else:
			# IV present and healthy — green status, Remove button
			status_lbl.text = "✓ IV in place"
			status_lbl.add_theme_color_override("font_color", C_GOOD)
			action_btn.text = "Remove"
			action_btn.disabled = false

	# Update bottom summary
	_refresh_summary()


# Single dispatcher for any site row's action button. Shows a confirmation
# modal; the actual place/remove only happens after the user clicks Confirm.
func _on_row_action(site_id: String) -> void:
	var record = iv_sites.get(site_id, null)
	if record == null:
		_show_confirm_modal("place", site_id)
	else:
		_show_confirm_modal("remove", site_id)


func _refresh_summary() -> void:
	var summary: Label = main_panel.find_child("SummaryLabel", true, false)
	if not summary:
		return
	var count: int = 0
	for sid in SITE_ORDER:
		if iv_sites.get(sid, null) != null:
			count += 1
	if count == 0:
		summary.text = "No IV access."
	elif count == 1:
		summary.text = "1 IV in place."
	else:
		summary.text = "%d IVs in place." % count


# ============================================================
# Button handlers
# ============================================================
func _attempt_place(site_id: String) -> void:
	# Charge AP up front (before mini-game). Success/failure goes through the
	# placement attempt below; either way the AP is gone.
	available_ap -= AP_PER_PLACEMENT

	# --- Mini-game stub ---
	# Real mini-game will replace this. Always returns success for now.
	# Engine will read the result via the iv_placed signal payload.
	var result: Dictionary = _attempt_iv_placement(site_id, [])

	iv_placed.emit(site_id, bool(result.get("success", false)), AP_PER_PLACEMENT)

	# Note: the engine is the source of truth for iv_sites; we wait for the
	# engine to update the dict and then re-read it. But we don't have a
	# round-trip here — the engine modifies the dict directly (we hold the
	# same reference), so refresh immediately.
	_refresh_rows()


func _remove_iv(site_id: String) -> void:
	iv_removed.emit(site_id)
	_refresh_rows()


# ============================================================
# CONFIRMATION MODAL — shown before placing or removing an IV
# ============================================================
func _build_modal_layer() -> void:
	modal_layer = Control.new()
	modal_layer.name = "ModalLayer"
	modal_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	modal_layer.mouse_filter = Control.MOUSE_FILTER_STOP
	modal_layer.visible = false
	add_child(modal_layer)

	# Dim background that catches clicks (so user can't interact with the popup
	# behind the modal while it's open)
	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	modal_layer.add_child(dim)

	# Card — centered fixed-size panel
	var card := PanelContainer.new()
	card.anchor_left = 0.5
	card.anchor_top = 0.5
	card.anchor_right = 0.5
	card.anchor_bottom = 0.5
	card.offset_left = -200
	card.offset_top = -90
	card.offset_right = 200
	card.offset_bottom = 90
	_style_panel(card, C_PANEL)
	modal_layer.add_child(card)

	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 16)
	pad.add_theme_constant_override("margin_right", 16)
	pad.add_theme_constant_override("margin_top", 14)
	pad.add_theme_constant_override("margin_bottom", 14)
	card.add_child(pad)

	modal_content = VBoxContainer.new()
	modal_content.add_theme_constant_override("separation", 10)
	pad.add_child(modal_content)

	modal_title = _make_label("", 16, C_TEXT)
	modal_content.add_child(modal_title)

	modal_body = _make_label("", 12, C_DIM)
	modal_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	modal_content.add_child(modal_body)

	# Spacer so buttons sit at the bottom
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	modal_content.add_child(spacer)

	var btn_row := _make_hbox(8)
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	# Confirm on the left, Cancel on the right
	modal_confirm_btn = _make_btn("Confirm", 100)
	_style_btn_bg(modal_confirm_btn, C_CONFIRM)
	modal_confirm_btn.pressed.connect(_on_modal_confirm)
	btn_row.add_child(modal_confirm_btn)
	modal_cancel_btn = _make_btn("Cancel", 100)
	modal_cancel_btn.pressed.connect(_on_modal_cancel)
	btn_row.add_child(modal_cancel_btn)
	modal_content.add_child(btn_row)


# Show the modal asking the user to confirm a place or remove action.
# action: "place" or "remove"
func _show_confirm_modal(action: String, site_id: String) -> void:
	if not modal_layer:
		return
	modal_pending_action = action
	modal_pending_site = site_id
	var site_name: String = SITE_DISPLAY_NAMES.get(site_id, site_id)

	if action == "place":
		modal_title.text = "Place IV in %s?" % site_name
		modal_body.text = "Cost Per Attempt: %d AP" % AP_PER_PLACEMENT
	elif action == "remove":
		modal_title.text = "Remove IV from %s?" % site_name
		modal_body.text = "No AP cost. The IV catheter will be removed."
	else:
		return

	modal_layer.visible = true
	modal_confirm_btn.grab_focus()


func _hide_modal() -> void:
	if modal_layer:
		modal_layer.visible = false
	modal_pending_action = ""
	modal_pending_site = ""


func _on_modal_confirm() -> void:
	var action := modal_pending_action
	var site := modal_pending_site
	_hide_modal()
	match action:
		"place":  _attempt_place(site)
		"remove": _remove_iv(site)


func _on_modal_cancel() -> void:
	_hide_modal()


# ============================================================
# Mini-game placeholder
# ============================================================
# Returns { "success": bool, "extravasation": bool, "notes": String }
#
# Currently always succeeds. When the real mini-game ships, replace the body
# of this function with a call into the mini-game scene that returns a result
# Dictionary in the same shape.
#
# `harm_modifiers` will be a list of strings like ["dehydrated", "obese"] that
# decrease success probability — Stage D will define and pass these.
func _attempt_iv_placement(_site_id: String, _harm_modifiers: Array) -> Dictionary:
	return {
		"success": true,
		"extravasation": false,
		"notes": "",
	}


# ============================================================
# Close handling
# ============================================================
func _on_close_pressed() -> void:
	visible = false
	popup_closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		# If the confirmation modal is open, dismiss the modal instead of
		# closing the whole popup
		if modal_layer and modal_layer.visible:
			_on_modal_cancel()
		else:
			_on_close_pressed()
		get_viewport().set_input_as_handled()


# ============================================================
# UI HELPERS
# ============================================================
func _make_label(text: String, font_size: int = 13, color: Color = C_TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
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


func _style_panel(panel: Control, color: Color) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", style)


# Apply a colored background + hover state to a Button.
func _style_btn_bg(btn: Button, color: Color) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(3)
	btn.add_theme_stylebox_override("normal", style)
	var hover := StyleBoxFlat.new()
	hover.bg_color = Color(color.r + 0.08, color.g + 0.08, color.b + 0.08)
	hover.set_corner_radius_all(3)
	btn.add_theme_stylebox_override("hover", hover)


# Apply a colored background to a non-Container Control by wrapping it with a
# StyleBoxFlat. Used for header / footer rows in the popup.
func _bg_rect_panel(parent: Control, color: Color) -> void:
	# For HBoxContainer parents we can't directly add a stylebox, so wrap in
	# a PanelContainer-like effect via a child ColorRect at z=-1.
	var cr := ColorRect.new()
	cr.color = color
	cr.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cr.z_index = -1
	parent.add_child(cr)
	parent.move_child(cr, 0)
