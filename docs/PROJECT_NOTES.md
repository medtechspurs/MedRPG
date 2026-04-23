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
- **LLM:** Anthropic API (Claude Sonnet 4.5) via Node.js backend server
- **Git repo:** `C:\Users\jmcar\OneDrive\Documents\Coding Projects\MedRPG`
- **Godot project root:** `C:\Users\jmcar\OneDrive\Documents\Coding Projects\MedRPG\game\med-rpg\`
- **Backend server:** `C:\Users\jmcar\OneDrive\Documents\Coding Projects\MedRPG\server\`

---

## Backend Server
Node.js server on `http://localhost:3000`. Proxies all LLM requests to Anthropic API.

**To run:** `cd server && node server.js`
**For production:** Deploy to cloud server (e.g. $5/month DigitalOcean droplet)

**Endpoints:**
- `GET /health` — health check
- `POST /llm` — send prompt + system, receive response

**Model:** `claude-sonnet-4-5`

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
│           ├── sprites/
│           │   └── characters/
│           │       ├── meddy/
│           │       │   ├── meddy_neutral.png         ← static neutral sprite
│           │       │   └── MeddyBlinkAnimationSpriteSheet.png ← idle animation sheet
│           │       ├── player/
│           │       │   ├── body/
│           │       │   ├── body_baby/
│           │       │   ├── head/
│           │       │   ├── head_baby/
│           │       │   ├── hair/
│           │       │   ├── hair_baby/
│           │       │   ├── clothing/
│           │       │   ├── clothing_baby/
│           │       │   └── extras/
│           │       ├── patients/
│           │       │   └── patient_young_male/
│           │       └── npcs/
│           ├── badges/
│           │   ├── boost/
│           │   ├── burnout/
│           │   └── badge_reel.png
│           ├── ui/
│           │   ├── icons/
│           │   ├── panels/
│           │   ├── buttons/
│           │   ├── fonts/
│           │   └── hud/
│           ├── backgrounds/
│           └── audio/
├── exports/
└── reference/
```

---

## Current Scene Structure (clinical_encounter.tscn)
```
ClinicalEncounter (Node2D) ← clinical_engine.gd attached
├── HUD (CanvasLayer, layer 10)
│   ├── APBar (HBoxContainer) → APLabel, APValue
│   ├── BonusPoints (HBoxContainer) → BonusLabel, BonusValue
│   └── HarmPoints (HBoxContainer) → HarmLabel, HarmValue
├── IconBar (CanvasLayer)
│   ├── IconContainer (HBoxContainer) → 13 buttons
│   └── QuickAccess (HBoxContainer) → IVBtn, O2Btn
├── InputArea (CanvasLayer)
│   └── InputPanel → InputRow → InputField (LineEdit) + SubmitBtn
├── PopupLayer (CanvasLayer, layer 20)
│   └── PopupContent (PanelContainer, hidden by default)
│       └── PopupVBox → PopupMessage + PopupButtons → ConfirmBtn + CancelBtn
├── ResponseLayer (CanvasLayer, layer 5)
│   └── ResponsePanel (hidden by default)
│       └── ResponseContent → ResponseSpeaker + ResponseText
├── Background (Node2D)
├── PatientArea (Node2D)
│   ├── PatientSprite (Node2D) → Body, Head, Hair, Eyes, Glasses, Clothing
│   └── Bed (Sprite2D)
├── PlayerArea (Node2D)
│   ├── PlayerSprite (Node2D) → Body, Head, Hair, Eyes, Glasses, Clothing
│   └── Meddy (Node2D)
│       ├── MeddySprite (AnimatedSprite2D) ← idle animation playing
│       └── MeddyPopup (CanvasLayer, hidden)
│           └── PopupPanel → PopupLabel
├── Monitor (Node2D, position ~900, 20)
│   ├── MonitorBackground (Sprite2D)
│   └── VitalsContainer (VBoxContainer)
│       ├── HRRow → HRTitle + HRValue
│       ├── BPRow → BPTitle + BPValue
│       ├── RRRow → RRTitle + RRValue
│       ├── TempRow → TempTitle + TempValue
│       ├── SpO2Row → SpO2Title + SpO2Value
│       └── ALineWaveform (HBoxContainer, hidden) → ALineTitle + ALineValue
└── OllamaRequest (HTTPRequest) ← handles all API calls
```

---

## MEDDY Sprite System

### Current Status
- ✅ Neutral static sprite: `meddy_neutral.png` (325x572 trimmed, displayed at scale 0.42)
- ✅ Idle animation: `MeddyBlinkAnimationSpriteSheet.png` (10 frames, playing as AnimatedSprite2D)
- ⬜ Excited animation
- ⬜ Worried animation
- ⬜ Alarmed animation
- ⬜ Thinking animation
- ⬜ Celebrating animation

### MEDDY Sprite States
| State | Trigger |
|---|---|
| idle | Default, always playing |
| excited | Bonus point earned |
| worried | Harm point triggered |
| alarmed | Patient deteriorating |
| thinking | LLM processing |
| celebrating | Correct diagnosis |

### MEDDY Animation Workflow
1. Generate base image in **ChatGPT**
2. Convert to pixel art in **Pixelicious** (pixelicious.xyz) — 128px grid
3. Clean up / trim in **Aseprite**
4. Generate animation frames in **PixelLab** (pixellab.ai)
   - Max input size: 256x256
   - Export as individual PNGs (0001, 0002, etc.)
5. Import frames into **Aseprite** (File → Open all frames as animation)
6. Adjust frame timing (~100-150ms per frame)
7. Export as horizontal sprite sheet PNG
8. Import into Godot as AnimatedSprite2D SpriteFrames

### PixelLab Idle Animation Prompt
*"Idle animation. Consistent sprite size. Subtle breathing motion. Knees flex up and down, elbows flex and unflex, green eyes and smile pulsing with light, looping idle animation, standing still. All frames same size, seamless loop."*

### Aseprite Tips
- Remove background: Eraser tool (E) at high zoom
- Trim transparent border: Sprite → Trim
- Check dimensions: F4
- Extend canvas without scaling: Sprite → Canvas Size
- Frame timing: Right-click frame in timeline → Frame Properties
- Import multiple frames as animation: File → Open all PNGs at once → Yes to animation prompt
- Files must be in folder with no spaces in path, short filenames

### Godot AnimatedSprite2D Setup
- Change node type from Sprite2D to AnimatedSprite2D
- Inspector → Sprite Frames → New SpriteFrames
- SpriteFrames panel → rename animation to `idle`
- Add Frames from Sprite Sheet → set correct frame width (check dimensions)
- Set FPS to ~10, enable loop
- Set Autoplay to `idle`

---

## LLM Integration

### Flow
```
Player input → Godot → HTTP POST → Node.js server → Anthropic API → Claude → response → Godot → display
```

### Two-Call System (History)
- **Call 1:** Cost detection — Claude classifies domains, returns JSON with AP cost
- **Popup:** Shows cost, player confirms or cancels
- **Call 2:** Patient response — Claude responds as Marcus

### Response Display
- ResponsePanel (top center of screen) shows patient/MEDDY responses
- Speaker label + wrapped response text
- Hidden by default, shown on response

---

## History Domain System

### Domain AP Costs
| Domain | AP Cost | Once Only? |
|---|---|---|
| overview | 1 | Yes |
| symptom_drill (per symptom) | 1 | Per new symptom |
| Further drill same symptom | 0 | Free |
| review_of_systems | 1 | Yes |
| pmh_surgical | 1 | Yes — covers both |
| medications | 1 | Yes |
| allergies | 1 | Yes |
| social_travel_exposure | 1 | Yes |
| family_history | 1 | Yes |
| sexual_history | 1 | Yes — blocked in family friendly mode |
| Multiple domains one question | Stacked | Each charged once |

### Tracking in GDScript
```gdscript
var history_domains_asked: Array = []
var history_symptoms_drilled: Array = []
var family_friendly_mode: bool = false
```

### Flow
1. Player types history question → clicks Send
2. `detect_history_cost()` → Call 1 to Claude
3. Claude returns JSON: `{"new_domains": [...], "new_symptoms": [...], "ap_cost": 1}`
4. If cost = 0 → skip popup, go straight to patient
5. If cost > 0 → show popup with cost
6. Player confirms → `spend_ap()` → `send_history_to_patient()` → Call 2
7. Patient responds, domain tracking updated

---

## Physical Exam System

### Validation
- Call 1: Claude validates input is ONE specific body system or maneuver
- VALID → patient reacts to exam
- INVALID → MEDDY redirects: "Try one specific area or maneuver at a time"

---

## Patient Personality Schema
Every condition includes `patient_personality` in condition JSON and companion `[condition]_system_prompts.json`.

### Appendicitis Patient (Marcus)
- Age: 22, male, college student
- Analytical: 5/10, Speech: 11th grade, Dialect: Standard USA
- Friendly, cooperative, anxious but calm, pain 7/10
- No agendas, forthcoming communication style

---

## 13 Icon UI Bar
| # | Button | Mode | AP Cost |
|---|---|---|---|
| 1 | Hx | history | 1 per domain |
| 2 | Stab | stability | 2 |
| 3 | Exam | exam | 2 |
| 4 | Labs | labs | varies |
| 5 | Ima | imaging | 8 |
| 6 | Med | medications | 3 |
| 7 | Con | consults | 7 |
| 8 | Sur | surgeries | 10 |
| 9 | Tx | other_treatments | 2 |
| 10 | Air | airway | 5 |
| 11 | Path | pathology | 4 |
| 12 | Misc | misc_tests | 5 |
| 13 | Dx | diagnosis | 0 |

**Quick Access:** IV (2 AP), O2 (1 AP)

### UI Keyboard Controls
- **Enter** — submits input field OR confirms popup
- **Escape** — cancels popup
- **Left/Right arrows** — toggle between Confirm/Cancel buttons
- **White border** = focused button (unambiguous selection indicator)

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
Pre-attached on some encounters = higher XP reward.

---

## Sprite System
Layered sprites: Body → Head → Hair → Eyes → Glasses → Clothing → Overlays
Four tiers: Adult (100%) / Child (65-70%) / Toddler (body 45-50%, head 60-65%) / Baby (separate assets)
27 hair styles. Runtime color tinting via Godot modulate.

---

## Character Creator
Skin tone slider / Height 5 options / 27 hair styles / Hair+Eye color wheels / Glasses toggle / White coat always worn.
**Family Friendly Mode** — chosen at character creation screen. Blocks sexual history questions.

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
4. ✅ All 13 buttons + IV + O2 wired up
5. ✅ Confirmation popup — keyboard nav, white focus ring
6. ✅ Anthropic API connected — fast responses
7. ✅ Patient system prompt locked in clinically
8. ✅ Exam validation layer working
9. ✅ History domain AP system — two-call architecture
10. ✅ MEDDY idle animation in game
11. ⬜ Labs system — objective data from condition file
12. ⬜ Diagnosis evaluation
13. ⬜ MEDDY emotional animations wired to events
14. ⬜ Bonus/harm point events firing
15. ⬜ AP visual feedback / state transitions
16. ⬜ Badge system
17. ⬜ Win/fail states
18. ⬜ Badge board + encounter selection
19. ⬜ Overworld + story

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
- **Session 16:** History button wired, Submit button wired
- **Session 17:** Switched to Anthropic API via Node.js backend
- **Session 18:** Patient personality schema, full clinical system prompt
- **Session 19:** All 14 buttons wired, confirmation popup complete, keyboard nav
- **Session 20:** Exam validation layer, MEDDY idle animation in game
- **Session 21:** History domain AP system — two-call architecture, domain tracking, free re-queries
