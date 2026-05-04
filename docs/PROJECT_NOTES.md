# MedRPG — Project Notes

*Single source of truth. Re-paste this at the start of new chat sessions to give Claude full context.*
*Two sections below: one optimized for Claude (dense reference), one for John (overview & quick lookups).*

---
---

# 🤖 SECTION FOR CLAUDE — read this first when starting a new chat

This section is dense by design. Skim once, refer back to specifics as needed.

## Project basics

- **Engine:** Godot 4.6.2 stable, GDScript, warnings-as-errors strict typing
- **Render:** Compatibility renderer / 1280×720 / canvas_items stretch / Nearest filter
- **LLM backend:** Claude Sonnet 4.5 via local Node.js on `localhost:3000` (run with `cd server && node server.js`)
- **Repo root:** `C:\Users\jmcar\OneDrive\Documents\Coding Projects\MedRPG`
- **Godot project root:** `MedRPG/game/med-rpg/`
- **Scripts:** `game/med-rpg/scripts/`
- **Scenes:** `game/med-rpg/scenes/`
- **Data:** `game/med-rpg/data/` (subfolders: `conditions/`, `labs/`, `imaging/`, `medications/`, `responses/`, `badges/`)

## Working with John

- **John is a physician, not a coder.** Treat him as the implementer who needs exact instructions. Tell him what to paste where, not architectural debates (unless he's specifically asking for design discussion).
- **He pastes terminal/code output in chat with mangled markdown:** filenames like `clinical_engine.gd` show as `clinical_[engine.gd](http://engine.gd)`. The brackets and URLs are chat-interface auto-link artifacts — ignore them, the real filenames are clean.
- **He hates the word "genuinely" and hollow validation.** Be direct. Acknowledge mistakes plainly. Don't pad with affirmations.
- **He's a paying Pro customer.** Treat his time accordingly — don't drag out simple tasks.
- **Strict technical accuracy required.** No guessing UI elements, button names, or library APIs. Search documentation first.
- **He has memory entry about Wheel Stand Pro fix** — irrelevant to MedRPG, ignore.

## Working style preferences (learned the hard way)

- **When changes don't produce expected results, STOP and add debug prints** rather than continuing to guess. We've burned hours iterating on layout values based on incorrect mental models. If a change has zero effect or moves something the wrong direction, that's the signal to verify behavior empirically before proposing more changes.
- **Pixel-tweaking UI is a bottomless pit.** Don't get sucked in. After 2-3 rounds of "another N pixels left/right" with diminishing returns, suggest stopping and accepting "good enough."
- **Prefer "good enough" + commit + move on** over "perfect but never shipped." Commits are checkpoints; ship the feature even if there's a 2px misalignment.
- **Don't ask "what's next" between every micro-step.** Batch related changes. Ask for direction at meaningful decision points only.
- **When he says "you decide" or "I trust you,"** he means it — make the call, don't bounce back with options.

## Godot/GDScript quirks already discovered (don't re-learn these)

- **Anchors don't work for Controls parented under CanvasLayer.** Solution implemented in `popup_layout.gd`: set `position` and `size` directly via `get_viewport_rect().size`, with `set_anchors_preset(Control.PRESET_TOP_LEFT)`.
- **PanelContainer auto-grows to content's minimum size.** Setting smaller dimensions silently gets clamped. Affects all our popup sizing — picking too-small numbers in `popup_layout.gd` produces unchanged output.
- **HBox layout with expand-fill children:** spacers added BEFORE the expand child move later siblings leftward (consume from expand allocation). Spacers AFTER the expand child sometimes have no visible effect because right-edge clamping hits first. We have NOT fully understood this — the imaging results column header alignment was partially solved empirically.
- **External CDN libraries blocked in artifact rendering environment** — including Three.js. Use self-contained Canvas 2D solutions for any browser-rendered demos.
- **GDScript strict typing:** `:= max(...)` and `:= dict.get()` produce ambiguous return types and trigger warnings-as-errors. Use explicit annotations: `var x: float = max(a, b)`, `var s: String = dict.get("key", "")`.
- **`spend_ap()` in clinical_engine.gd already calls `increment_turn()` and `update_hud()` internally.** Handlers calling `spend_ap()` must NOT call those again or turns double-bump.

## File organization conventions

- New popup → script in `scripts/`, scene in `scenes/`, scene parented under `PopupLayer` (CanvasLayer node) inside `clinical_encounter.tscn`. Set `visible = false` by default.
- Scene root nodes named PascalCase: `IVPopup`, `LabsPopup`, `ImagingPopup`.
- Engine references popups by `$PopupLayer/PopupName`, not `$PopupName` (post-refactor).
- Scripts use snake_case filenames, snake_case function names, snake_case variables.
- Constants in SCREAMING_SNAKE_CASE.
- Color constants prefixed `C_` (e.g. `C_PANEL`, `C_DIM`, `C_CONFIRM`).
- Helper functions prefixed with underscore: `_make_label`, `_style_panel`, `_set_btn_left_padding`.

## Critical reference docs

These exist alongside PROJECT_NOTES and are mandatory reading for the topics they cover. Do not start work on these systems without reading them first.

- **`AUTHORED_RESPONSE_SYSTEM.md`** — architecture for authored patient dialogue (deferred)
- **`MEDICATIONS_INTEGRATION.md`** — engine integration steps for the medications popup (Session 30 active work)
- **`SCORING_DESIGN.md`** — *(NEW Session 30)* full scoring/economy/badge/difficulty design spec. **THIS IS A MAJOR REFACTOR ITEM.** When implementing, follow the file order in that doc's "Implementation Order" section. The current `bonus_points` system in JSON files will be split into `score_value` (per-action, per-case, run measurement) and `bonus_points` (persistent meta-currency between runs). Schema docs in PROJECT_NOTES will need updating after refactor.
- **`AUTORUNNER_DESIGN.md`** — *(NEW Session 30)* full autorunner architecture spec. Covers the persona system (16 anchor personas: 6 clinical, 6 adversarial, 4 pediatric), termination conditions (fixed question cap per persona × state, no AP limits, manual state setup), inline clustering, full-case-context for doctor LLM, output formats, off-topic handling. **THIS IS THE EXISTENTIAL EXPERIMENT.** If autorunner-built authored content covers the input space, MedRPG ships to Steam. If not, fallback is LLM-NPC version on itch.io. Read this doc before doing any autorunner work.

## What's built and how it's wired

### Engine (`clinical_engine.gd`)
The brain. Holds patient state, AP, turns, time, IV state, measurement rolls. Wires up popups in `_ready()`. Loads condition data from JSON files in `_ready()` via `load_condition_data()`.

Key state vars: `current_state` (PatientState enum), `ap_current`, `bonus_points`, `harm_points`, `turn_count`, `elapsed_seconds`, `iv_sites`, `iv_access`, `current_measurements`.

Key functions: `spend_ap(amount)` (returns bool, handles increment+HUD), `increment_turn()`, `update_monitor()`, `transition_to_state()`, `roll_radiology_measurements()`, `format_measurement(id, modality)`, `substitute_measurements(text, modality)`, `_has_any_working_iv()`, `_has_working_ac_iv()`, `_update_iv_status_display()`.

### Popups (all share patterns)
- **Labs popup** (`labs_system.gd` + `labs_popup.tscn`) — three tabs (Search by Name, Browse Categories, Ask MEDDY!), section headers (Panels/Labs), result rows with selection, AP cost summary, two-step confirm. Result variation via `randf_range` between min/max in `appendicitis_labs.json`. Cache invalidated on state transition.
- **Imaging popup** (`imaging_system.gd` + `imaging_popup.tscn`) — three tabs, hierarchical category tree (X-Ray with subcategories, CT With/Without Contrast, etc.), IV contrast modal, stability blocks (most MRI blocked when septic_shock/coma_fail), pediatric filter, modality color badges, pending state with dual delays (real-time AND turn). Result text from `appendicitis_imaging.json`, with `{{measurement_id}}` placeholders substituted via engine call. Cache NOT invalidated on state transition (known gap).
- **IV popup** (`iv_system.gd` + `iv_popup.tscn`) — single panel, 6 site rows in clinical priority (L AC, R AC, L Hand, R Hand, L Foot, R Foot), confirmation modal for both place (1 AP) and remove (free). Mini-game stub `_attempt_iv_placement(site, harm_modifiers)` always returns success. Modal: Confirm left, Cancel right, centered.

### Shared layout (`popup_layout.gd`)
Static class with edge-offset constants per popup (IMAGING, LABS, MEDICATIONS, IV, DEFAULT). `apply_layout(panel, popup_kind)` sets position+size directly (not anchors). To resize a popup, edit constants here only.

### Status displays (in `clinical_encounter.tscn`)
- Vitals stack: HR, BP, RR, Temp, SpO2 inside `Monitor/VitalsContainer` (rigid narrow rows)
- IV access status: `Monitor/IVAccessLabel` (RichTextLabel, sibling of VitalsContainer, BBCode enabled). Shows `No IV access` / `IVs: N (sites)`. Red BBCode for extravasated sites.

### Variation systems
- **Labs:** uniform random sample between min/max per `(lab_id, patient_state)`. Cached. Function: `_generate_single_result()` in `labs_system.gd` line ~ middle. Uses `randf_range(min, max)` then rounds to `display_decimals`. The `normal_distribution` / `mean` / `std_dev` fields in JSON are NOT used — the actual code uses only `min` / `max`. The labs JSON schema is "ahead of" the implementation.
- **Radiology measurements:** new system. Schema in `appendicitis.json` under `radiology_measurements`. `roll_radiology_measurements()` fires at end of `load_condition_data()`, samples each measurement once. `state_offsets` block adds delta for derived states (e.g. perforated = stable + 2mm). `format_measurement()` applies offset and per-modality precision. `substitute_measurements()` replaces `{{id}}` placeholders in any text. Wired into `_generate_result_text()` in `imaging_system.gd` before caching.

### Medications system (Session 29 — schema designed, popup not yet built)

**Critical to read before working on medications. The architecture decisions here are locked in.**

**File loading model:**
- Engine loads ONE file at startup: `data/medications/master_medications.json`
- The 23 source category files (`medications_antibiotics.json`, `medications_analgesics.json`, etc.) live in `data/medications/source/` and are NEVER loaded by the engine. They're authoring source — copy entries from them into `master_medications.json` to expand the v1 set.
- This mirrors the labs/imaging pattern: `master_labs.json` + `master_imaging.json` are the engine's load targets.

**v1 catalog scope:** 40 drugs covering 9 of 23 categories — antibiotics (10), analgesics (6), gi (4 incl. antiemetics + pantoprazole), fluids_electrolytes (4), vasopressors_inotropes (4), anesthetics (4), paralytics (2), reversal_antidotes (3), endocrine (3 incl. hydrocortisone for septic shock).

**v1 deferred categories** (not in master_medications.json yet, source files exist): rheumatological, allergy, antifungals, antiparasitics, antivirals, anticoagulants, cardiovascular, dermatologic, gynecologic, neuro_psych, respiratory, transfusions, vaccines_immunoglobulins, other.

**Per-medication schema (master_medications.json):**
- `id` — unique entry primary key
- `canonical_id` — drug's true identity. Multiple entries (same drug across multiple categories, e.g. ondansetron in GI vs Other) share canonical_id so engine treats them as one drug for allergy/already-given/max-dose tracking. For non-duplicates canonical_id == id.
- `category_id` — drives Browse Categories tab placement, mirrors source file
- `routes` — available routes for this drug (PO, IV, IM, SQ, intranasal, topical, inhaled, PR, sublingual, ODT, transdermal, ophthalmic, otic, etc.)
- `ap_cost` — per-drug global, same regardless of route. Scale: routine meds 1 AP, vasopressors/inotropes 2 AP, blood products 2 AP (none in v1), thrombolytics 4-5 AP (none in v1)
- `allergy_class` — categorical (penicillins, cephalosporins, carbapenems, sulfonamides, nsaids, opioids, etc.) or null. Matched against `patient_allergies` array in condition file
- `peripheral_extravasation_risk` — `low` | `moderate` | `high`. Currently informational only. Wires into IV Stage F extravasation roll when that ships. DO NOT REMOVE.
- `semantic_tags` — free-text bag for Ask MEDDY filter

**Patient allergy enforcement:**
- Condition files include `patient_allergies` array at top level (e.g. `appendicitis.json` has `"patient_allergies": ["nsaids"]`)
- Marcus's allergy is also reflected in `appendicitis_system_prompts.json` in two places: `clinical_ground_truth.allergies` and the history prompt itself, so he discloses it naturally when asked
- When player tries to order a med with `allergy_class` matching any value in `patient_allergies`, MEDDY warning popup fires: 1 harm point for the attempt, player can cancel (still keeps the harm point) or proceed (gets another harm point and triggers anaphylaxis)
- For Marcus's NSAID allergy in v1 catalog, the trigger drugs are: `ibuprofen`, `ketorolac` (both `allergy_class: "nsaids"`)

**Anaphylaxis state — DEFERRED (planned, architecture must support):**
- Not implemented in v1. Engine should set a flag `anaphylaxis_triggered: true` and log it but not yet enact state changes
- When implemented: anaphylaxis is its own patient state with respiratory distress → shock → arrest progression, reversible with timely IM epinephrine, IV fluids, steroids, antihistamines

**Vascular access architecture (v1 = peripheral IV only, future-proof for IO + central line):**
- Engine concept: `vascular_access_points` — a unified list the medication popup queries. Currently contains only working peripheral IVs from `iv_sites`. Future IO and central line entries append to the same list
- Medication confirmation popup builds route buttons from `medication.routes` intersected with what's currently feasible. Non-IV routes (PO, inhaled, PR, IM, SQ, topical, sublingual, intranasal) always show. IV routes only show if `vascular_access_points` is non-empty
- Each individual access point = its own button. So today player sees "L AC IV / R Hand IV" as separate route buttons; later they might see "L AC IV / Central line — RIJ / IO — L tibia"
- All vascular access types are interchangeable for the medication popup. NO `requires_central_line: true` flag in v1 — anything can go through peripheral. Some drugs (norepinephrine, vasopressin, epinephrine, phenylephrine, vancomycin, D50, promethazine) have `peripheral_extravasation_risk: high` or `moderate` — when IV Stage F ships, that risk drives an extravasation probability roll

**Medication popup UX (planned, not built yet):**
- Same shape as labs/imaging — three tabs (Search by Name, Browse Categories, Ask MEDDY)
- **Single medication at a time** (NOT a multi-cart like labs/imaging). Each med needs route selection so cart-with-per-item-route would be awkward
- Flow: pick drug from list → confirmation popup with route radio buttons (one per available route) + Order button → AP cost confirmation popup with Confirm/Cancel (same shape as IV placement)
- Allergy check fires AFTER drug pick, BEFORE route selection
- IV-without-access flow: if player picks IV-only drug and `vascular_access_points` is empty, MEDDY warning popup fires telling them to close, exit meds, click IV button, place IV, retry. NOT the auto-place-IV behavior from `appendicitis_other_treatments.json` (that was for the old non-popup ordering path)

**Ask MEDDY tab mechanism:**
- Player asks question → LLM call returns list of `semantic_tags` to filter on
- Engine filters `medications` by tag overlap, popup displays filtered list
- Player still picks. MEDDY narrows, doesn't decide

## What's deferred (explicitly NOT built yet)

### IV system stages D-F
- **Stage D:** Harm-badge modifier integration. Currently passes empty `[]` array to mini-game stub.
- **Stage E:** CT PE protocol AC requirement. Only that one specific study uses power injection and needs AC IV. Other contrast studies just need any working IV. Helper `_has_working_ac_iv()` already exists.
- **Stage F:** Extravasation state machine (currently `extravasated` field exists in IV record but never set true), MEDDY auto-suggest removal popup when extravasation detected, exam findings showing local swelling/erythema/tenderness around extravasated site.

### IV mini-game itself
Currently `_attempt_iv_placement(site, harm_modifiers)` in `iv_system.gd` always returns `{"success": true, "extravasation": false, "notes": ""}`. Real mini-game replaces only the body of this function — signature is the contract.

### Patient diagram
Future chalk-outline pixel art body sprite that all systems annotate (IV sites, edema, rashes, drains, lines). Deferred until pixel art exists. For now, text status label below SpO2 is the source of truth for IV state.

### Imaging cache invalidation on state transition
Labs has it (`labs_popup.invalidate_result_cache()` called in `transition_to_state()`). Imaging does not. Means a CT ordered before perforation will keep showing pre-perforation findings if state changes. One-line fix when ready: add `imaging_popup.invalidate_result_cache()` to `transition_to_state()`.

### Other major systems not started
- Authored response system (architecture documented in `AUTHORED_RESPONSE_SYSTEM.md` but not yet implemented in code)
- Auto-runner (`auto_runner.gd` mentioned in plans, not built)
- Ask MEDDY button (separate from imaging/labs MEDDY tabs)
- PPE button + system
- Diagnosis evaluation system
- MEDDY emotional animations (idle works, others don't exist)
- Badge system implementation
- Win/fail end-game states
- Balatro run mode + encounter selection
- Character creator screen

### Medications system status (Sessions 29–30)
- **Schema designed and documented** (see "Medications system" subsection above). Catalog file `master_medications.json` created with 40 drugs across 9 categories. `patient_allergies` field added to `appendicitis.json`. Marcus's NSAID allergy reflected in `appendicitis_system_prompts.json`.
- **Popup BUILT (Session 30):** `medications_system.gd` created (~1000 lines). Three-tab UI (Search by Name / Browse Categories / Ask MEDDY). Order flow: medication click → feasibility check → optional allergy modal → route picker → AP confirmation. Single-medication-at-a-time. Returns to popup after order. Integration patches in `MEDICATIONS_INTEGRATION.md`. Scene file `medications_popup.tscn` must be created in Godot editor (instructions in integration doc).
- **`meddy_medication_filter` prompt added** to `appendicitis_system_prompts.json` for the Ask MEDDY tab. Popup makes its own HTTP call to `localhost:3000/llm` (mirrors labs Ask MEDDY pattern). Returns JSON `{canonical_ids: [...]}` which the popup uses to filter the displayed list.
- **Anaphylaxis state DEFERRED** — popup emits `anaphylaxis_triggered_signal`, engine sets `anaphylaxis_triggered: bool` flag and adds harm point. State machine for respiratory distress/shock/arrest progression is future work.
- **IO and central line procedures DEFERRED** — engine helper `_get_vascular_access_points()` reads from `iv_sites` only. Future IO/central line entries append to the returned array; popup needs no changes.
- **Clinical effects of giving meds DEFERRED** — antibiotics don't yet stop sepsis, opioids don't reduce pain reports, ondansetron doesn't stop nausea symptoms. The popup orders, the engine logs to `medications_given`, but no effect is enacted on patient state. That's the next major treatment-effects system.

## Known broken things

- **Imaging cache stale across state transitions** — described above, easy fix not yet applied
- **Imaging "Time" column header alignment** — sits ~1px right of data text. Multiple attempts to fix failed. Mechanism not understood. Accepted as good-enough.
- **Lab variation schema unused fields** — `mean`, `std_dev`, `type: "normal_distribution"`, `flag_above` fields in lab JSON are not read by the variation function. Only `min` and `max` are used. The schema is aspirational.
- **`.gitignore` had a parse bug** — `Photos saved/` was concatenated to previous line. Fixed mid-session by splitting onto own line. Verify hasn't regressed.
- **Engine doesn't handle `is_other` from exam cost detection** — Session 28 added an `is_other: true` fallback to the `exam_cost_detection` prompt for inputs that don't match any known system or maneuver. The engine's `handle_exam_cost_response` was not updated to read this field, so unclassifiable exam input ("examine one eyelash") still falls through to the live patient-response LLM call instead of showing a "I'm not sure what you're trying to examine" redirect. Acceptable while in `DEV_MODE_LLM = true` since the LLM will produce a plausible response either way.

## Dev toggles in clinical_engine.gd

```gdscript
const DEV_MODE_LLM: bool = true          # true = live LLM, false = authored responses (not built yet)
const DEV_MODE_SKIP_CONFIRM: bool = false # true = skip AP confirmation popups (auto-runner mode)
```

Before shipping: delete all `DEV_MODE_LLM` code paths and the auto-runner script entirely.

## Schema versioning rule

All JSON files include `schema_version` as first field. Current: `"1.0"`. Bump to `"1.1"` for non-breaking additions, `"2.0"` for breaking changes.

---
---

# 👤 SECTION FOR JOHN — your project at a glance

This section is the human-readable overview. Skim when you want to remember where you are, what's been built, or look up a quick reference.

## What MedRPG is

A retro pixel-art RPG where you play a doctor. You travel a world map healing patients via turn-based clinical encounters. Each encounter, you spend Action Points (AP) on history-taking, exams, labs, imaging, treatments, and surgery. Burn through AP without curing the patient → they deteriorate. The game has both replayability (Balatro-style runs with random cases and badges) and learning value (works as a teaching tool for any non-medical person).

## Where you are right now

**Working in-game:**
- Full encounter scene with vitals monitor, AP/turn/time tracking
- All 13 action button categories wired
- History and exam systems with LLM-powered question handling
- Confirmation popups for all actions
- Labs system (full popup, three tabs, search, ordering, results, variation)
- Imaging system (full popup, three tabs, contrast handling, stability blocks, results, modality color coding)
- IV system (popup with 6 sites, place/remove with confirmation, status display below SpO2)
- Radiology measurement variation (appendix diameter rolls per session, displays in CT/ultrasound/MRI reports with appropriate precision per modality, +2mm if perforated)

**Working but rough:**
- Live LLM responses for patient dialogue (placeholder — will be replaced by authored responses in shipped game)
- Exam cost-detection prompt was upgraded in Session 28 to use a canonical ID enum matching the JSON keys (`exam_abdominal`, `bonus_mcburney`, etc.) and to return `is_other: true` for unrecognized input. Engine doesn't yet read `is_other` (see Known broken things)

**Not yet started:**
- Authored response system implementation
- Auto-runner for content discovery
- Medication ordering popup
- Ask MEDDY button
- PPE button
- Badge system
- Win/fail end-game logic
- Balatro run mode
- Character creator
- World map / overworld
- Patient diagram for visualizing IV sites and other status

## Conventions to remember

- Each new popup goes under `PopupLayer` (CanvasLayer) in the encounter scene, hidden by default
- Sizing is controlled centrally in `popup_layout.gd` — to resize any popup, edit the constants there
- Modals (like IV place/remove confirmation) live INSIDE their parent popup, not as separate scenes
- Confirm button always on the LEFT, Cancel on the RIGHT, centered
- All variation values rolled once per encounter, cached, and consistent across modalities

## Quick reference

### Git commit routine

```
git status
git add .
git commit -m "your message here"
git push
```

If `git status` shows screenshots in `Photos saved/` getting picked up, your `.gitignore` is broken again. The line should read `Photos saved/` on its own line (not concatenated to another).

### Dev toggles (top of `clinical_engine.gd`)

- `DEV_MODE_LLM = true` → live LLM responses (current dev mode)
- `DEV_MODE_LLM = false` → authored responses (future shipped mode, not implemented yet)
- `DEV_MODE_SKIP_CONFIRM = true` → skip AP popups (auto-runner mode)

### File locations

- Engine code: `game/med-rpg/scripts/clinical_engine.gd`
- Popup scripts: `game/med-rpg/scripts/{labs,imaging,iv}_system.gd`
- Popup scenes: `game/med-rpg/scenes/{labs,imaging,iv}_popup.tscn`
- Shared sizing: `game/med-rpg/scripts/popup_layout.gd`
- Main scene: `game/med-rpg/scenes/clinical_encounter.tscn`
- Condition data: `game/med-rpg/data/conditions/appendicitis.json` and related
- Medication catalog (engine loads this): `game/med-rpg/data/medications/master_medications.json`
- Medication source files (NOT loaded — authoring reference): `game/med-rpg/data/medications/source/medications_*.json` (23 files)
- Backend server: `server/server.js` (run with `cd server && node server.js`)

### To resize any popup

Edit `game/med-rpg/scripts/popup_layout.gd`. Each popup has its own constant block (IMAGING, LABS, IV, MEDICATIONS) with four numbers (left/top/right/bottom edge offsets in pixels from screen edges). Save and reload.

### To add a new measurement to randomize

1. Add a block to `radiology_measurements` in `appendicitis.json` (or future condition file)
2. Add `{{your_measurement_id}}` placeholders in the imaging report text wherever it should appear
3. Variation rolls automatically at encounter start — no engine code changes needed

## Big design decisions you've locked in

- **Authored responses + LLM classification, not live LLM dialogue.** The shipped game uses pre-written, physician-reviewed responses. LLM only routes input to the right response. This is the entire content authoring pipeline (see `AUTHORED_RESPONSE_SYSTEM.md`).
- **Balatro run mode first, world overworld later.** Faster to ship, more replayable, validates the core loop before building world content.
- **Radiology measurements consistent across modalities.** Appendix diameter rolled once per encounter, displays the same value (with modality-appropriate precision) on CT, ultrasound, and MRI. Perforated state adds +2mm to derived states.
- **IV system architecture allows future patient-diagram integration.** Per-site state model with rich record schema means we can later replace text status display with annotated body sprite without changing the engine.
- **Single-file artifacts for popups.** All UI logic for a popup lives in one `.gd` file, no separate CSS/JS-style splits.
- **Schema versioning on all JSON.** Future migrations easier.

## Things to come back to

These aren't urgent but you flagged them as "we'll do this later":

- IV mini-game (real implementation, replacing the always-success stub)
- IV harm-badge modifiers (dehydration, obesity, etc. affecting placement success)
- CT PE protocol AC requirement (currently any IV works for any contrast study)
- Extravasation state machine + MEDDY auto-suggest popup
- Patient diagram (chalk-outline body sprite for visualizing patient status)
- Imaging cache invalidation on state transitions (one-line fix)
- Convert lab variation system to use the `mean`/`std_dev`/`normal_distribution` fields the schema implies (currently uniform sampling)

## Session log (high level)

- **Sessions 1–22:** Architecture, JSON data layer, scene skeleton, ClinicalEngine, vitals monitor, all 13 buttons, confirmation popups, LLM API integration, exam validation, history domain AP system, MEDDY idle animation, dev toggles
- **Session 23:** Turn counter + time counter, labs system designed, project notes baseline established
- **Session 24:** Imaging system built end-to-end (master imaging data, condition imaging data, popup with three tabs, hierarchical category tree, contrast handling)
- **Session 25:** Shared `popup_layout.gd` extracted, popups reparented under PopupLayer, dark overlay removed, extensive column header alignment work
- **Session 26:** IV access system built (Stages A, B, C). Per-site state, popup, confirmation modal, status display below SpO2. Mini-game stub ready to swap
- **Session 27:** Radiology measurement variation system. Appendix diameter rolls per session, displays in imaging reports with per-modality precision and state-based offset. PROJECT_NOTES rewritten to bootstrap-doc format
- **Session 28:** Physical exam authored-response groundwork (later deferred). `appendicitis.json` exam data updated: 1 AP per system / 1 AP per maneuver, named maneuvers (McBurney, Rovsing, psoas, obturator) removed from `exam_abdominal` clinical text so they must be ordered separately, `bonus_obturator` and `bonus_heel_tap` added (5 special-maneuver bonuses total, each worth 1 bonus point, no ordering gate). `exam_cost_detection` prompt rewritten with canonical IDs as a constrained enum and an `is_other: true` fallback for unclassifiable input. **Server recreation:** `server/server.js` was lost from OneDrive (no version history, no recycle bin); rebuilt from scratch using `@anthropic-ai/sdk` with model `claude-sonnet-4-5-20250929`. Has `/llm` POST endpoint and `/health` GET endpoint. Authored-response lookup for exams was scoped but not built — pivoted to focus on auto-runner first since results may inform a different architecture entirely
- **Session 29:** Medications system schema designed and documented end-to-end. 23 source category files (~600 medications total) reviewed and confirmed as authoring-only — engine loads ONE file: `master_medications.json`. v1 catalog created with 40 drugs across 9 categories (antibiotics 10, analgesics 6, gi 4 incl. antiemetics + pantoprazole, fluids 4, vasopressors 4, anesthetics 4, paralytics 2, reversal 3, endocrine 3). Schema fields: `id`, `canonical_id` (for cross-category dedup), `category_id`, `routes`, `ap_cost` (per-drug global, 1 AP routine / 2 AP vasopressors / 4-5 AP thrombolytics), `allergy_class`, `peripheral_extravasation_risk` (low/moderate/high — informational until IV Stage F ships), `semantic_tags`. **Marcus given an NSAID allergy** — `patient_allergies: ["nsaids"]` added to `appendicitis.json`, allergy reflected in `clinical_ground_truth.allergies` and history prompt of `appendicitis_system_prompts.json`. Marcus discloses ibuprofen rash + breathing difficulty when asked. v1 trigger drugs for this allergy: `ibuprofen`, `ketorolac`. Anaphylaxis state and IO/central-line procedures explicitly deferred but architecture (`vascular_access_points`, `anaphylaxis_triggered` flag) left forward-compatible. Medication popup itself NOT yet built — will follow labs/imaging three-tab pattern but single-medication-at-a-time (no multi-cart) because each med needs route selection.
- **Session 30:** Medications popup built. `medications_system.gd` (~1000 lines), three tabs (Search/Browse/Ask MEDDY), order flow (feasibility check → allergy modal → route picker → AP confirm). Search matches token-prefix on generic OR brand names ("tor" finds Toradol). Browse uses flat category list (left) + medication list (right). Ask MEDDY makes its own HTTP call (mirrors labs MEDDY pattern), prompt added to `appendicitis_system_prompts.json` as `meddy_medication_filter`, returns `{canonical_ids: [...]}`. Allergy modal fires before route picker — first harm point on display, second on Proceed Anyway with `anaphylaxis_triggered_signal` emitted. Route picker shows non-IV routes always + one button per vascular access point for IV (encoded as `IV|left_ac` token). After order resolves, returns to popup main view (per spec). Engine integration documented in separate `MEDICATIONS_INTEGRATION.md` (5 explicit edits + scene file creation steps for the Godot editor). Scene file `medications_popup.tscn` must be created manually in editor. Clinical effects (antibiotics stopping sepsis, etc.) DEFERRED — popup orders, engine logs to `medications_given` array, but no patient state effects yet. **Also Session 30:** extensive design discussion on game philosophy → produced `SCORING_DESIGN.md` capturing the full economy redesign (Score / Bonus / XP / AP four-currency system, diagnosis-as-AP-cost mechanic, time-into-AP-debit pressure, difficulty card draws, badge categories incl. Hot Mess, shop UI sketch). Implementation deferred to Session 31. The existing `bonus_points` system in all JSON files will be refactored — most current bonus_points become score_values (per-action run measurement), real bonus_points become persistent meta-currency for between-run shop. Route button highlighting fixed during testing — selected = blue across all states, unselected = subtle dark hover (no blue). Click-toggles-deselect added. **Also Session 30:** strategic decision on autorunner vs. LLM-NPC architecture. John's framing: try autorunner; if it fails, ship LLM-NPC version on itch.io instead of Steam. Produced `AUTORUNNER_DESIGN.md` capturing full autorunner spec — 16 anchor personas (6 clinical pro, 6 adversarial/edge-case incl. trying to break game / gross / violent / roleplay disruptor / off-topic / bad-faith medical, 4 pediatric ages 6/8/10/12), no AP limits during autorun, manual state setup (not natural progression), fixed question cap per persona × state, doctor LLM gets full case context (findings + history + state), inline clustering with ≥0.8 confidence threshold, adversarial personas generate off-topic deliberately to populate redirect bank. Per-session JSON + aggregated coverage report with saturation curve as convergence signal. Estimated dataset size: ~600 KB patient text per condition, ~30 MB total for 50 conditions — text is so compact this is not the bottleneck; authoring labor is. The autorunner is THE existential experiment for the project.
