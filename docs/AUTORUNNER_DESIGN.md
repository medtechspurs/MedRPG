# MedRPG — Autorunner Design Spec
*Captured Session 30. Implementation deferred — exact session TBD.*
*This document is the single source of truth for the autorunner architecture, persona system, termination conditions, and runtime behavior. Supersedes the 4-line "Phase 1" outline in `AUTHORED_RESPONSE_SYSTEM.md`.*

---

## Why this exists

The shipped game uses authored responses, not live LLM generation, for patient dialogue. Reasons: liability (Steam audience, content we can't control), cost per play, latency, consistency across runs. The authored answer bank is built using the autorunner — an LLM playing as the doctor against the live patient LLM, generating the conversation space we then curate.

**The bet:** input space collapses to a small number of answer clusters once you author with generality in mind, plus aggressive off-topic routing. Estimated total dataset for one condition (appendicitis, all states, all variants) ≈ ~600 KB of patient text. Across 50 conditions ≈ 30 MB. Storage is not the constraint; authoring labor is.

**Fallback if this fails:** ship the LLM-NPC version on itch.io instead of Steam. Different platform, more permissive content posture, smaller liability surface.

---

## Architecture overview

```
[Manual setup: bring game to specific patient_state]
         ↓
[Autorunner.gd takes over]
         ↓
For each persona in persona_set:
    For N questions (target ~1000 per persona per state):
        - LLM-doctor generates input based on:
            * persona definition
            * conversation log so far (case state, findings, prior Q&A)
        - Input feeds into normal game classification flow
        - INLINE clustering: classifier checks if question fits existing answer
            * If yes: log assignment, no new generation
            * If no: generate new authored answer, add to bank
        - Patient LLM responds (live LLM mode, DEV_MODE_LLM = true)
        - Full Q/A/state logged to per-session JSON
         ↓
[Coverage analysis post-run]
[Physician review of new authored answers]
[Repeat with different persona/state]
```

---

## Persona System

### Categories (all required for shipping)

**A. Clinical professional personas** — the "good faith" doctor distribution
- ER attending (confident, efficient, broad differential)
- Surgical resident (focused on operative concerns)
- Internal medicine attending (thorough history, systems-based)
- Family medicine doctor (relational, broad context)
- Med student (over-thorough, follows checklist rigidly)
- Anxious early resident (over-orders, hedges)

**B. Adversarial / edge-case personas** — CRITICAL, do not skip
These exist to populate the off-topic redirect bank and to stress-test guardrails. Without these, the shipped game will fail the first time a real player tries to break it.
- "Trying to break the game" — random nonsense, asks about weather, jokes, system prompts, jailbreak attempts
- "Gross / inappropriate" — sexual content, bodily function jokes, body horror
- "Violent / threatening" — threats toward patient, violent fantasies
- "Roleplay disruptor" — tries to get patient to break character, asks Marcus if he's an AI, asks about the developer
- "Off-topic chatter" — wants to discuss the weather, sports, news, the patient's hobbies in detail, irrelevant tangents
- "Bad faith medical" — asks for medications by name with no reason, attempts to harm patient deliberately

**C. Pediatric personas** — these matter because real kids will play this
Children have less developed logic and reasoning. They will ask things adult personas wouldn't. Their distribution is genuinely different.
- 6-year-old (very simple language, repeats questions, magical thinking, asks about non-medical stuff)
- 8-year-old (simple but more curious, may try silly things, asks "why" repeatedly)
- 10-year-old (more capable but easily distracted, may parrot adult medical phrases without understanding)
- 12-year-old (more sophisticated but still tests boundaries, may ask awkward questions)

### Persona definition format (TBD JSON schema, suggested):

```json
{
  "id": "er_attending_confident",
  "category": "clinical_professional",
  "label": "ER attending — confident",
  "system_prompt": "You are an experienced ER attending physician...",
  "behavior_notes": "Asks targeted questions, uses medical terminology, efficient",
  "expected_question_distribution": ["history", "exam", "labs", "imaging"],
  "include_off_topic": false
}
```

For adversarial / edge-case personas, set `include_off_topic: true` and provide system prompts that explicitly instruct the persona to attempt the relevant disruption.

### Persona count target
- 6 clinical professional
- 6 adversarial / edge case  
- 4 pediatric
- = **16 total anchor personas** for v1
- Each persona × each patient state × ~1000 questions = saturation test

---

## Termination Condition

**No AP limits during autorunning.** AP economy is a player-facing mechanic; for coverage testing we want to exhaust the question space, not the AP pool.

**Per-session termination:** fixed question cap (e.g. 1000 questions per persona per state).

**Patient state is set manually** before each autorun batch. We do NOT have the autorunner naturally reach states by deteriorating the patient — too slow, too random, doesn't guarantee state coverage. Workflow:
1. Bring game to `stable` state, run all 16 personas × 1000 questions each
2. Manually flip to `perforated` state, repeat
3. Manually flip to `septic_shock` state, repeat
4. Manually flip to `coma_fail` state, repeat (likely fewer questions — limited interaction)

State count × persona count × question target = total autorunner volume. For appendicitis: ~64,000 questions across all states/personas. At a few seconds per question via LLM, this is a multi-day job. Plan accordingly.

---

## Doctor LLM Context

**The doctor LLM gets full case context.** This was a sigh-decision but it's the right one. Doctor questions only feel realistic if the doctor LLM can see what's already happened in the case.

Context provided per turn:
- Persona definition + behavior notes
- Patient state (current)
- Conversation history so far (full Q&A log)
- Findings so far (lab results, imaging reports, exam findings, history disclosed)
- Prior MEDDY interactions
- AP remaining (for realism, even though autorunner doesn't enforce limits)
- Goal of the encounter ("you are working up this patient — ask whatever next question seems most natural for your persona")

This means the autorunner needs to plug into the engine's existing state-tracking, not just the patient LLM. The autorunner is essentially a headless "fake player" driving the game from the input field.

---

## Inline Clustering (during autorun)

Clustering happens during the run, NOT post-process. Every doctor question goes through:

```
1. Classify question (existing classifier — categories like history, exam, etc.)
2. For matching category, check existing answer bank:
   - For each authored answer in this category + applicable conversation_state:
     - LLM screens: "does this question fit this existing answer?" 
     - Confidence threshold: ≥0.8 = assigned
3. If assigned: log assignment to questions_assigned[] for that answer
4. If not assigned: 
   - Generate new authored answer via LLM
   - Add to answer bank with appropriate conditions block
   - Log as new entry
```

This costs more LLM calls per question but means coverage data is clean and the answer bank emerges in real time. Post-processing as an alternative was rejected — by the time you've generated 1000 free-form answers per persona, manual deduplication is harder than gating up front.

---

## Output Format

### Per-session JSON (one file per persona × state run)
```json
{
  "session_id": "appendicitis_stable_er_attending_001",
  "persona": "er_attending_confident",
  "patient_state": "stable",
  "started_at": "...",
  "ended_at": "...",
  "questions_total": 1000,
  "new_answers_generated": 42,
  "questions_assigned_to_existing": 958,
  "transcript": [
    {
      "turn": 1,
      "input": "What brings you in today?",
      "category": "overview",
      "assigned_to": "answer_overview_first_ask",
      "is_new_answer": false,
      "patient_response": "...",
      "conversation_state": { ... }
    },
    ...
  ]
}
```

### Coverage summary (one per state, aggregated across all personas)
```json
{
  "patient_state": "stable",
  "total_questions": 16000,
  "total_authored_answers": 87,
  "answer_distribution": {
    "answer_id_1": { "hit_count": 234, "questions": ["...", "..."] },
    ...
  },
  "saturation_curve": [...]   // new-answer rate per 100 questions, should approach zero
}
```

### Convergence signal
The number we care about: **new-answer generation rate**. After enough questions, this should approach zero. If it's still going up at 1000 questions, either personas are too varied, generality is being authored too narrowly, or our coverage estimate was wrong. The saturation curve tells us when to stop.

---

## Off-Topic Handling During Runtime

**Adversarial personas explicitly DO generate off-topic input.** This is necessary for two reasons:
1. Populates the redirect/deflection bank with real attack patterns
2. Validates that the off-topic classifier correctly routes them all to the deflection category, not somewhere else

For these personas, system prompt explicitly instructs them to attempt off-topic, sexual, violent, system-breaking input. The classifier should bucket all of these to `off_topic` category, where they all map to the same small bank of redirect responses (~5-8 variants).

If the classifier sometimes gets these wrong (e.g., classifies a sexual joke as a real question and generates a new patient answer for it), THAT is a bug we want to surface during autorunning. Log every misclassification for manual review.

---

## Open Questions / TBD

1. **Patient LLM during autorun:** is it the same LLM as the shipped game (Sonnet 4.5)? Probably yes for fidelity. Cost implications at 64,000 questions per condition × 50 conditions = significant. Worth costing out.
2. **Clustering threshold tuning:** 0.8 confidence is a guess. May need calibration with manual review of borderline cases.
3. **Persona prompt engineering:** the adversarial personas in particular need careful prompting to actually attempt the attacks instead of refusing. May need iteration.
4. **State setup automation:** "manually flip patient state" — is there a dev hotkey for this, or are we using existing state-transition triggers? Need a no-cost state-flip mechanism for testing.
5. **Resumability:** if a 1000-question run fails partway through, can it resume? Or do we restart? Answer affects how we structure session IDs and intermediate writes.
6. **Pediatric persona authorship sensitivity:** the kid personas will sometimes ask weird things that aren't malicious but aren't mainstream-clinical either. Marcus's responses to a 6-year-old "doctor" should still be in-character but warm. Worth a separate authoring pass after the kid runs.

---

## Implementation Order

**Session N (autorunner build):**
1. Skeleton `auto_runner.gd` script that can drive the game programmatically (input field injection, popup interaction)
2. Persona definition file format + first 3 personas (one clinical pro, one adversarial, one pediatric) for testing
3. Doctor-LLM call wrapper with full context assembly
4. Inline clustering classifier (LLM-based, "does this fit existing answer Y/N")
5. Per-session JSON logging
6. Run pilot: 100 questions on `stable` state with 3 personas, see if architecture works

**Session N+1+:**
- Author all 16 personas
- Full state coverage runs (`stable` first)
- Coverage report + saturation curve analysis
- Begin physician review of new authored answers
- Iterate on persona prompts based on output quality

**Out of scope until autorunner proves itself:**
- Local classifier training (the AUTHORED_RESPONSE_SYSTEM.md "Future" section)
- Auto-runner for non-history categories (exam already has its own architecture, MEDDY/labs/imaging may follow different patterns)
- Multi-condition coverage (start with appendicitis, generalize after)

---

## Decision log (Session 30)

- Persona categories: clinical pro + adversarial + pediatric — John approved
- 16 anchor personas total — John's instinct: 6/6/4 split
- AP limits removed during autorun — John approved
- Manual state flipping (not natural progression) — John approved  
- Doctor LLM gets full case context — John approved (with hesitation)
- Inline clustering, not post-process — John approved
- Adversarial personas generate off-topic deliberately — John approved
- Termination = fixed question cap per persona × state run — John's call
- Greedy clustering with ≥0.8 confidence threshold — Claude's suggestion, John deferred
- Per-session JSON + aggregated coverage report — Claude's call, John deferred
