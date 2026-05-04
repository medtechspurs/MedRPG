# Engine Integration — Medications Popup (Session 30)

This document covers what to change in `clinical_engine.gd` to wire up the new medications popup. Five edits in order. Each block tells you what to find and what to add.

After all five edits, you'll also need to create the scene file `medications_popup.tscn` in the Godot editor — instructions at the bottom.

---

## EDIT 1 — Add new state variables (top of file, with the other `var` declarations)

**Find** the section near the top where popups are declared (around line 115-124, where `labs_popup` and `imaging_popup` are):

```gdscript
var labs_popup: Control = null
```

**Add immediately after the existing popup vars** (so all popup references live together):

```gdscript
var medications_popup: Control = null

# Medications state
var master_medications_data: Dictionary = {}   # full master_medications.json
var medications_given: Array = []              # log of what's been ordered: [{canonical_id, route, ap_spent, turn_given}]
var anaphylaxis_triggered: bool = false        # set when player overrides allergy warning; state machine deferred
```

---

## EDIT 2 — Load `master_medications.json` (inside `load_condition_data()`)

**Find** the block that loads `master_imaging.json` (around line 190):

```gdscript
	var imaging_file = FileAccess.open("res://data/imaging/master_imaging.json", FileAccess.READ)
	if imaging_file:
		var imaging_json := JSON.new()
		imaging_json.parse(imaging_file.get_as_text())
		master_imaging_data = imaging_json.get_data()
		imaging_file.close()
		print("master_imaging.json loaded OK")
	else:
		print("ERROR: Could not load master_imaging.json")
```

**Add immediately after** (before the `appendicitis_imaging.json` block):

```gdscript
	# Load master medications catalog
	var meds_file = FileAccess.open("res://data/medications/master_medications.json", FileAccess.READ)
	if meds_file:
		var meds_json := JSON.new()
		meds_json.parse(meds_file.get_as_text())
		master_medications_data = meds_json.get_data()
		meds_file.close()
		print("master_medications.json loaded OK")
	else:
		print("ERROR: Could not load master_medications.json")
```

---

## EDIT 3 — Wire the popup in `_ready()`

**Find** the IV popup wire-up block (around line 152):

```gdscript
# Wire IV popup
	iv_popup = $PopupLayer/IVPopup
	iv_popup.iv_placed.connect(_on_iv_placed)
	iv_popup.iv_removed.connect(_on_iv_removed)
	iv_popup.popup_closed.connect(_on_iv_popup_closed)
```

**Add immediately after**:

```gdscript
# Wire medications popup
	medications_popup = $PopupLayer/MedicationsPopup
	medications_popup.medication_ordered.connect(_on_medication_ordered)
	medications_popup.allergy_warning_shown.connect(_on_medication_allergy_warning)
	medications_popup.anaphylaxis_triggered_signal.connect(_on_anaphylaxis_triggered)
	medications_popup.popup_closed.connect(_on_medications_popup_closed)
```

---

## EDIT 4 — Replace `_on_meds_btn_pressed()` body

**Find** the existing function (around line 702):

```gdscript
func _on_meds_btn_pressed() -> void:
	current_mode = "medications"
	$InputArea/InputPanel/InputRow/InputField.placeholder_text = "Order a medication..."
	$InputArea/InputPanel/InputRow/InputField.grab_focus()
```

**Replace the entire function body** with:

```gdscript
func _on_meds_btn_pressed() -> void:
	if medications_popup == null:
		print("ERROR: medications_popup not wired")
		return
	if master_medications_data.is_empty():
		print("ERROR: master_medications_data not loaded")
		return
	$InputArea.visible = false
	medications_popup.open(
		master_medications_data.get("medications", []),
		condition_data.get("patient_allergies", []),
		medications_given,
		_get_vascular_access_points(),
		ap_current,
		system_prompts.get("system_prompts", {}).get("meddy_medication_filter", {}).get("prompt", "")
	)
```

---

## EDIT 5 — Add the medication signal handlers + the vascular-access helper

**Add at the bottom of the file** (after the last existing function):

```gdscript
# ============================================================
# MEDICATIONS POPUP HANDLERS
# ============================================================
func _on_medication_ordered(canonical_id: String, route: String, ap_spent: int) -> void:
	if not spend_ap(ap_spent):
		print("Medication order failed — insufficient AP")
		return
	medications_given.append({
		"canonical_id": canonical_id,
		"route": route,
		"ap_spent": ap_spent,
		"turn_given": turn_count,
	})
	print("Medication ordered: %s via %s (%d AP)" % [canonical_id, route, ap_spent])
	# Future: apply clinical effects (antibiotic stops sepsis progression, etc.) — not in v1


func _on_medication_allergy_warning(canonical_id: String, allergy_class: String) -> void:
	# 1 harm point for hitting the warning at all
	add_harm_point("Attempted to order %s despite documented %s allergy" % [canonical_id, allergy_class])


func _on_anaphylaxis_triggered(canonical_id: String) -> void:
	# Additional harm point for proceeding through warning
	add_harm_point("Proceeded with %s after allergy warning — anaphylaxis triggered" % canonical_id)
	anaphylaxis_triggered = true
	print("ANAPHYLAXIS TRIGGERED — flag set; state machine deferred")
	# Future: transition to anaphylaxis state (respiratory distress → shock → arrest progression)


func _on_medications_popup_closed() -> void:
	$InputArea.visible = true


# Returns array of dicts representing currently-usable vascular access points.
# Used by medications popup route picker. Forward-compatible: when IO and central
# line ship, append those entries to the returned array.
func _get_vascular_access_points() -> Array:
	var points: Array = []
	# Display name lookup mirrors iv_system.gd SITE_DISPLAY_NAMES
	var site_names: Dictionary = {
		"left_ac":     "L AC",
		"right_ac":    "R AC",
		"left_hand":   "L Hand",
		"right_hand":  "R Hand",
		"left_foot":   "L Foot",
		"right_foot":  "R Foot",
	}
	for site_id in iv_sites.keys():
		var record = iv_sites.get(site_id, null)
		if record == null:
			continue
		if bool(record.get("extravasated", false)):
			continue
		points.append({
			"site_id": site_id,
			"display_name": site_names.get(site_id, site_id),
		})
	return points
```

**IMPORTANT:** the signal handler uses `add_harm_point(reason)`. If the actual function in your engine has a different signature (e.g. takes `(amount, reason)` or `(reason, amount)`), adjust to match. Looking at PROJECT_NOTES line about line 359 in your engine, the function appears to be `add_harm_point(reason)` style, but please verify and tweak if needed.

---

## SCENE FILE — Create `medications_popup.tscn`

In the Godot editor, this is mechanically identical to how you made `iv_popup.tscn`:

1. **Scene → New Scene → User Interface (Control root)**
2. **Rename the root node to `MedicationsPopup`** (PascalCase, matches engine's `$PopupLayer/MedicationsPopup`)
3. **Set Layout → Anchors Preset → Full Rect**
4. **Set Visible = false** in the Inspector (default state — engine's `open()` sets it visible)
5. **Attach the script `medications_system.gd`** to the root node
6. **Save as `scenes/medications_popup.tscn`**

That's the entire scene. The script builds all UI programmatically — no child nodes needed, no exports to wire.

7. **Open `scenes/clinical_encounter.tscn`** (the main scene)
8. **Right-click the `PopupLayer` node → Instantiate Child Scene → pick `medications_popup.tscn`**
9. **Verify the new node is named `MedicationsPopup`** (matches the engine's `$PopupLayer/MedicationsPopup` reference)
10. **Verify `Visible` is false** on the instance
11. **Save the encounter scene**

---

## TESTING CHECKLIST

After applying all edits and creating the scene, run the game and:

1. Press the Meds button → popup should open with three tabs visible
2. **Search tab:** type "tor" → should show Toradol (ketorolac). Type "morph" → should show morphine. Type "nothere" → should show "no medications match"
3. **Browse tab:** click each category in the left list → right side should populate
4. **Ask MEDDY tab:** type "antibiotic for sepsis" → wait → should populate with broad-spectrum antibiotics. Watch the server console for the LLM call
5. **Allergy test:** Browse → Analgesics → click Ibuprofen → allergy warning modal should fire. Cancel → should add 1 harm point and close. Try again → click Proceed Anyway → should add second harm point, set `anaphylaxis_triggered = true` (visible in console), then continue to route picker
6. **No-IV test:** Without placing an IV, Browse → Antibiotics → click Zosyn (IV-only) → "No IV Access" modal should fire
7. **Route picker:** Place an IV first via the IV popup. Then Browse → Antibiotics → ceftriaxone → route picker should show: IM button + "IV via L AC" (or whichever site) button
8. **AP confirmation:** Pick a route → click Order → AP cost popup should fire showing cost and current AP. Confirm → AP should deduct, turn should advance, popup returns to medication browser

If any step fails, check the Godot console for error messages and the Node.js server console for LLM call logs.
