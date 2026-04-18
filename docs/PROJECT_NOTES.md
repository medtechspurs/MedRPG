# MedRPG — Project Notes
*Single source of truth. Update this file every session.*

---

## Concept
Retro pixel art RPG where player is a doctor traveling a world map curing patients. Clinical encounters are turn-based. Player uses 13 icon categories to interact with patients. A local LLM (Ollama) parses free text for History, Physical Exam, Medications, and Diagnosis. Everything else is list/browser-based.

---

## Platform & Stack
- **Engine:** Godot 4 (GDScript)
- **Primary target:** PC / Steam
- **Secondary:** Mac / Linux via Godot export
- **Art:** LPC sprites + Itch.io tilesets (placeholder)
- **LLM:** Ollama local — Phi-3 Mini or Llama 3.2 3B
- **Git repo:** `C:\Users\jmcar\OneDrive\Documents\Coding Projects\MedRPG`
- **Godot project root:** `C:\Users\jmcar\OneDrive\Documents\Coding Projects\MedRPG\game\med-rpg\`

---

## File Structure
```
MedRPG/
├── docs/
│   └── PROJECT_NOTES.md
├── game/
│   └── med-rpg/                   ← Godot project root (project.godot lives here)
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
│       │   │   ├── appendicitis_other_treatments.json
│       │   │   ├── appendicitis_surgeries_procedures.json
│       │   │   └── appendicitis_end_conditions.json
│       │   └── medications/
│       │       └── (23 medication JSON files)
│       ├── scenes/
│       ├── scripts/
│       └── assets/
│           ├── sprites/
│           │   └── characters/
│           │       ├── meddy/
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

## UI Icons Needed (created later)
**13 Icon Bar:** icon_history, icon_stability, icon_exam, icon_labs, icon_imaging, icon_medications, icon_consults, icon_surgeries, icon_other_treatments, icon_airway, icon_pathology, icon_misc_tests, icon_diagnosis
**Quick Access:** icon_iv, icon_o2

---

## Sprite System

### Layer Stack (bottom to top)
```
Layer 1 — Body (torso + limbs)     grayscale, skin tone tinted at runtime
Layer 2 — Head                     grayscale, skin tone tinted at runtime
Layer 3 — Hair                     grayscale, hair color tinted at runtime
Layer 4 — Eyes                     grayscale, eye color tinted at runtime
Layer 5 — Glasses                  optional overlay
Layer 6 — Clothing                 varies by character type
Layer 7 — Ad hoc overlays          IV line, O2 mask, pain expression, etc.
```

### Four Sprite Tiers
| Tier | Body | Head | Hair | Clothing | Scale |
|---|---|---|---|---|---|
| Adult | `body\` | `head\` | `hair\` | `clothing\` | 100% |
| Child | `body\` | `head\` | `hair\` | `clothing\` | 65-70% |
| Toddler | `body\` | `head\` | `hair\` | `clothing\` | body 45-50%, head 60-65% |
| Baby | `body_baby\` | `head_baby\` | `hair_baby\` | `clothing_baby\` | own proportions |

### Hair Styles
**Adult/Child/Toddler (27):** Shaved, Bald, Short/Medium/Shoulder/Long × Straight/Wavy/Curly, Braided Short/Medium/Long, Natural Very Short/Short/Medium/Large
**Baby:** Baby Short, Baby Medium only

### Clothing Variants
coat_white (player), clothes_hospital_gown, clothes_casual_male/female/child/toddler, clothes_scrubs, clothes_suit, clothes_onesie (baby)

---

## Character Creator
- Skin tone: gradient slider
- Height: 5 options (adult)
- Hair style: 27 styles grid
- Hair color + Eye color: color wheels
- Glasses: toggle
- White coat: always worn

---

## MEDDY — Companion AI Device
Cute pixel art mobile computer / AI EMR companion. Stands next to player during encounters. Reacts via popup messages to all bonus/harm events.

**Sprite states:** neutral, excited, worried, alarmed, thinking, celebrating
**Popup text** defined per-event in condition JSON via `meddy_feedback` field. Auto-dismisses 3–4 seconds.

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
Browse mode (category + filter) / LLM semantic mode (Ollama → ranked list).
Med detail: route dropdown + dose free text. Default 3 AP per med.

### IV Without Access
Auto-places IV via popup. Normal +1 AP / Difficult Stick +2 AP. Never earns bonus point.

### Dose Scoring
`correct_dose` + `correct_dose_aliases`. Correct = bonus points. Wrong = nothing.

---

## Airway System
Icon 10. Subcategories: Basic Maneuvers, Adjuncts, BMV, Intubation, Surgical Airway, Ventilator Settings, Extubation.

### Intubation (RSI) — 5 AP
MEDDY RSI safety checklist (free). Player checks boxes — engine verifies independently.

**Harm point rules:**
| Scenario | Harm Points |
|---|---|
| Intubate in stable or perforated | 2 |
| Intubate in septic shock | 0 |
| No paralytic | 2 |
| No sedation — immediate | 5 |
| Each action without sedation post-intubation | 5 per action |
| Sedation given post-intubation | stops accrual, prior harm stays |

**Auto-vent on intubation:** VC-AC, TV 500mL, RR 14, PEEP 5, FiO2 40%

---

## Surgeries & Procedures

### Appendectomy — 10 AP — WIN CONDITION — +10 bonus points
Prerequisites: imaging (CT/XR/US) OR general surgery consult.

| State | Allowed | Harm | Notes |
|---|---|---|---|
| Stable | Yes | 0 | |
| Perforated | Yes | 0 | |
| Septic Shock | Yes | 0 if resuscitated, 2 if not | Needs fluids + vasopressor first |
| Coma/Fail | No | — | Too late |

### Arterial Line — 4 AP
Unlocks: ABG → 1 AP (from 6 AP). New vital: continuous A-line waveform on monitor.

### Central Line — 5 AP
Appropriate in septic shock. No direct progression effect.

### Other procedures (no effect): Thoracentesis 6 AP, Paracentesis 6 AP, LP 6 AP

---

## End Condition System

### Win
Appendectomy completed → +10 bonus points → disposition prompt.

### Disposition Prompt (0 AP, post-appendectomy)
MEDDY asks: *"Where are we sending this patient?"*

| State | Hospital Floor | ICU | Discharge Home |
|---|---|---|---|
| Stable | +1 bonus ✓ | overridden → floor | +1 bonus ✓ |
| Perforated | +1 bonus ✓ | overridden → floor | 0 bonus |
| Septic Shock | 1 harm, overridden → ICU | +1 bonus ✓ | 2 harm, overridden → ICU |

**Endings:**
- Admission: ambulance arrives, patient whisked away
- Discharge home: patient walks out

### Lose Conditions
- **AP hits 0:** coma/fail → ambulance to Mega Hospital, encounter lost
- **Unaffordable action:** MEDDY popup → Yes = lose (0 bonus) / No = dismiss
- **Unaffordable appendectomy:** same popup → Yes = lose + **3 bonus points**

---

## Other Treatments System

### Auto-Bed Triggers (appendicitis)
IV established / O2 started / septic shock state.

### IV Access
| Scenario | AP | Bonus |
|---|---|---|
| Proactive before septic shock | 2 | +1 |
| Proactive after septic shock | 1 | 0 |
| Via popup | 1 or 2 | never |

### Difficult Stick Infiltration
Every 5 AP spent → 15% infiltration → IV resets → 2 AP to replace.

### NPO
Before septic shock: 2 AP, +1 bonus. After: 1 AP, 0 bonus.

### Other (all 1 AP, 0 bonus)
O2 (auto-bed), Foley, NG Tube, Fall Precautions, Strict I&Os.

---

## Badge System

### Boost (13)
Badge Board / Dispenser (10 AP, draw 3 pick 1, stable, once/encounter early) / rewards.

### Burnout (12)
Triggered at 5 harm OR 50 AP remaining. Random. Max 1 early / max 2 late.
Pre-attached on some encounters = higher XP reward.

---

## Appendicitis Case

### Patient
22yo male, 6'0", 84kg, BMI 25.1, no allergies, no PMH

### States
| State | Trigger | HR | BP | RR | Temp | SpO2 |
|---|---|---|---|---|---|---|
| Stable | Start | 105 ±3 | 120/85 | 16 | 100.8°F | 99 |
| Perforated | 50 AP without appendectomy | 122 ±4 | 106/70 | 24 | 102.1°F | 98 |
| Septic Shock | 70 AP without appendectomy OR 7 harm points | 135 ±6 | 100/60 | 28 | 103.4°F | 95 |
| Coma/Fail | 100 AP | 148 ±2 | 80/40 | 32 | 104.2°F | 88 |

### Total Available Bonus Points: 34
| Source | Points |
|---|---|
| History | 2 |
| Physical Exam | 3 |
| Rapid Stability Assessment | 2 |
| Consult | 1 |
| Other Treatments (NPO + IV) | 2 |
| Diagnosis | 13 |
| Appendectomy | 10 |
| Disposition | 1 |
| **Total** | **34** |

### Scoring
Base 120 XP + remaining AP×1 + banked bonus×3 - harm×10

---

## Godot Project Settings
- Renderer: Compatibility
- Window: 1280×720
- Stretch Mode: canvas_items
- Stretch Aspect: keep
- Default Texture Filter: Nearest (critical for pixel art)

---

## MVP Sequence
1. Single encounter, appendicitis
2. Character creator
3. Free text → Ollama → action registry
4. AP counter + state machine
5. MEDDY UI + popups
6. Badge system
7. Win/fail/disposition states
8. Badge board + encounter selection
9. Overworld, story, more conditions

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
- **Session 8:** Character creator — layered sprite system, 27 hair styles, color wheels, height, glasses
- **Session 9:** Unified sprite tier system — adult/child/toddler share assets, baby separate. Head as own layer.
- **Session 10:** Full UI asset folder structure.
- **Session 11:** Surgeries & procedures — appendectomy, intubation RSI checklist, arterial line unlocks.
- **Session 12:** End conditions fully defined — disposition, MEDDY overrides, ambulance, Mega Hospital. Bonus points = 34.
- **Session 13:** Godot project initialized. Project moved to game\med-rpg\. .gitignore added. Pixel art settings configured.
