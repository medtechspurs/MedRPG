# MedRPG — Authored Response System Schema
*The architecture for pre-authored patient dialogue, MEDDY responses, and all game content.*
*This document is the single source of truth for the response authoring pipeline.*

---

## Overview

MedRPG uses a **classification + authored response** system for all patient dialogue and MEDDY content. No live LLM content generation in the shipped game. The LLM is used only for:

1. **Input classification** — routes player input to the correct answer bucket
2. **Auto-runner** — generates test inputs during development to discover conversation states
3. **Answer authoring** — generates candidate responses during development for human review

All responses in the shipped game have been reviewed and approved by a physician.

---

## Core Architecture

```
Player types input
        ↓
Classification Layer (LLM call)
        ↓
Returns: { category, confidence, conversation_state_flags }
        ↓
Answer Lookup (local, no API call)
        ↓
Select correct variant based on conversation state
        ↓
Display authored response
```

---

## Developer Toggles (clinical_engine.gd)

```gdscript
const DEV_MODE_LLM: bool = true          # true = live LLM responses (dev/auto-run)
                                          # false = authored responses (shipped game)
const DEV_MODE_SKIP_CONFIRM: bool = false # true = skip AP confirmation popups (auto-runs)
                                          # false = normal confirmation flow
```

**Before shipping:** Delete all DEV_MODE_LLM code paths and auto-runner script entirely.

---

## Answer Bank Structure

Each answer entry has the following schema:

```json
{
  "id": "unique_answer_id",
  "category": "classification_category_name",
  "condition_id": "appendicitis",
  "variants": [
    {
      "id": "variant_id",
      "priority": 1,
      "conditions": {
        "domains_asked": [],
        "domains_not_asked": [],
        "symptoms_drilled": [],
        "symptoms_not_drilled": [],
        "patient_state": "any",
        "flags": {}
      },
      "answers": [
        "Answer text option 1 — pick randomly from this array",
        "Answer text option 2 — slight variation for variety",
        "Answer text option 3"
      ],
      "speaker": "patient",
      "meddy_commentary": null
    }
  ],
  "fallback_answer": "I'm not sure I understand — can we focus on what's going on with me right now?",
  "questions_assigned": [],
  "auto_runner_generated": true,
  "physician_reviewed": false,
  "review_notes": ""
}
```

---

## Condition Fields Explained

### `conditions` object
Defines when this variant is applicable. All conditions must be met.

| Field | Type | Description |
|---|---|---|
| `domains_asked` | Array | History domains that MUST have been asked already |
| `domains_not_asked` | Array | History domains that must NOT have been asked yet |
| `symptoms_drilled` | Array | Symptoms already drilled in detail |
| `symptoms_not_drilled` | Array | Symptoms NOT yet drilled |
| `patient_state` | String | `"any"`, `"stable"`, `"perforated"`, `"septic_shock"`, `"coma_fail"` |
| `flags` | Dictionary | Any clinical flags — `iv_access`, `imaging_completed`, `diagnosis_correct`, etc. |

### `answers` array
Multiple answer strings per variant. Game picks one randomly on each trigger. Provides natural variation without needing more variants. Aim for 2-4 options per variant.

### `priority`
Lower number = checked first. Highest priority variant whose conditions are met is selected.

### `speaker`
- `"patient"` — Marcus speaks
- `"meddy"` — MEDDY speaks
- `"clinical"` — Pure clinical finding, no dialogue (used for sensitive exams)

---

## Classification Categories

### History Categories
| Category ID | Description | AP Cost | Once Only? |
|---|---|---|---|
| `overview` | What's going on / chief complaint | 1 | Yes |
| `symptom_drill_pain` | Detailed questions about pain | 1 | Once per symptom |
| `symptom_drill_nausea` | Detailed questions about nausea | 1 | Once per symptom |
| `symptom_drill_fever` | Detailed questions about fever | 1 | Once per symptom |
| `symptom_drill_appetite` | Questions about appetite/eating | 1 | Once per symptom |
| `symptom_drill_bowel` | Bowel habit questions | 1 | Once per symptom |
| `symptom_drill_urinary` | Urinary symptom questions | 1 | Once per symptom |
| `review_of_systems` | Any other symptoms / ROS | 1 | Yes |
| `pmh_surgical` | Past medical/surgical history | 1 | Yes |
| `medications` | Current medications | 1 | Yes |
| `allergies` | Allergies / drug reactions | 1 | Yes |
| `social_travel_exposure` | Social/travel/exposure history | 1 | Yes |
| `family_history` | Family medical history | 1 | Yes |
| `sexual_history` | Sexual history (blocked in family friendly mode) | 1 | Yes |
| `irrelevant` | Not clinically relevant | 0 | — |

### Physical Exam Categories
| Category ID | Description | AP Cost |
|---|---|---|
| `exam_abdomen` | General abdominal examination | 2 |
| `exam_cardiovascular` | Cardiovascular examination | 2 |
| `exam_respiratory` | Respiratory examination | 2 |
| `exam_neurological` | Neurological examination | 2 |
| `exam_skin` | Skin examination | 2 |
| `exam_heent` | Head, eyes, ears, nose, throat | 2 |
| `exam_musculoskeletal` | Musculoskeletal examination | 2 |
| `exam_genitourinary` | Genitourinary examination (clinical only) | 2 |
| `exam_rectal` | Rectal examination (clinical only) | 2 |
| `exam_breast` | Breast examination (clinical only) | 2 |
| `maneuver_mcburneys` | McBurney's point | 2 |
| `maneuver_rovsing` | Rovsing's sign | 2 |
| `maneuver_psoas` | Psoas sign | 2 |
| `maneuver_obturator` | Obturator sign | 2 |
| `maneuver_rebound` | Rebound tenderness | 2 |
| `maneuver_murphy` | Murphy's sign | 2 |
| `maneuver_other` | Other specific maneuver | 2 |

### Ask MEDDY Categories
| Category ID | Description | AP Cost |
|---|---|---|
| `meddy_general_knowledge` | General medical question | 2 |
| `meddy_differential` | Differential diagnosis based on findings so far | 4 |
| `meddy_condition_tests` | What tests diagnose X condition | 2 |
| `meddy_condition_treatment` | What is treatment for X condition | 2 |
| `meddy_finding_significance` | What does finding X mean | 2 |
| `meddy_irrelevant` | Not a medical question | 0 |

---

## Conversation State Object

Passed to answer lookup on every query. Built from GDScript runtime tracking.

```json
{
  "history_domains_asked": ["overview", "symptom_drill_pain"],
  "history_symptoms_drilled": ["pain"],
  "exam_systems_done": ["abdomen"],
  "exam_maneuvers_done": ["rovsing", "mcburneys"],
  "patient_state": "stable",
  "flags": {
    "iv_access": false,
    "supplemental_o2": false,
    "npo": false,
    "imaging_completed": false,
    "surgery_consult_completed": false,
    "diagnosis_correct": false,
    "arterial_line": false,
    "intubated": false
  },
  "turn_count": 7,
  "ap_remaining": 87,
  "family_friendly_mode": false
}
```

---

## Answer Lookup Algorithm

```
function lookup_answer(category, conversation_state):
    
    # Get all answers for this category
    candidates = answer_bank[category]
    
    # Filter to variants whose conditions are met
    eligible = []
    for variant in candidates.variants:
        if check_conditions(variant.conditions, conversation_state):
            eligible.append(variant)
    
    if eligible is empty:
        return candidates.fallback_answer
    
    # Sort by priority (lowest number = highest priority)
    eligible.sort_by(priority)
    
    # Pick highest priority variant
    best = eligible[0]
    
    # Pick random answer from that variant's answer array
    return random_choice(best.answers)
```

---

## Variant Priority Guidelines

| Priority | Use Case |
|---|---|
| 1 | Most specific state (e.g. post-perforation answer) |
| 2 | Contextually aware (e.g. repeat ask after domain established) |
| 3 | First ask (domain not yet asked) |
| 10 | Generic fallback within category |

---

## Answer Authoring Pipeline

### Phase 1 — Auto-Runner Discovery
1. Enable `DEV_MODE_LLM = true`, `DEV_MODE_SKIP_CONFIRM = true`
2. Run AutoRunner.gd — LLM plays as doctor, exhausts conversation states
3. Godot exports conversation log JSON to `reports/` folder
4. Each log contains: input, classification, conversation_state, LLM_response

### Phase 2 — Coverage Analysis
Review `coverage_report.json`:
- Which categories were triggered?
- How many times each?
- Which conversation states were covered?
- Which questions were flagged for manual review?

### Phase 3 — Answer Curation
For each category:
1. Review all LLM responses for that category across all runs
2. Select best 2-4 responses as answer array options
3. Identify which conversation state conditions apply
4. Create variant entries in answer bank JSON
5. Mark `physician_reviewed: true`

### Phase 4 — Question Assignment
For each auto-runner generated question:
1. LLM screens against existing answer bank
2. Returns confidence: does this question fit existing answer?
3. ≥8/10 confident fits → assigned to that answer (`questions_assigned` array)
4. ≥8/10 confident doesn't fit → new answer generated
5. <8/10 either direction → flagged for manual review

### Phase 5 — Manual Review Queue
All flagged items reviewed by physician. Decisions:
- Assign to existing answer
- Create new answer
- Mark as irrelevant category

### Phase 6 — Validation
Run full playthrough in authored mode (`DEV_MODE_LLM = false`).
Verify all common inputs route correctly.
Verify all patient states covered.

---

## Future: Local Classifier Training

Once answer bank has 50+ labeled questions per category:

**Approach:** Fine-tune sentence-transformer model on labeled dataset.

**Training data format:**
```json
{
  "question": "where does it hurt",
  "conversation_state_features": {
    "pain_location_asked": false,
    "turn_count": 1
  },
  "assigned_category": "symptom_drill_pain",
  "assigned_variant": "pain_location_first_ask"
}
```

**Target accuracy:** >95% on held-out test set.

**Hybrid fallback architecture:**
```
Local classifier (fast, free, handles 95%)
    → if confidence < threshold
    → LLM classifier (handles edge cases)
    → if still unclassified
    → irrelevant bucket
```

**Tools:** Hugging Face, sentence-transformers, scikit-learn, BioBERT/ClinicalBERT base models.

---

## Sensitive Exam Handling

Exams involving genitalia, rectum, breasts, or intimate areas:
- `speaker: "clinical"` — no patient dialogue
- Pure objective finding only
- No asterisk actions, no patient reactions
- One sentence maximum
- Example: `"Normal male genitalia on examination — no masses, swelling, or tenderness noted."`

---

## Irrelevant Input Handling

When classification returns `irrelevant` or confidence < threshold:
- 0 AP cost
- Patient redirects warmly
- Occasionally humorous but never mean
- Rotates through deflection responses randomly

**Deflection response bank:**
```json
[
  "Ha, I appreciate that, but honestly I'm really focused on this pain right now, doc.",
  "I'm not sure what you mean — can we maybe focus on what's going on with me?",
  "That's... an interesting question. But this pain is really worrying me.",
  "I think we might be getting a little off track here — is everything okay?",
  "Doc, I trust you, but I'm in a lot of pain. Can we stay focused?"
]
```

---

## YouTock Badge Override

When `burnout_youtock` badge is active:
- 50% chance any medication/vaccine/procedure triggers refusal
- Refusal pulls from `badge_youtock_dialogue.json` medication_refusal_quotes
- Education attempts pull from education_refusal_quotes
- Same classification system still applies for routing
- Refusal check happens AFTER answer lookup, BEFORE display

---

## File Structure

```
game/med-rpg/data/
    responses/
        appendicitis/
            history_responses.json
            exam_responses.json
            meddy_responses.json
            ask_meddy_responses.json
            deflection_responses.json
        coverage_reports/
            run_001.json
            run_002.json
            coverage_summary.json
    badges/
        badge_youtock_dialogue.json
        boost_badges.json
        burnout_badges.json
```

---

## Quality Standards

Every authored response must meet:
- **Medical accuracy** — reviewed by physician
- **Natural language** — sounds like a real person, not a textbook
- **Age appropriate** — safe for all ages unless explicitly gated
- **Consistent character** — Marcus sounds the same throughout
- **Appropriate length** — 1-3 sentences for patient, 1-2 for MEDDY
- **No diagnosis revelation** — patient never names their condition

---

## Session Log
- **Created:** Session 22 — Full authored response system architecture designed
- Replaces live LLM patient dialogue in shipped game
- LLM retained only for input classification in shipped version
- All content physician-reviewed before shipping
