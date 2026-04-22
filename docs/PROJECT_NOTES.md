# MedRPG — Project Notes
*Single source of truth. Update this file every session.*

---

## Concept
Retro pixel art RPG where player is a doctor traveling a world map curing patients. Clinical encounters are turn-based. Player uses 13 icon categories to interact with patients. A local LLM (Claude via Anthropic API) parses free text for History, Physical Exam, Medications, and Diagnosis. Everything else is list/browser-based.

---

## Platform & Stack
- **Engine:** Godot 4 (GDScript)
- **Primary target:** PC / Steam
- **Secondary:** Mac / Linux via Godot export
- **Art:** LPC sprites + Itch.io tilesets (placeholder)
- **LLM:** Anthropic API (Claude Sonnet) via Node.js backend server
- **Git repo:** `C:\Users\jmcar\OneDrive\Documents\Coding Projects\MedRPG`
- **Godot project root:** `C:\Users\jmcar\OneDrive\Documents\Coding Projects\MedRPG\game\med-rpg\`
- **Backend server:** `C:\Users\jmcar\OneDrive\Documents\Coding Projects\MedRPG\server\`

---

## Backend Server
Node.js server running on `http://localhost:3000`. Proxies all LLM requests to Anthropic API. Players never see the API key.

**For development:** Run manually with `node server.js`
**For production:** Deploy to cloud server (e.g. $5/month DigitalOcean droplet)

**Endpoints:**
- `GET /health` — health check
- `POST /llm` — send prompt + system prompt, receive LLM response

---

## File Structure
```
MedRPG/
├── docs/
│   └── PROJECT_NOTES.md
├── server/
│   ├── server.js              ← Node.js backend (API key lives here)
│   ├── package.json
│   └── node_modules/
├── game/
│   └── med-rpg/               ← Godot project root
│       ├── .gitignore
│       ├── project.godot
│       ├── data/
│       │   ├── action_registry.json
│       │   ├── airway.json
│       │   ├── badges/
│       │   │   ├── boost_badges.json
│       │   │   └── burnout_badges.json
│       │   ├── conditions/
│       │   │   ├── appendicitis.json
│       │   │   ├── appendicitis_system_prompts.json
│       │   │   ├── appendicitis_other_treatments.json
│       │   │   ├── appendicitis_surgeries_procedures.json
│       │   │   └── appendicitis_end_conditions.json
│       │   └── medications/
│       │       └── (23 medication JSON files)
│       ├── scenes/
│       │   └── clinical_encounter.tscn
│       ├── scripts/
│       │   └── clinical_engine.gd
│       └── assets/
│           ├── sprites/characters/
│           │   ├── meddy/
│           │   ├── player/ (body, head, hair, clothing, extras, _baby variants)
│           │   ├── patients/patient_young_male/
│           │   └── npcs/
│           ├── badges/boost/ + burnout/
│           ├── ui/icons/ + panels/ + buttons/ + fonts/ + hud/
│           ├── backgrounds/
│           └── audio/
├── exports/
└── reference/
```

---

## Patient Personality Schema
Every condition file must include a `patient_personality` block and a companion `[condition]_system_prompts.json` file. This ensures clinical accuracy and consistent patient characterization across all LLM interactions.

### Schema
```json
"patient_personality": {
  "name": "string — patient first name",
  "analytical_level": "1-10 (1=very concrete, 10=very analytical)",
  "education": "none | high_school | some_college | college | graduate",
  "speech_grade_level": "integer (e.g. 11)",
  "dialect": "standard_usa | southern_usa | AAVE | british | etc.",
  "personality": "free text description",
  "mood": "free text description",
  "pain_level": "1-10",
  "agendas": "array of hidden goals or directives (empty if none)",
  "communication_style": "forthcoming | hesitant | verbose | concise | evasive",
  "notes": "any additional notes for LLM prompt construction"
}
```

### Appendicitis Patient (Marcus)
- Name: Marcus
- Analytical level: 5 (average)
- Education: College
- Speech grade level: 11
- Dialect: Standard USA
- Personality: Friendly, respectful, cooperative, not dramatic
- Mood: Anxious but calm, clearly in pain, trusting the doctor
- Pain level: 7
- Agendas: None
- Communication style: Forthcoming

---

## System Prompts Architecture
Each condition has a companion `[condition]_system_prompts.json` file containing:

- **history** — Patient responds to history questions with correct clinical presentation
- **physical_exam** — Patient reacts to physical exam maneuvers correctly
- **diagnosis** — Engine evaluates player's diagnosis (not shown to player)
- **meddy_commentary** — MEDDY generates educational feedback for bonus/harm events

### Key Principle
System prompts contain the full clinical ground truth for the case. The patient never volunteers information not asked about. Responses are 1-3 sentences. Patient never uses medical terminology or reveals diagnosis.

### Appendicitis Clinical Ground Truth (locked into system prompt)
- Pain started periumbilical 24hrs ago, migrated to RLQ — classic presentation
- Sharp, constant, 7/10
- Worse with movement, coughing, bumps, jumping
- Relieved only by lying still
- Associated: mild nausea, anorexia, low grade fever
- No vomiting, no diarrhea, no urinary symptoms
- PMH: none | Meds: none | Allergies: none

---

## LLM Integration

### Flow
```
Player input → Godot → HTTP POST → Node.js server → Anthropic API → Claude → response → Godot → display
```

### In Godot
- `send_to_llm(prompt, system)` sends request to `http://localhost:3000/llm`
- `_on_ollama_request_request_completed()` handles response
- `display_response(speaker, text)` shows response in ResponsePanel

### Response Speed
~1-3 seconds with Anthropic API. Far superior to local Ollama on CPU.

---

## 13 Icon UI Bar
| # | Icon | Input |
|---|---|---|
| 1 | History | Free text + LLM |
| 2 | Rapid Stability Assessment | Single button |
| 3 | Physical Exam | Free text + LLM |
| 4 | Labs | Browser + LLM search |
| 5 | Imaging | Modality + free text + LLM |
| 6 | Medications | Browser + LLM search |
| 7 | Consults | Contextual list |
| 8 | Surgeries & Procedures | Contextual list |
| 9 | Other Treatments | Contextual list |
| 10 | Airway | Subcategory menu |
| 11 | Pathology / Biopsy | Contextual list |
| 12 | Miscellaneous Tests | Category browser |
| 13 | Diagnosis | Free text + LLM |

**Quick Access (always visible): IV icon, O2 icon**

---

## Points System

### AP
Budget per case (appendicitis = 100 AP). Depleted = deterioration / fail.

### Bonus Points
Earned for targeted clinical knowledge. Dual use: offset harm OR bank for XP.

### Harm Points
Threshold = 7 (appendicitis). Reaching threshold → septic shock + AP reduced to 30.

### XP Formula
`base_xp + (remaining AP × 1) + (banked bonus × 3) - (harm × 10)`

---

## Medication System
~531 medications across 23 JSON files. No dosing in med files — lives in condition files.

### Medication Browser
Browse mode / LLM semantic mode. Med detail: route dropdown + dose free text.
Default 3 AP per med. IV without access → auto-place popup.

---

## Airway System
Icon 10. RSI checklist (free). Intubation 5 AP. Auto-vent: VC-AC, TV 500mL, RR 14, PEEP 5, FiO2 40%.

---

## Surgeries & Procedures
Appendectomy 10 AP → WIN → +10 bonus points → disposition prompt.
Arterial line 4 AP → ABG becomes 1 AP + A-line waveform vital sign.

---

## End Condition System
Post-appendectomy disposition: Hospital / ICU / Discharge (0 AP).
Lose: AP hits 0 OR unaffordable action → Mega Hospital transfer.
Unaffordable appendectomy → +3 bonus points on transfer.

---

## Other Treatments
NPO + IV before septic shock = +1 bonus each. All others 1 AP, 0 bonus.
Auto-bed triggers: IV placed / O2 started / septic shock.
Difficult Stick: IV costs 2 AP, 15% infiltration per 5 AP spent.

---

## Badge System
**Boost (13):** Badge Board / Dispenser (10 AP, draw 3 pick 1, stable only) / rewards
**Burnout (12):** Triggered at 5 harm OR 50 AP. Max 1 early / max 2 late.

---

## Sprite System
Layered sprites: Body → Head → Hair → Eyes → Glasses → Clothing → Overlays
Four tiers: Adult (100%) / Child (65-70%) / Toddler (body 45-50%, head 60-65%) / Baby (separate assets)
27 hair styles. Runtime color tinting via Godot modulate.

---

## Character Creator
Skin tone slider / Height 5 options / 27 hair styles / Hair+Eye color wheels / Glasses toggle / White coat always worn.

---

## MEDDY
Cute pixel art AI device companion. 6 sprite states. Popup feedback on all bonus/harm events.
Feedback text defined in `[condition]_system_prompts.json` via `meddy_commentary` prompt.

---

## Appendicitis Case

### Patient
Marcus, 22yo male, 6'0", 84kg, BMI 25.1, no allergies, no PMH

### States
| State | Trigger | HR | BP | RR | Temp | SpO2 |
|---|---|---|---|---|---|---|
| Stable | Start | 105 ±3 | 120/85 | 16 | 100.8°F | 99 |
| Perforated | 50 AP without appendectomy | 122 ±4 | 106/70 | 24 | 102.1°F | 98 |
| Septic Shock | 70 AP without appendectomy OR 7 harm points | 135 ±6 | 100/60 | 28 | 103.4°F | 95 |
| Coma/Fail | 100 AP | 148 ±2 | 80/40 | 32 | 104.2°F | 88 |

### Bonus Points: 34 total
History (2) + Exam (3) + Stability (2) + Consult (1) + Other Treatments (2) + Diagnosis (13) + Appendectomy (10) + Disposition (1)

### Scoring
Base 120 XP + remaining AP×1 + banked bonus×3 - harm×10

---

## Godot Project Settings
Renderer: Compatibility / Window: 1280×720 / Stretch: canvas_items / Texture Filter: Nearest

---

## MVP Sequence
1. ✅ Scene built — ClinicalEncounter.tscn
2. ✅ ClinicalEngine.gd — state machine, AP, bonus/harm
3. ✅ Vitals monitor working
4. ✅ History button wired up
5. ✅ Anthropic API connected — fast responses
6. ✅ Patient system prompt locked in clinically
7. ⬜ Wire remaining 12 icon buttons
8. ⬜ AP deduction on actions
9. ⬜ MEDDY popup system
10. ⬜ Confirmation popup
11. ⬜ Badge system
12. ⬜ Win/fail states
13. ⬜ Badge board + encounter selection
14. ⬜ Overworld + story

---

## Monetization
$10 base. DLC condition packs later.

---

## Session Log
- **Session 1:** Concept, architecture, platform
- **Session 2:** Action registry, appendicitis condition file
- **Session 3:** Full medication database (23 files, ~531 meds)
- **Session 4:** Badge system
- **Session 5:** Other treatments fully defined
- **Session 6:** Airway icon (13th icon)
- **Session 7:** MEDDY designed. Asset folder structure finalized.
- **Session 8:** Character creator — layered sprite system
- **Session 9:** Unified sprite tier system
- **Session 10:** Full UI asset folder structure
- **Session 11:** Surgeries & procedures schema
- **Session 12:** End conditions fully defined
- **Session 13:** Godot project initialized
- **Session 14:** ClinicalEncounter scene built, ClinicalEngine.gd written
- **Session 15:** Vitals monitor fixed, basic layout working
- **Session 16:** History button wired, Submit button wired, Ollama integrated
- **Session 17:** Switched to Anthropic API via Node.js backend — fast responses
- **Session 18:** Patient personality schema defined. Full clinical system prompt written for appendicitis. appendicitis_system_prompts.json created.
