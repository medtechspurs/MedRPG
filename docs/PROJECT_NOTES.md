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
- Medication ordering popup (planned, will follow imaging/labs pattern)

## Known broken things

- **Imaging cache stale across state transitions** — described above, easy fix not yet applied
- **Imaging "Time" column header alignment** — sits ~1px right of data text. Multiple attempts to fix failed. Mechanism not understood. Accepted as good-enough.
- **Lab variation schema unused fields** — `mean`, `std_dev`, `type: "normal_distribution"`, `flag_above` fields in lab JSON are not read by the variation function. Only `min` and `max` are used. The schema is aspirational.
- **`.gitignore` had a parse bug** — `Photos saved/` was concatenated to previous line. Fixed mid-session by splitting onto own line. Verify hasn't regressed.

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
