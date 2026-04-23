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
	print("Submit button pressed!")
	var input_text = $InputArea/InputPanel/InputRow/InputField.text.strip_edges()
	if input_text == "":
		return
	
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
	current_mode = "labs"
	$InputArea/InputPanel/InputRow/InputField.placeholder_text = "Order a lab test..."
	$InputArea/InputPanel/InputRow/InputField.grab_focus()

func _on_imaging_btn_pressed() -> void:
	current_mode = "imaging"
	$InputArea/InputPanel/InputRow/InputField.placeholder_text = "Order imaging (e.g. CT abdomen)..."
	$InputArea/InputPanel/InputRow/InputField.grab_focus()

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
	current_mode = "other_treatments"
	pending_input = "IV access"
	show_confirmation_popup()

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
		send_history_to_patient(pending_history_input)
		return
	
	var ap_cost = data.get("ap_cost", 1)
	var new_domains = data.get("new_domains", [])
	var new_symptoms = data.get("new_symptoms", [])
	
	pending_history_cost = ap_cost
	
	# If cost is 0 — skip popup and go straight to patient response
	if ap_cost == 0:
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
