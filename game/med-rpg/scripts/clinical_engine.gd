extends Node2D

# ============================================================
# ClinicalEngine.gd
# Brain of the clinical encounter. Manages patient state,
# AP, bonus points, harm points, and all game logic.
# ============================================================

# ============================================================
# DEVELOPER TOGGLES — change before builds
# ============================================================
const DEV_MODE_LLM: bool = true          # true = live LLM, false = authored responses
const DEV_MODE_SKIP_CONFIRM: bool = false # true = skip AP popups (for auto-runs only)


# --- Patient State ---
enum PatientState { STABLE, PERFORATED, SEPTIC_SHOCK, COMA_FAIL }
var current_state: PatientState = PatientState.STABLE

# --- Action Points ---
var ap_max: int = 100
var ap_current: int = 100

# --- Bonus & Harm Points ---
var bonus_points: int = 0
var harm_points: int = 0
var harm_threshold: int = 7

# --- Clinical Flags ---
var iv_access: bool = false
# --- IV State ---
# Per-site IV records. Null = no IV; Dictionary = IV in place.
# See iv_system.gd for site IDs and record schema.
var iv_sites: Dictionary = {
	"left_ac":     null,
	"right_ac":    null,
	"left_hand":   null,
	"right_hand":  null,
	"left_foot":   null,
	"right_foot":  null,
}

# --- IV Popup ---
var iv_popup: Control = null


var supplemental_o2: bool = false
var npo: bool = false
var intubated: bool = false
var arterial_line: bool = false
var central_line: bool = false
var sedative_given: bool = false
var paralytic_given: bool = false
var appendectomy_done: bool = false
var diagnosis_correct: bool = false

# --- Imaging & Consult Flags (appendectomy prerequisites) ---
var imaging_completed: bool = false
var surgery_consult_completed: bool = false

# --- Badge Flags ---
var active_boost_badges: Array = []
var active_burnout_badges: Array = []
var dispenser_used: bool = false

# --- Turn Counter ---
var turn_count: int = 0

# --- Time Counter ---
var elapsed_seconds: float = 0.0
var time_limit_seconds: float = 36000.0  # 10 hours — effectively off for now
var time_limit_active: bool = false       # set true by timed badges/modes
var clock_timer: Timer

# --- Condition Data ---
var condition_data: Dictionary = {}

var current_mode: String = ""

var system_prompts: Dictionary = {}

var pending_input: String = ""

var pending_validated_input: String = ""
var awaiting_validation: bool = false

# History domain tracking
var history_domains_asked: Array = []
var history_symptoms_drilled: Array = []
var family_friendly_mode: bool = false

# Two-call state tracking
var awaiting_history_cost: bool = false
var pending_history_input: String = ""
var pending_history_cost: int = 0

var pending_new_domains: Array = []
var pending_new_symptoms: Array = []

# Exam tracking
var exam_systems_done: Array = []      # e.g. ["abdomen", "cardiovascular", "respiratory"]
var exam_maneuvers_done: Array = []    # e.g. ["rovsing", "mcburneys", "rebound_tenderness"]
var awaiting_exam_cost: bool = false
var pending_exam_input: String = ""
var pending_exam_cost: int = 0
var pending_new_exam_systems: Array = []
var pending_new_exam_maneuvers: Array = []

# --- Labs Data ---
var master_labs_data: Dictionary = {}
var condition_labs_data: Dictionary = {}
var encounter_lab_results: Array = []

# --- Labs Popup ---
var labs_popup: Control = null

# --- Imaging Data ---
var master_imaging_data: Dictionary = {}
var condition_imaging_data: Dictionary = {}
var encounter_imaging_orders: Array = []
var current_measurements: Dictionary = {}

# --- Imaging Popup ---
var imaging_popup: Control = null

# ============================================================
func _ready():
	if DEV_MODE_LLM:
		print("WARNING: Running in LLM dev mode — not for shipping")
	if DEV_MODE_SKIP_CONFIRM:
		print("WARNING: AP confirmation disabled — auto-run mode")
	load_condition_data()
	# Start the clock
	clock_timer = Timer.new()
	clock_timer.wait_time = 1.0
	clock_timer.autostart = true
	clock_timer.timeout.connect(_on_clock_tick)
	add_child(clock_timer)
	update_hud()
	update_monitor()
# Wire labs popup
	labs_popup = $PopupLayer/LabsPopup
	labs_popup.order_confirmed.connect(_on_labs_order_confirmed)
	labs_popup.popup_closed.connect(_on_labs_popup_closed)
	
# Wire imaging popup
	imaging_popup = $PopupLayer/ImagingPopup
	imaging_popup.order_confirmed.connect(_on_imaging_order_confirmed)
	imaging_popup.popup_closed.connect(_on_imaging_popup_closed)
	
# Wire IV popup
	iv_popup = $PopupLayer/IVPopup
	iv_popup.iv_placed.connect(_on_iv_placed)
	iv_popup.iv_removed.connect(_on_iv_removed)
	iv_popup.popup_closed.connect(_on_iv_popup_closed)
# ============================================================
func load_condition_data():
	var file = FileAccess.open("res://data/conditions/appendicitis.json", FileAccess.READ)
	if file:
		var json = JSON.new()
		json.parse(file.get_as_text())
		condition_data = json.get_data()
		file.close()
		print("Condition data loaded OK")
	else:
		print("ERROR: Could not load appendicitis.json")
	# Load master labs
	var labs_file = FileAccess.open("res://data/labs/master_labs.json", FileAccess.READ)
	if labs_file:
		var labs_json := JSON.new()
		labs_json.parse(labs_file.get_as_text())
		master_labs_data = labs_json.get_data()
		labs_file.close()
		print("master_labs.json loaded OK")
	else:
		print("ERROR: Could not load master_labs.json")
	roll_radiology_measurements()
	

	var cond_labs_file = FileAccess.open("res://data/conditions/appendicitis_labs.json", FileAccess.READ)
	if cond_labs_file:
		var cond_json := JSON.new()
		cond_json.parse(cond_labs_file.get_as_text())
		condition_labs_data = cond_json.get_data()
		cond_labs_file.close()
		print("appendicitis_labs.json loaded OK")
	else:
		print("ERROR: Could not load appendicitis_labs.json")
		
	var imaging_file = FileAccess.open("res://data/imaging/master_imaging.json", FileAccess.READ)
	if imaging_file:
		var imaging_json := JSON.new()
		imaging_json.parse(imaging_file.get_as_text())
		master_imaging_data = imaging_json.get_data()
		imaging_file.close()
		print("master_imaging.json loaded OK")
	else:
		print("ERROR: Could not load master_imaging.json")

	var cond_imaging_file = FileAccess.open("res://data/conditions/appendicitis_imaging.json", FileAccess.READ)
	if cond_imaging_file:
		var cond_imaging_json := JSON.new()
		cond_imaging_json.parse(cond_imaging_file.get_as_text())
		condition_imaging_data = cond_imaging_json.get_data()
		cond_imaging_file.close()
		print("appendicitis_imaging.json loaded OK")
	else:
		print("ERROR: Could not load appendicitis_imaging.json")
		
	var prompt_file = FileAccess.open("res://data/conditions/appendicitis_system_prompts.json", FileAccess.READ)
	if prompt_file:
		var json2 = JSON.new()
		json2.parse(prompt_file.get_as_text())
		system_prompts = json2.get_data()
		prompt_file.close()
		print("System prompts loaded OK")
	else:
		print("ERROR: Could not load appendicitis_system_prompts.json")

# ============================================================

func roll_radiology_measurements() -> void:
	current_measurements.clear()
	var measurements: Dictionary = condition_data.get("radiology_measurements", {})
	if measurements.is_empty():
		return
 
	var state_name: String = _get_state_name()
	for measurement_id in measurements:
		var spec: Dictionary = measurements[measurement_id]
		var by_state: Dictionary = spec.get("by_state", {})
		var range_for_state: Dictionary = by_state.get(state_name, {})
		# Fall back to "stable" range if current state has no entry — useful
		# for measurements that don't differ across states (or to reduce
		# authoring burden for measurements that only vary in a few states).
		if range_for_state.is_empty():
			range_for_state = by_state.get("stable", {})
		if range_for_state.is_empty():
			continue
		var mn: float = float(range_for_state.get("min", 0.0))
		var mx: float = float(range_for_state.get("max", 0.0))
		var value: float
		if mx <= mn:
			value = mn
		else:
			value = randf_range(mn, mx)
		current_measurements[measurement_id] = value
		print("Rolled measurement %s = %.2f (state: %s)" % [measurement_id, value, state_name])

func format_measurement(measurement_id: String, modality: String = "ct") -> String:
	if not current_measurements.has(measurement_id):
		return ""
	var raw_value: float = current_measurements[measurement_id]
	var spec: Dictionary = condition_data.get("radiology_measurements", {}).get(measurement_id, {})
	var unit: String = spec.get("unit", "")
	var precision_map: Dictionary = spec.get("modality_precision", {})
	# Add per-state offset if the patient has progressed beyond stable.
	# E.g. perforated state adds +2mm to the original rolled appendix diameter.
	var state_offsets: Dictionary = spec.get("state_offsets", {})
	var state_name: String = _get_state_name()
	var offset: float = float(state_offsets.get(state_name, 0))
	var adjusted_value: float = raw_value + offset
	# Default to 1 decimal if modality isn't listed
	var decimals: int = int(precision_map.get(modality, 1))
	var factor: float = pow(10.0, decimals)
	var rounded: float = round(adjusted_value * factor) / factor
	var formatted: String
	if decimals == 0:
		formatted = "%d" % int(rounded)
	else:
		formatted = "%.*f" % [decimals, rounded]
	if unit != "":
		formatted += " " + unit
	return formatted
	
func substitute_measurements(text: String, modality: String = "ct") -> String:
	if text.is_empty():
		return text
	var result: String = text
	for measurement_id in current_measurements:
		var placeholder: String = "{{" + measurement_id + "}}"
		if placeholder in result:
			var formatted: String = format_measurement(measurement_id, modality)
			result = result.replace(placeholder, formatted)
	return result
	
# ============================================================
func update_hud():
	# Update AP, bonus, harm, turn, time displays
	var hud = $HUD
	hud.get_node("APBar/APValue").text = str(ap_current)
	hud.get_node("BonusPoints/BonusValue").text = str(bonus_points)
	hud.get_node("HarmPoints/HarmValue").text = str(harm_points)
	hud.get_node("TurnCounter/TurnValue").text = str(turn_count)
	hud.get_node("TimeCounter/TimeValue").text = format_time(elapsed_seconds)

# ============================================================
func increment_turn() -> void:
	turn_count += 1
	update_hud()
	check_burnout_triggers()

# ============================================================
func _on_clock_tick() -> void:
	elapsed_seconds += 1.0
	update_hud()
	if time_limit_active and elapsed_seconds >= time_limit_seconds:
		on_time_limit_reached()

# ============================================================
func on_time_limit_reached() -> void:
	clock_timer.stop()
	print("Time limit reached!")
	# TODO: same Mega Hospital outcome as 0 AP
	on_insufficient_ap()

# ============================================================
func format_time(seconds: float) -> String:
	var total: int = int(seconds)
	var h: int = total / 3600
	var m: int = (total % 3600) / 60
	var s: int = total % 60
	return "%02d:%02d:%02d" % [h, m, s]

# ============================================================
func spend_ap(amount: int) -> bool:
	# Returns true if AP was successfully spent, false if insufficient
	var actual_cost = apply_badge_cost_modifiers(amount)
	if ap_current >= actual_cost:
		ap_current -= actual_cost
		increment_turn()
		update_hud()
		check_state_transitions()
		check_burnout_triggers()
		return true
	else:
		on_insufficient_ap()
		return false

# ============================================================
func apply_badge_cost_modifiers(base_cost: int) -> int:
	var cost = base_cost
	if "burnout_burnt_out" in active_burnout_badges:
		cost += 1
	# Add other badge modifiers here as needed
	return max(cost, 1)

# ============================================================
func award_bonus_points(amount: int, reason: String):
	bonus_points += amount
	update_hud()
	print("Bonus point awarded: " + reason)
	# TODO: trigger MEDDY excited popup

# ============================================================
func award_harm_points(amount: int, reason: String):
	harm_points += amount
	update_hud()
	print("Harm point awarded: " + reason)
	# TODO: trigger MEDDY worried popup
	check_harm_threshold()

# ============================================================
func check_harm_threshold():
	if harm_points >= harm_threshold and current_state != PatientState.SEPTIC_SHOCK:
		transition_to_state(PatientState.SEPTIC_SHOCK)
		ap_current = min(ap_current, 30)
		update_hud()

# ============================================================
func check_state_transitions():
	match current_state:
		PatientState.STABLE:
			if ap_current <= 50:
				transition_to_state(PatientState.PERFORATED)
		PatientState.PERFORATED:
			if ap_current <= 30:
				transition_to_state(PatientState.SEPTIC_SHOCK)
		PatientState.SEPTIC_SHOCK:
			if ap_current <= 0:
				transition_to_state(PatientState.COMA_FAIL)

# ============================================================
func transition_to_state(new_state: PatientState):
	current_state = new_state
	print("Patient state changed to: " + PatientState.keys()[new_state])
	update_monitor()
	labs_popup.invalidate_result_cache()
	imaging_popup.invalidate_result_cache()
	# TODO: trigger MEDDY alarmed popup
	# TODO: update patient sprite

# ============================================================
func check_burnout_triggers():
	if active_burnout_badges.size() == 0:
		if harm_points >= 5:
			trigger_burnout_badge()
		elif ap_current <= 50:
			trigger_burnout_badge()
		elif turn_count >= 10:
			trigger_burnout_badge()

# ============================================================
func trigger_burnout_badge():
	# TODO: draw random burnout badge and apply it
	print("Burnout badge triggered!")

# ============================================================
func update_monitor():
	var v = $Monitor/VitalsContainer
	match current_state:
		PatientState.STABLE:
			v.get_node("HRRow/HRValue").text = "105"
			v.get_node("BPRow/BPValue").text = "120/85"
			v.get_node("RRRow/RRValue").text = "16"
			v.get_node("TempRow/TempValue").text = "100.8°F"
			v.get_node("SpO2Row/SpO2Value").text = "99%"
		PatientState.PERFORATED:
			v.get_node("HRRow/HRValue").text = "122"
			v.get_node("BPRow/BPValue").text = "106/70"
			v.get_node("RRRow/RRValue").text = "24"
			v.get_node("TempRow/TempValue").text = "102.1°F"
			v.get_node("SpO2Row/SpO2Value").text = "98%"
		PatientState.SEPTIC_SHOCK:
			v.get_node("HRRow/HRValue").text = "135"
			v.get_node("BPRow/BPValue").text = "100/60"
			v.get_node("RRRow/RRValue").text = "28"
			v.get_node("TempRow/TempValue").text = "103.4°F"
			v.get_node("SpO2Row/SpO2Value").text = "95%"
		PatientState.COMA_FAIL:
			v.get_node("HRRow/HRValue").text = "148"
			v.get_node("BPRow/BPValue").text = "80/40"
			v.get_node("RRRow/RRValue").text = "32"
			v.get_node("TempRow/TempValue").text = "104.2°F"
			v.get_node("SpO2Row/SpO2Value").text = "88%"
	_update_iv_status_display()

func _update_iv_status_display() -> void:
	# Updates the IV access label below SpO2 in the vitals area.
	var label = find_child("IVAccessLabel", true, false)
	if not label:
		return  # Label hasn't been added to the scene yet — see setup notes.

	var sites: Array = []
	var has_extravasated := false
	for sid in iv_sites:
		var rec = iv_sites[sid]
		if rec == null:
			continue
		var display: String = ""
		match sid:
			"left_ac":     display = "L AC"
			"right_ac":    display = "R AC"
			"left_hand":   display = "L Hand"
			"right_hand":  display = "R Hand"
			"left_foot":   display = "L Foot"
			"right_foot":  display = "R Foot"
		if bool(rec.get("extravasated", false)):
			sites.append("[color=#e64d4d]%s[/color]" % display)
			has_extravasated = true
		else:
			sites.append(display)

	if sites.is_empty():
		label.text = "[color=#8c8e95]No IV access[/color]"
	else:
		label.text = "IVs: %d (%s)" % [sites.size(), ", ".join(sites)]
# ============================================================
func on_insufficient_ap():
	print("Insufficient AP!")
	# TODO: show Mega Hospital popup


func _on_history_btn_pressed() -> void:
	print("History button clicked!")
	show_input_area("history")

func show_input_area(mode: String) -> void:
	current_mode = mode
	print("Mode set to: " + current_mode)
	$InputArea/InputPanel/InputRow/InputField.placeholder_text = "Ask a history question..."
	$InputArea/InputPanel/InputRow/InputField.grab_focus()
	


func _on_submit_btn_pressed() -> void:
	print("Submit button pressed!")
	var input_text = $InputArea/InputPanel/InputRow/InputField.text.strip_edges()
	if input_text == "":
		return
	
	if DEV_MODE_SKIP_CONFIRM:
		# Skip confirmation popup entirely
		if current_mode == "history":
			detect_history_cost(input_text)
		elif current_mode == "exam":
			detect_exam_cost(input_text)
		else:
			process_input(input_text)
		$InputArea/InputPanel/InputRow/InputField.text = ""
	else:
		if current_mode == "history":
			detect_history_cost(input_text)
			$InputArea/InputPanel/InputRow/InputField.text = ""
		elif current_mode == "exam":
			detect_exam_cost(input_text)
			$InputArea/InputPanel/InputRow/InputField.text = ""
		else:
			pending_input = input_text
			show_confirmation_popup()

func show_confirmation_popup() -> void:
	var cost = get_action_cost(current_mode)
	var message = ""
	match current_mode:
		"history":
			message = "Ask patient:\n\"" + pending_input + "\"\n\nCost: " + str(cost) + " AP. Proceed?"
		"exam":
			message = "Perform exam:\n\"" + pending_input + "\"\n\nCost: " + str(cost) + " AP. Proceed?"
		"diagnosis":
			message = "Submit diagnosis:\n\"" + pending_input + "\"\n\nNo AP cost. Proceed?"
		_:
			message = "Perform action:\n\"" + pending_input + "\"\n\nCost: " + str(cost) + " AP. Proceed?"
	$PopupLayer/PopupContent/PopupVBox/PopupMessage.text = message
	$PopupLayer/PopupContent.visible = true
	$PopupLayer/PopupContent/PopupVBox/PopupButtons/ConfirmBtn.grab_focus()

func process_input(input: String) -> void:
	print("process_input called with: " + input)
	print("Current mode is: " + current_mode)
	match current_mode:
		"history":
			detect_history_cost(input)
		"exam":
			detect_exam_cost(input)
		"stability":
			var system = system_prompts["system_prompts"]["physical_exam"]["prompt"]
			send_to_llm("The doctor performs a rapid stability assessment — quickly looks at the patient's general appearance, skin color, breathing, and alertness.", system)
		_:
			print("No mode selected")
			
func send_to_llm(prompt: String, system: String) -> void:
	print("send_to_llm called")
	print("Prompt length: " + str(prompt.length()))
	print("System length: " + str(system.length()))
	print("Sending request to MedRPG server...")
	var url = "http://localhost:3000/llm"
	var headers = ["Content-Type: application/json"]
	var body = JSON.stringify({
		"prompt": prompt,
		"system": system,
		"max_tokens": 256
	})
	print("Body length: " + str(body.length()))
	$OllamaRequest.request(url, headers, HTTPClient.METHOD_POST, body)
	print("Request sent!")

func _on_ollama_request_request_completed(result, response_code, headers, body) -> void:
	var json = JSON.new()
	json.parse(body.get_string_from_utf8())
	var response = json.get_data()
	if response and response.has("response"):
		var response_text = response["response"]
		print("Response received: " + response_text)
		if awaiting_history_cost:
			handle_history_cost_response(response_text)
		elif awaiting_exam_cost:
			handle_exam_cost_response(response_text)
		elif awaiting_validation:
			handle_validation_response(response_text)
		else:
			display_response("Patient", response_text)
	else:
		print("Ollama error or empty response")

func display_response(speaker: String, response_text: String) -> void:
	$ResponseLayer/ResponsePanel.visible = true
	$ResponseLayer/ResponsePanel/ResponseContent/ResponseSpeaker.text = speaker + ":"
	$ResponseLayer/ResponsePanel/ResponseContent/ResponseText.text = response_text
	
func get_action_cost(mode: String) -> int:
	match mode:
		"history":
			return 5
		"stability":
			return 2
		"exam":
			return 2
		"labs":
			return 2
		"imaging":
			return 8
		"medications":
			return 3
		"consults":
			return 7
		"surgeries":
			return 10
		"other_treatments":
			return 2
		"airway":
			return 5
		"pathology":
			return 4
		"misc_tests":
			return 5
		"diagnosis":
			return 0
		_:
			return 2


func _on_confirm_btn_pressed() -> void:
	$PopupLayer/PopupContent.visible = false
	var cost = 0
	if current_mode == "history":
		cost = pending_history_cost
	elif current_mode == "exam":
		cost = pending_exam_cost
	else:
		cost = get_action_cost(current_mode)
	
	if spend_ap(cost):
		if current_mode == "history":
			update_history_tracking(pending_new_domains, pending_new_symptoms)
			send_history_to_patient(pending_history_input)
			pending_history_input = ""
			pending_history_cost = 0
			pending_new_domains = []
			pending_new_symptoms = []
		elif current_mode == "exam":
			update_exam_tracking(pending_new_exam_systems, pending_new_exam_maneuvers)
			send_exam_to_patient(pending_exam_input)
			pending_exam_input = ""
			pending_exam_cost = 0
			pending_new_exam_systems = []
			pending_new_exam_maneuvers = []
		else:
			process_input(pending_input)
		$InputArea/InputPanel/InputRow/InputField.text = ""
		pending_input = ""
	else:
		print("Not enough AP!")

func _on_cancel_btn_pressed() -> void:
	$PopupLayer/PopupContent.visible = false
	pending_input = ""
	$InputArea/InputPanel/InputRow/InputField.text = ""


func _on_input_field_text_submitted(new_text: String) -> void:
	_on_submit_btn_pressed()
	
func _input(event: InputEvent) -> void:
	if $PopupLayer/PopupContent.visible:
		if event.is_action_pressed("ui_accept"):
			_on_confirm_btn_pressed()
		elif event.is_action_pressed("ui_cancel"):
			_on_cancel_btn_pressed()


func _on_stability_btn_pressed() -> void:
	current_mode = "stability"
	pending_input = "Rapid Stability Assessment"
	show_confirmation_popup()

func _on_exam_btn_pressed() -> void:
	current_mode = "exam"
	$InputArea/InputPanel/InputRow/InputField.placeholder_text = "Examine part of body (abdomen, lungs, etc), or do specific exam maneuver (e.g. 'listen to lungs,' 'palpate abdomen')..."
	$InputArea/InputPanel/InputRow/InputField.grab_focus()

func _on_labs_btn_pressed() -> void:
	if master_labs_data.is_empty():
		print("ERROR: master_labs_data not loaded")
		return
	$InputArea.visible = false
	labs_popup.open(
		master_labs_data,
		condition_labs_data,
		_get_state_name(),
		elapsed_seconds,
		encounter_lab_results
	)

func _on_imaging_btn_pressed() -> void:
	if master_imaging_data.is_empty():
		print("ERROR: master_imaging_data not loaded")
		return
	$InputArea.visible = false
	imaging_popup.open(
		master_imaging_data,
		condition_imaging_data,
		_get_state_name(),
		elapsed_seconds,
		turn_count,
		encounter_imaging_orders,
		iv_access,
		condition_data.get("patient_demographics", {}),
		{}
	)

func _on_meds_btn_pressed() -> void:
	current_mode = "medications"
	$InputArea/InputPanel/InputRow/InputField.placeholder_text = "Order a medication..."
	$InputArea/InputPanel/InputRow/InputField.grab_focus()

func _on_consults_btn_pressed() -> void:
	current_mode = "consults"
	$InputArea/InputPanel/InputRow/InputField.placeholder_text = "Request a consult (e.g. General Surgery)..."
	$InputArea/InputPanel/InputRow/InputField.grab_focus()

func _on_surgeries_btn_pressed() -> void:
	current_mode = "surgeries"
	$InputArea/InputPanel/InputRow/InputField.placeholder_text = "Request a procedure or surgery..."
	$InputArea/InputPanel/InputRow/InputField.grab_focus()

func _on_other_tx_btn_pressed() -> void:
	current_mode = "other_treatments"
	$InputArea/InputPanel/InputRow/InputField.placeholder_text = "Order supportive care (e.g. NPO, IV access)..."
	$InputArea/InputPanel/InputRow/InputField.grab_focus()

func _on_airway_btn_pressed() -> void:
	current_mode = "airway"
	$InputArea/InputPanel/InputRow/InputField.placeholder_text = "Airway action (e.g. intubate, BMV)..."
	$InputArea/InputPanel/InputRow/InputField.grab_focus()

func _on_pathology_btn_pressed() -> void:
	current_mode = "pathology"
	$InputArea/InputPanel/InputRow/InputField.placeholder_text = "Order pathology or biopsy..."
	$InputArea/InputPanel/InputRow/InputField.grab_focus()

func _on_misc_tests_btn_pressed() -> void:
	current_mode = "misc_tests"
	$InputArea/InputPanel/InputRow/InputField.placeholder_text = "Order misc test (e.g. EKG, EEG)..."
	$InputArea/InputPanel/InputRow/InputField.grab_focus()

func _on_diagnosis_btn_pressed() -> void:
	current_mode = "diagnosis"
	$InputArea/InputPanel/InputRow/InputField.placeholder_text = "Enter your diagnosis..."
	$InputArea/InputPanel/InputRow/InputField.grab_focus()

func _on_iv_btn_pressed() -> void:
	if iv_popup == null:
		print("ERROR: iv_popup not wired")
		return
	$InputArea.visible = false
	iv_popup.open(iv_sites, ap_current, elapsed_seconds, turn_count)

func _on_o2_btn_pressed() -> void:
	current_mode = "other_treatments"
	pending_input = "Supplemental oxygen"
	show_confirmation_popup()

func validate_exam_input(input: String) -> void:
	awaiting_validation = true
	pending_validated_input = input
	var validation_system = "You are a medical input validator. Determine if the following physical exam input describes ONE specific body system exam (e.g. abdominal exam, cardiac exam, respiratory exam) OR ONE specific exam maneuver (e.g. McBurney's point, Rovsing's sign, rebound tenderness, psoas sign). Respond with only VALID or INVALID. Multiple maneuvers at once = INVALID. Vague requests like 'do everything' = INVALID."
	send_to_llm(input, validation_system)

func handle_validation_response(response: String) -> void:
	awaiting_validation = false
	var clean = response.strip_edges().to_upper()
	if clean.begins_with("VALID"):
		var system = system_prompts["system_prompts"]["physical_exam"]["prompt"]
		send_to_llm(pending_validated_input, system)
		pending_validated_input = ""
	else:
		display_response("MEDDY", "Try examining one specific area or maneuver at a time — like 'abdominal exam' or 'check for rebound tenderness'.")
		pending_validated_input = ""

func detect_history_cost(input: String) -> void:
	print("detect_history_cost called with: " + input)
	awaiting_history_cost = true
	pending_history_input = input
	
	var already_asked = JSON.stringify(history_domains_asked)
	var already_drilled = JSON.stringify(history_symptoms_drilled)
	
	var detection_system = system_prompts["system_prompts"]["history_cost_detection"]["prompt"]
	detection_system = detection_system.replace("{already_asked_domains}", already_asked)
	detection_system = detection_system.replace("{already_drilled_symptoms}", already_drilled)
	
	send_to_llm(input, detection_system)

func handle_history_cost_response(response: String) -> void:
	awaiting_history_cost = false
	
	# Parse JSON response
	var json = JSON.new()
	var clean = response.strip_edges()
	# Strip markdown code blocks if present
	clean = clean.replace("```json", "").replace("```", "").strip_edges()
	json.parse(clean)
	var data = json.get_data()
	
	if data == null:
		print("ERROR: Could not parse history cost response")
		# Fall back to just sending the question
		send_history_to_patient(pending_history_input)
		return
	
	# Check if unrelated
	if data.get("is_unrelated", false):
		increment_turn()
		send_history_to_patient(pending_history_input)
		return
	
	var ap_cost = data.get("ap_cost", 1)
	var new_domains = data.get("new_domains", [])
	var new_symptoms = data.get("new_symptoms", [])
	
	pending_history_cost = ap_cost
	
	# If cost is 0 — skip popup and go straight to patient response
	if ap_cost == 0:
		increment_turn()
		update_history_tracking(new_domains, new_symptoms)
		send_history_to_patient(pending_history_input)
		return
	
	# Show confirmation popup with AP cost
	var message = "Ask patient:\n\"" + pending_history_input + "\"\n\nCost: " + str(ap_cost) + " AP. Proceed?"
	$PopupLayer/PopupContent/PopupVBox/PopupMessage.text = message
	$PopupLayer/PopupContent.visible = true
	$PopupLayer/PopupContent/PopupVBox/PopupButtons/ConfirmBtn.grab_focus()
	
	# Store domains for updating after confirm
	pending_new_domains = new_domains
	pending_new_symptoms = new_symptoms

func update_history_tracking(new_domains: Array, new_symptoms: Array) -> void:
	for domain in new_domains:
		if not history_domains_asked.has(domain):
			history_domains_asked.append(domain)
	for symptom in new_symptoms:
		if not history_symptoms_drilled.has(symptom):
			history_symptoms_drilled.append(symptom)

func send_history_to_patient(input: String) -> void:
	var system = system_prompts["system_prompts"]["history"]["prompt"]
	send_to_llm(input, system)

func detect_exam_cost(input: String) -> void:
	awaiting_exam_cost = true
	pending_exam_input = input
	
	var already_systems = JSON.stringify(exam_systems_done)
	var already_maneuvers = JSON.stringify(exam_maneuvers_done)
	
	var detection_system = system_prompts["system_prompts"]["exam_cost_detection"]["prompt"]
	detection_system = detection_system.replace("{already_examined_systems}", already_systems)
	detection_system = detection_system.replace("{already_done_maneuvers}", already_maneuvers)
	
	send_to_llm(input, detection_system)

func handle_exam_cost_response(response: String) -> void:
	awaiting_exam_cost = false
	
	var json = JSON.new()
	var clean = response.strip_edges()
	clean = clean.replace("```json", "").replace("```", "").strip_edges()
	json.parse(clean)
	var data = json.get_data()
	
	if data == null:
		print("ERROR: Could not parse exam cost response")
		send_exam_to_patient(pending_exam_input)
		return
	
	var ap_cost = data.get("ap_cost", 2)
	var new_systems = data.get("new_systems", [])
	var new_maneuvers = data.get("new_maneuvers", [])
	
	pending_exam_cost = ap_cost
	pending_new_exam_systems = new_systems
	pending_new_exam_maneuvers = new_maneuvers
	
	if ap_cost == 0:
		increment_turn()
		update_exam_tracking(new_systems, new_maneuvers)
		send_exam_to_patient(pending_exam_input)
		return
	
	var message = "Perform exam:\n\"" + pending_exam_input + "\"\n\nCost: " + str(ap_cost) + " AP. Proceed?"
	$PopupLayer/PopupContent/PopupVBox/PopupMessage.text = message
	$PopupLayer/PopupContent.visible = true
	$PopupLayer/PopupContent/PopupVBox/PopupButtons/ConfirmBtn.grab_focus()

func update_exam_tracking(new_systems: Array, new_maneuvers: Array) -> void:
	for system in new_systems:
		if not exam_systems_done.has(system):
			exam_systems_done.append(system)
	for maneuver in new_maneuvers:
		if not exam_maneuvers_done.has(maneuver):
			exam_maneuvers_done.append(maneuver)

func send_exam_to_patient(input: String) -> void:
	var system = system_prompts["system_prompts"]["physical_exam"]["prompt"]
	send_to_llm(input, system)

func _get_state_name() -> String:
	match current_state:
		PatientState.STABLE:       return "stable"
		PatientState.PERFORATED:   return "perforated"
		PatientState.SEPTIC_SHOCK: return "septic_shock"
		PatientState.COMA_FAIL:    return "coma_fail"
	return "stable"

func _on_labs_order_confirmed(new_results: Array, total_ap: int) -> void:
	spend_ap(total_ap)
	encounter_lab_results.append_array(new_results)
	increment_turn()
	print("Labs ordered: %d results, %d AP" % [new_results.size(), total_ap])

func _on_labs_popup_closed() -> void:
	$InputArea.visible = true

func _on_imaging_order_confirmed(orders: Array, total_ap: int, used_iv_contrast: bool) -> void:
	spend_ap(total_ap)
	encounter_imaging_orders.append_array(orders)
	increment_turn()
	print("Imaging ordered: %d studies, %d AP, contrast=%s" % [orders.size(), total_ap, used_iv_contrast])

func _on_imaging_popup_closed() -> void:
	$InputArea.visible = true

func _on_iv_placed(site_id: String, success: bool, used_ap: int) -> void:
	# spend_ap also calls increment_turn() and update_hud() internally,
	# so don't call those again here.
	if not spend_ap(used_ap):
		print("WARN: spend_ap returned false during IV placement (insufficient AP?)")
		return
	if success:
		iv_sites[site_id] = {
			"site": site_id,
			"placed_at_seconds": elapsed_seconds,
			"placed_at_turn": turn_count,
			"extravasated": false,
			"extravasated_at_seconds": 0.0,
			"extravasated_at_turn": 0,
			"gauge": 18,  # default; mini-game will set this later
		}
	# Keep the legacy iv_access boolean in sync (still read by imaging system)
	iv_access = _has_any_working_iv()
	# Refresh vitals display (which now includes the IV access line)
	update_monitor()
	print("IV attempt at %s: success=%s, AP spent=%d" % [site_id, success, used_ap])


func _on_iv_removed(site_id: String) -> void:
	iv_sites[site_id] = null
	iv_access = _has_any_working_iv()
	update_monitor()
	print("IV removed at %s" % site_id)


func _on_iv_popup_closed() -> void:
	$InputArea.visible = true


# Helper — returns true if any site has a working (non-extravasated) IV.
func _has_any_working_iv() -> bool:
	for sid in iv_sites:
		var rec = iv_sites[sid]
		if rec != null and not bool(rec.get("extravasated", false)):
			return true
	return false


# Helper — returns true if any AC site has a working IV (used later by CT PE protocol).
func _has_working_ac_iv() -> bool:
	for sid in ["left_ac", "right_ac"]:
		var rec = iv_sites[sid]
		if rec != null and not bool(rec.get("extravasated", false)):
			return true
	return false
