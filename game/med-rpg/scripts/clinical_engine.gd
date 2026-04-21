extends Node2D

# ============================================================
# ClinicalEngine.gd
# Brain of the clinical encounter. Manages patient state,
# AP, bonus points, harm points, and all game logic.
# ============================================================

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

# --- Condition Data ---
var condition_data: Dictionary = {}

var current_mode: String = ""

# ============================================================
func _ready():
	load_condition_data()
	update_hud()
	update_monitor()

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

# ============================================================
func update_hud():
	# Update AP, bonus, harm displays
	var hud = $HUD
	hud.get_node("APBar/APValue").text = str(ap_current)
	hud.get_node("BonusPoints/BonusValue").text = str(bonus_points)
	hud.get_node("HarmPoints/HarmValue").text = str(harm_points)

# ============================================================
func spend_ap(amount: int) -> bool:
	# Returns true if AP was successfully spent, false if insufficient
	var actual_cost = apply_badge_cost_modifiers(amount)
	if ap_current >= actual_cost:
		ap_current -= actual_cost
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
	# TODO: trigger MEDDY alarmed popup
	# TODO: update patient sprite

# ============================================================
func check_burnout_triggers():
	if active_burnout_badges.size() == 0:
		if harm_points >= 5:
			trigger_burnout_badge()
		elif ap_current <= 50:
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
	var input_text = $InputArea/InputPanel/InputRow/InputField.text.strip_edges()
	if input_text == "":
		return
	print("Player input: " + input_text)
	process_input(input_text)
	$InputArea/InputPanel/InputRow/InputField.text = ""

func process_input(input: String) -> void:
	print("Current mode is: " + current_mode)
	match current_mode:
		"history":
			var system = "You are a 22 year old male patient with abdominal pain seeing a doctor. Respond naturally in 1-2 sentences only as the patient. Never reveal your diagnosis."
			send_to_llm(input, system)
		_:
			print("No mode selected")
			
func send_to_llm(prompt: String, system: String) -> void:
	print("Sending request to MedRPG server...")
	var url = "http://localhost:3000/llm"
	var headers = ["Content-Type: application/json"]
	var body = JSON.stringify({
		"prompt": prompt,
		"system": system,
		"max_tokens": 256
	})
	$OllamaRequest.request(url, headers, HTTPClient.METHOD_POST, body)

func _on_ollama_request_request_completed(result, response_code, headers, body) -> void:
	var json = JSON.new()
	json.parse(body.get_string_from_utf8())
	var response = json.get_data()
	if response and response.has("response"):
		var response_text = response["response"]
		print("Ollama says: " + response_text)
		display_response("Patient", response_text)
	else:
		print("Ollama error or empty response")

func display_response(speaker: String, response_text: String) -> void:
	$ResponseLayer/ResponsePanel.visible = true
	$ResponseLayer/ResponsePanel/ResponseContent/ResponseSpeaker.text = speaker + ":"
	$ResponseLayer/ResponsePanel/ResponseContent/ResponseText.text = response_text
