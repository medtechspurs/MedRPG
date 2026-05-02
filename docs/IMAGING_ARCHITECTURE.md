# MedRPG Imaging System — Architecture Documentation

## Overview
The imaging system mirrors the labs system architecture but adapted for diagnostic imaging studies.
Imaging orders are individual studies (no "panels"), with descriptive text results instead of numeric values.

## File Structure
- `data/imaging/master_imaging.json` — comprehensive list of all imaging studies, AP costs, modality categories, contrast requirements, age restrictions, stability restrictions
- `data/conditions/appendicitis_imaging.json` — state-based result text for each imaging study in appendicitis case
- `scripts/imaging_system.gd` — popup UI script (mirrors labs_system.gd architecture)

## AP Cost Tiers
- Plain film: 1 AP
- Ultrasound (most): 1 AP
- Ultrasound (complex protocols — testicular doppler, OB, transvaginal): 2 AP
- CT non-contrast: 2 AP
- CT with contrast (any kind): 3 AP
- CT angiogram: 3 AP
- MRI non-contrast: 3 AP
- MRI with contrast (any kind): 4 AP
- MR angiogram: 4 AP
- Fast MRI brain (stroke): 2 AP
- Nuclear medicine: 3 AP
- Fluoroscopy: 2 AP

## Result Delays
Imaging results have time delays representing real-world acquisition + read time.
**Both real-time and turn-based delays apply — whichever is LATER blocks result release.**

| Modality            | Real-time delay | Turn delay |
|---------------------|-----------------|------------|
| Plain film          | 30 sec          | 1 turn     |
| Ultrasound          | 30 sec          | 1 turn     |
| CT (any)            | 1 minute        | 1 turn     |
| MRI (any)           | 2 minutes       | 2 turns    |
| Fast MRI brain      | 1 minute        | 1 turn     |
| Nuclear medicine    | 5 minutes       | 3 turns    |
| Fluoroscopy         | 1 minute        | 1 turn     |

When ordered, the study appears in Results view immediately with status `⏳ Pending — results in X turns / Y seconds`. When both delays have elapsed, the status flips to the actual finding text.

These values are tunable in master_imaging.json per study.

## Contrast Requirements & IV Dependency
Studies flagged `requires_iv_contrast: true` cannot be ordered if patient does not have an IV in place.

If patient has IV:
- Ordering a contrast study triggers a confirmation popup: "Give IV contrast for this study?"
- IV contrast does NOT cost separate AP (bundled into study cost)
- Contrast confirmation should warn if patient has documented contrast allergy or significant renal failure (Cr >2.0)

Studies that involve oral contrast (CT abdomen/pelvis with oral) require IV access too if also IV contrast, plus add ~30 sec real-time delay for oral contrast administration.

## Stability Restrictions
Studies flagged `requires_stable: true` cannot be ordered when patient is in unstable states.

For appendicitis case:
- Unstable states: `septic_shock`, `coma_fail`
- Blocked when unstable: ALL MRI studies EXCEPT fast MRI brain
- Allowed when unstable: all CT, plain films, ultrasound, fast MRI brain, nuclear medicine

When player attempts to order a blocked study:
- Show popup: "Patient too unstable for [Study Name]. They cannot lie still in the MRI scanner."
- Cancel order, no AP charged

## Pediatric Restrictions
Studies flagged `pediatric_only: true` only appear in case patient demographics are pediatric (<18yo).
- Currently: pediatric skeletal survey (child abuse workup)

## Modality Categories (UI Browser)
- Plain Films (X-Ray)
- Ultrasound
- CT
- CT Angiogram
- MRI
- MR Angiogram
- Nuclear Medicine
- Fluoroscopy

## Result Caching
Same as labs: results cached per `(study_id, patient_state)`.
Re-ordering same study in same state returns same result.
Cache cleared on state transition or on explicit intervention (e.g. drainage of abscess might warrant repeat CT).

## Result Text Format
Unlike labs (numeric value + reference range), imaging results are radiologist-style report text:
```
{
  "findings": "Multiline radiologist findings...",
  "impression": "Short bulleted impression",
  "is_abnormal": true/false  // for the red-flag indicator
}
```

Standalone studies not in condition_imaging.json fall back to "Normal study" template.

## UI Mirrors Labs System
- Three tabs: Search by Name, Browse Modalities, Ask MEDDY
- Selection chips with AP cost
- Two-step confirm flow
- Results view with collapsible studies (one expand per study, not two-level since no panels)
- Hover highlight on rows
- Column headers: Study Name | Modality | AP Cost
