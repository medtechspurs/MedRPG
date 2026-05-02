# MedRPG — Project Notes
*Single source of truth. Update this file every session.*

---

## Concept
Retro pixel art RPG where player is a doctor traveling a world map curing patients. Clinical encounters are turn-based. Player uses 13 icon categories + quick access buttons to interact with patients. Input classified by LLM, routed to authored responses in shipped game.

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
**Model:** `claude-sonnet-4-5`
**Endpoints:** `GET /health` / `POST /llm`

---

## Developer Toggles (clinical_engine.gd)
```gdscript
const DEV_MODE_LLM: bool = true          # true = live LLM, false = authored responses
const DEV_MODE_SKIP_CONFIRM: bool = false # true = skip AP popups (auto-runs only)
```
**Before shipping:** Delete all DEV_MODE_LLM code paths and auto-runner script entirely.

---

## JSON Schema Versioning Rule
**All JSON files must include `schema_version` as the first field.**
- Current version: `"1.0"`
- Bump to `"1.1"` for non-breaking additions
- Bump to `"2.0"` for breaking schema changes

---

## File Structure
```
MedRPG/
├── docs/
│   ├── PROJECT_NOTES.md
│   └── AUTHORED_RESPONSE_SYSTEM.md    ← full authored response architecture
├── server/
│   ├── server.js
│   ├── package.json
│   └── node_modules/
├── game/
│   └── med-rpg/
│       ├── .gitignore
│       ├── project.godot
│       ├── data/
│       │   ├── master_categories.json     ← global category list for all conditions
│       │   ├── action_registry.json
│       │   ├── airway.json
│       │   ├── badges/
│       │   │   ├── boost_badges.json
│       │   │   ├── burnout_badges.json
│       │   │   └── badge_youtock_dialogue.json
│       │   ├── conditions/
│       │   │   ├── appendicitis.json
│       │   │   ├── appendicitis_system_prompts.json
│       │   │   ├── appendicitis_other_treatments.json
│       │   │   ├── appendicitis_surgeries_procedures.json
│       │   │   └── appendicitis_end_conditions.json
│       │   ├── medications/
│       │   │   └── (23 medication JSON files)
│       │   └── responses/
│       │       ├── appendicitis/
│       │       │   ├── history_responses.json
│       │       │   ├── exam_responses.json
│       │       │   ├── meddy_responses.json
│       │       │   ├── ask_meddy_responses.json
│       │       │   └── deflection_responses.json
│       │       └── coverage_reports/      ← auto-runner output
│       ├── scenes/
│       │   └── clinical_encounter.tscn
│       ├── scripts/
│       │   ├── clinical_engine.gd
│       │   └── auto_runner.gd             ← dev only, deleted before shipping
│       └── assets/
│           ├── sprites/characters/
│           │   ├── meddy/
│           │   │   ├── meddy_neutral.png
│           │   │   └── MeddyBlinkAnimationSpriteSheet.png
│           │   ├── player/
│           │   │   ├── body/ head/ hair/ clothing/ extras/
│           │   │   └── body_baby/ head_baby/ hair_baby/ clothing_baby/
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

## Authored Response System
*Full architecture in `docs/AUTHORED_RESPONSE_SYSTEM.md`*

### Overview
All patient dialogue and MEDDY content is pre-authored and physician-reviewed. LLM used only for input classification in shipped game.

### Pipeline
1. **Auto-runner** generates test inputs (LLM plays as doctor)
2. **Coverage reports** exported to `data/responses/coverage_reports/`
3. **Human review** — physician curates best responses
4. **Answer bank** built in response JSON files
5. **Local classifier** trained eventually for offline classification

### Answer Bank Structure
```json
{
  "schema_version": "1.0",
  "category": "symptom_drill_pain",
  "variants": [
    {
      "id": "pain_first_ask",
      "priority": 3,
      "conditions": {
        "domains_asked": [],
        "patient_state": "any"
      },
      "answers": ["Answer option 1", "Answer option 2"],
      "speaker": "patient"
    }
  ],
  "fallback_answer": "Can we focus on what's going on with me right now?"
}
```

### Master Categories (42 total)
- **History (14):** overview, symptom_drill_pain/nausea/fever/appetite/bowel/urinary, review_of_systems, pmh_surgical, medications, allergies, social_travel_exposure, family_history, sexual_history
- **Physical Exam (17):** exam_general/abdomen/cardiovascular/respiratory/neurological/skin/heent/musculoskeletal/genitourinary/rectal/breast + maneuver_mcburneys/rovsing/psoas/obturator/rebound/murphy/other
- **Ask MEDDY (5):** meddy_general_knowledge, meddy_differential, meddy_condition_tests, meddy_condition_treatment, meddy_finding_significance
- **Irrelevant (1):** catch-all deflection

*New categories can be added anytime — just add to `master_categories.json` and create corresponding response entries.*

---

## MEDDY Sprite System

### Current Status
- ✅ Idle animation: `MeddyBlinkAnimationSpriteSheet.png` (10 frames, AnimatedSprite2D)
- ⬜ Excited, Worried, Alarmed, Thinking, Celebrating animations

### Animation Workflow
1. Generate in **ChatGPT** → convert in **Pixelicious** → clean in **Aseprite** → animate in **PixelLab** → import to Godot
2. PixelLab idle prompt: *"Idle animation. Consistent sprite size. Subtle breathing motion. Knees flex up and down, elbows flex and unflex, green eyes and smile pulsing with light, looping idle animation, standing still. All frames same size, seamless loop."*
3. Export from PixelLab as individual PNGs → import to Aseprite → export as horizontal sprite sheet
4. In Godot: AnimatedSprite2D → SpriteFrames → frame width 256px → ~10 FPS → loop

---

## Game Modes

### Balatro Run Mode (build first)
- 3 random cases per run
- Cases pulled from full case library
- Badges accumulate across run
- Between cases: Badge Board (spend XP), encounter selection (3 options)

### Themed Runs (future DLC)
- Trauma Run, Infectious Disease Run, Cardiology Run, Pediatrics Run, ICU Run, Night Float Run
- Natural DLC packs — themed run + new cases + specialty badges

### RPG Overworld Mode (future)
- World map, story, linear progression
- Add after Balatro mode is complete and polished

---

## Personal Difficulty Scaling
Per-case performance tracked across runs:
- AP remaining, turns taken, bonus points, harm points
- If case crushed → next time: less AP, faster decompensation, pre-attached Burnout Badge, comorbidities
- **Difficulty tiers (appendicitis example):**

| Tier | AP | Decompensation | Burnout Badges | Comorbidities |
|---|---|---|---|---|
| 1 | 100 | Standard | 0 | None |
| 2 | 85 | 10% faster | 1 | Obese |
| 3 | 70 | 25% faster | 1 | Diabetic |
| 4 | 55 | 40% faster | 2 | Warfarin + diabetic |
| 5 | 40 | 50% faster | 2 | Complex, atypical |

---

## Turn Counter
- Every confirmed action = 1 turn (even free AP actions)
- Display near AP/Bonus/Harm in HUD
- Turn 10 → draw Burnout Badge (early game max 1, late game max 2)
- Creates pressure alongside AP — efficiency on two axes

---

## Badge System

### Boost Badges (13 + new)
Acquired via Badge Board (XP) / Badge Dispenser (10 AP, draw 3 pick 1, stable only) / mid-encounter rewards / critical hit chance (5% per bonus point earned)

**Diminishing returns:** Multiple badges less impactful, situational by design

### Burnout Badges (12 + new)
Triggered at 5 harm OR 50 AP remaining OR turn 10. Random from pool.
Early game: max 1. Late game: max 2. Pre-attached on some encounters = higher XP.

### New Badges Designed
| ID | Name | Type | Effect |
|---|---|---|---|
| boost_universal_healthcare | Universal Coverage | Boost | All actions -1 AP, non-emergent has 2-turn wait |
| boost_prayer | Thoughts & Prayers | Boost | 20% chance +1 AP per turn, 10% chance -1 harm per turn, heavenly glow |
| burnout_insurance_denial | Prior Auth Required | Burnout | 50% non-life-saving actions denied, AP still charged. CEO laughs counting money. Peer-to-peer 2AP/20% success, prior auth 3AP/50% success |
| burnout_national_backorder | National Backorder | Burnout | 33% chance med on backorder, AP charged, 40% chance stays backordered on retry |
| burnout_youtock | YouTock University | Burnout | 50% refuse meds/vaccines/procedures, funny refusal quotes, education attempts declined politely |

*(Full YouTock dialogue in `badge_youtock_dialogue.json`)*

---

## Ask MEDDY System
- Dedicated button above MEDDY's head on encounter screen
- Costs 2-4 AP depending on question type
- Uses conversation log as context for differential diagnosis
- All responses authored (not live LLM in shipped game)
- Accessible to non-medical players as learning tool

### MEDDY Hints
- Triggers if no clinical progress after X turns
- Triggers if AP drops critically without key actions
- Triggers on clinically wrong decisions
- Never condescending, always encouraging

---

## PPE System
- PPE button on main UI near IV and O2 quick access
- Required before physical exam or procedures
- Not donning appropriate PPE = 1 harm point
- One-time action per encounter
- For appendicitis: standard precautions (gloves + mask)
- Future: contact/droplet/airborne/full PPE for infectious cases

---

## Accessibility & Difficulty Modes
- **Tourist Mode** — MEDDY very proactive, suggests next steps
- **Attending Mode** — MEDDY helpful, larger Ask MEDDY radius
- **Resident Mode** — occasional nudges if going wrong direction
- **Med Student Mode** — full game, MEDDY only answers when asked
- **Family Friendly Mode** — blocks sexual history, age-appropriate content

---

## Character Creator

### Doctor Sprite
- Male and female base sprites (different body/face, same hair assets)
- Layered system: Body → Head → Hair → Beard (male) → Eyes → Glasses → White coat
- Skin tone: horizontal gradient slider
- Hair styles (13, shared male/female): Bald, Short/Medium/Long straight, Short/Medium/Long natural African, Short/Medium/Long braids, Short/Medium wavy
- Beard (male only): None, Short, Medium
- Hair color + Eye color: color wheels
- Glasses: toggle
- White coat: always worn

### Patient / NPC Sprites
- Same layered asset system as doctor
- Different clothing layer per character type
- Four tiers: Adult (100%) / Child (65-70%) / Toddler (body 45-50%, head 60-65%) / Baby (separate assets)

### Patient Visual States (appendicitis)
- **Standing** — default, slightly hunched, hand on right side, casual clothes
- **In hospital bed** — triggered by IV access / O2 / septic shock. Hospital gown.

---

## 13 Icon UI Bar + Quick Access
| # | Button | Mode | AP Cost |
|---|---|---|---|
| 1 | Hx | history | 1 per question |
| 2 | Stab | stability | 2 |
| 3 | Exam | exam | 2 (free repeat) |
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

**Quick Access (always visible):** IV (2 AP), O2 (1 AP), PPE (1 AP), Ask MEDDY (2-4 AP)

**Input field max length:** 150 characters

**Keyboard:** Enter = submit/confirm, Escape = cancel, Left/Right = toggle confirm/cancel

---

## Points System
- **AP:** 100 per case. Every action costs AP. Depleted = fail.
- **Turns:** Every confirmed action = 1 turn. Turn 10 triggers Burnout Badge.
- **Bonus Points:** Clinical excellence. Offset harm OR bank for XP.
- **Harm Points:** Threshold 7. Triggers septic shock + AP capped at 30.
- **XP Formula:** `base_xp + (remaining AP × 1) + (banked bonus × 3) - (harm × 10)`

---

## Appendicitis Case

### Patient: Marcus
22yo male, 6'0", 84kg, BMI 25.1, no allergies, no PMH, college student

### States
| State | Trigger | HR | BP | RR | Temp | SpO2 |
|---|---|---|---|---|---|---|
| Stable | Start | 105 ±3 | 120/85 | 16 | 100.8°F | 99 |
| Perforated | 50 AP without appendectomy | 122 ±4 | 106/70 | 24 | 102.1°F | 98 |
| Septic Shock | 70 AP without appendectomy OR 7 harm points | 135 ±6 | 100/60 | 28 | 103.4°F | 95 |
| Coma/Fail | 100 AP | 148 ±2 | 80/40 | 32 | 104.2°F | 88 |

### Bonus Points: 34 total
History (2) + Exam (3) + Stability (2) + Consult (1) + Other Treatments (2) + Diagnosis (13) + Appendectomy (10) + Disposition (1)

---

## Achievements (pixel art badge for each)
| ID | Name | Description |
|---|---|---|
| first_diagnosis | First Blood | First correct diagnosis |
| speed_demon | Speed Demon | Complete case under 15 turns |
| textbook | Textbook | Earn every bonus point |
| oops | Oops | Trigger septic shock |
| miracle_worker | Miracle Worker | Prayer badge saves the run |
| thorough | Thorough | Ask every possible history domain |
| sharpshooter | Sharpshooter | Correct diagnosis without Ask MEDDY |
| frequent_flyer | Frequent Flyer | Send 10 patients to Mega Hospital |
| boy_scout | Boy Scout | Place IV before any other action |
| insurance_nightmare | Insurance Nightmare | Get denied 5 times in one run |
| i_did_my_research | I Did My Own Research | Treat YouTock patient despite 5 refusals |
| respectfully_disagree | Respectfully Disagree | Patient declines education attempt |

---

## Godot Project Settings
Renderer: Compatibility / Window: 1280×720 / Stretch: canvas_items / Texture Filter: Nearest

---

## MVP Sequence
1. ✅ Scene built — ClinicalEncounter.tscn
2. ✅ ClinicalEngine.gd — state machine, AP, bonus/harm
3. ✅ Vitals monitor
4. ✅ All 13 buttons + IV + O2 wired
5. ✅ Confirmation popup — keyboard nav, white focus ring
6. ✅ Anthropic API connected
7. ✅ Patient system prompt locked in clinically
8. ✅ Exam validation layer
9. ✅ History domain AP system
10. ✅ Exam tracking — free re-examination
11. ✅ MEDDY idle animation
12. ✅ Dev toggles added
13. ✅ Master categories defined
14. ✅ Response folder structure created
15. ✅ Authored response system architecture documented
16. ⬜ AutoRunner.gd
17. ⬜ Coverage report export
18. ✅ Turn counter + HUD display
19. ✅ Time counter + HUD display
20. ⬜ Log system
20. ⬜ Ask MEDDY button + system
21. ⬜ PPE button
22. ⬜ Labs system
23. ⬜ Diagnosis evaluation
24. ⬜ MEDDY emotional animations
25. ⬜ Badge system implementation
26. ⬜ Win/fail states
27. ⬜ Balatro run mode + encounter selection
28. ⬜ Character creator screen

---

## Monetization
$10 base. DLC condition packs + themed runs later. School/institution licensing potential.

---

## Turn Counter & Time Counter

### Turn Counter
- `turn_count` increments on every confirmed action — including free AP (irrelevant deflections, repeat exams, repeat history)
- Increments via `increment_turn()` which also calls `check_burnout_triggers()`
- Turn 10 → triggers Burnout Badge draw
- Displayed in HUD: `HUD/TurnCounter/TurnValue`

### Time Counter
- `elapsed_seconds` increments every 1 second via a `Timer` node created in `_ready()`
- Clock runs continuously — never pauses during LLM wait
- `time_limit_active: bool = false` — off by default, activated by timed badges/game modes
- `time_limit_seconds: float = 36000.0` — 10 hours default (effectively disabled)
- When limit hit → same outcome as 0 AP (Mega Hospital transfer)
- To activate a time limit: set `time_limit_active = true` and `time_limit_seconds` to target value
- Displayed in HUD: `HUD/TimeCounter/TimeValue` in `HH:MM:SS` format

---

## Labs System

### UI Flow
1. Player clicks **Labs** button → Labs popup window opens
2. Popup has three ways to find and select labs:
   - **Search by description** (top bar): free text interpreted by LLM → returns matching labs by tag
   - **Search by name** (second bar): exact match on lab name or acronym (e.g. "CBC" or "complete blood count") → live dropdown of matches below
   - **Category browser** (main panel): scrollable vertical list of broad categories → click to expand → click lab to select
3. Labs can be selected from any of the three methods — selections accumulate
4. **"Order Selected Labs"** button → AP cost popup showing combined cost → Confirm or Cancel

### Lab Categories (broad, for UI browser)
General / Screening, Hematology, Chemistry / Metabolic, Liver / Hepatic, Renal, Cardiac, Inflammatory / Infection, Coagulation, Endocrine / Hormonal, Pulmonary / Blood Gas, Rheumatologic / Autoimmune, Toxicology / Drug Levels, Urinalysis, Microbiology / Cultures, Tumor Markers, Nutritional / Vitamins, Genetic / Molecular

*Labs can appear in multiple categories.*

### Lab Tag System
Each lab has a comprehensive tag array covering:
- **Organ system:** hematologic, hepatic, renal, cardiac, pulmonary, endocrine, GI, neurologic, musculoskeletal, reproductive
- **Category:** chemistry, hematology, coagulation, inflammatory, metabolic, hormonal, toxicology, urinalysis, culture, tumor_marker, nutritional, genetic
- **Body region:** abdomen, chest, pelvis, systemic
- **Clinical association:** tags linking to conditions/diagnoses (e.g. `appendicitis`, `anemia`, `sepsis`, `liver_disease`, etc.)
- **Clinical use:** screening, diagnosis, monitoring, preoperative

### Lab Result System
- Each lab has result ranges per patient state: `stable`, `perforated`, `septic_shock`, `coma_fail`
- Results are randomized within range each playthrough for replayability
- Example: WBC range 8–22 for appendicitis stable state
- Ranges based on real clinical literature

### JSON Structure
- **Master lab list:** `data/labs/master_labs.json` — all labs, tags, categories, AP costs
- **Condition-specific results:** `data/conditions/appendicitis_labs.json` — result ranges per state per lab

### AP Cost
- TBD per lab or per lab category — to be designed

---
- **Session 1-12:** Architecture, data layer, all JSON files
- **Session 13:** Godot initialized
- **Session 14:** Scene + ClinicalEngine.gd
- **Session 15:** Vitals monitor, basic layout
- **Session 16:** History + Submit buttons wired
- **Session 17:** Anthropic API via Node.js
- **Session 18:** Patient personality + system prompts
- **Session 19:** All 14 buttons, confirmation popup, keyboard nav
- **Session 20:** Exam validation, MEDDY idle animation
- **Session 21:** History domain AP system, two-call architecture
- **Session 22:** Authored response system designed, dev toggles, master categories, response folder structure, new badges designed, game modes planned, personal difficulty scaling, turn counter, achievements, character creator finalized
- **Session 23:** Migration session. Turn counter + time counter implemented in clinical_engine.gd and HUD. Labs system fully designed (UI flow, tag system, categories, result ranges, JSON structure). PROJECT_NOTES updated. AutoRunner design clarified — full encounter coverage, undifferentiated patient LLM persona, mode-constrained runs, free-text persona instructions, button lives on main scene.
