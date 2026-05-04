# MedRPG — Scoring, Economy & Difficulty Design Spec
*Captured Session 30. Implementation deferred to Session 31+.*
*This document is the single source of truth for the score/XP/bonus/AP economy until those systems are built. After implementation, this doc supersedes prior bonus_points / harm_points language elsewhere — most existing references will be refactored.*

---

## Core Loop

Score is the primary win condition. Diagnosis and treatment are necessary but not sufficient. The game is a real-time + turn-based puzzle where the better you do, the harder the next run gets, with global (cross-case) difficulty tracking and per-case scoring.

```
Run starts → Player works the case → Run ends:
  Win  = correct diagnosis(es) + correct key treatment(s) + score ≥ goal_score
  Lose = AP depleted, ran out of time, wrong disposition, or any win req unmet
       + (if score ≥ goal but missed dx/treatment, still counts as lose)
```

---

## The Four Currencies

| Currency | Time Horizon | Earned By | Spent On |
|---|---|---|---|
| **AP** (Action Points) | In-run | Starting allocation per case | Actions, MEDDY hints, badge draws, diagnosis guesses |
| **Score** | Per-run | Doing relevant clinical actions | (Not spent — this is the run-quality measurement) |
| **Bonus Points** | Persistent | Leftover AP at win, perfect runs, rare events | Power-ups / boost badges between runs |
| **XP** | Persistent | Score over goal, AP leftover, partial runs | RPG progression — unlocks cases, cards, shop items |

### AP — the in-run engine
Spent to do anything that costs AP. **New uses confirmed this session:**
- **Diagnosis guess: −2 AP per attempt.** Anytime, unlimited, self-regulating via AP scarcity.
- **MEDDY hint: −2 AP per hint** (per-lab, per-finding). Differential diagnosis hint costs more (TBD, probably 4-5 AP).
- **Badge draw mid-run: −X AP** (cost TBD, balance with rarity).

### Score — per-run quality measurement
Awarded for clinically valid, *relevant* actions. **Confirmed this session:**
- **Tier (c) authoring philosophy:** every action gets a score value tagged in the case file. Relevant = high. Irrelevant-but-not-harmful = **0**. Harmful = harm point, not score.
- **Score values are case-specific.** Lipid panel for appendicitis = 0. CBC for appendicitis = high. Each case file specifies its own per-action score values.
- Player can see goal score and max score from run start.
- Score above goal converts to XP at run-end: **1 score over goal → 10 XP.**

### Bonus Points — persistent meta-currency for power-ups
- Carry across runs (win or lose).
- **Earn at win: 1 bonus point per 5 AP leftover at win.**
- Earn small amounts on lose runs proportional to score accrued.
- **Perfect run bonus: 1 bonus point + Perfect Run achievement.** First perfect run on a case unlocks a new boost badge in the deck (e.g. "Gunner" badge for first appendicitis perfect).
- **Spent between runs** on:
  - Boost badges (guaranteed, cost varies by badge tier)
  - Removing burnout/hot-mess badges from active deck
  - Other power-ups (TBD — see Power-up Catalog section)
  - Re-rolling shop offerings

### XP — persistent RPG progression
- Earned from score, AP leftover at win, and partial credit on losses.
- **Conversion rates confirmed:**
  - 1 score over goal → 10 XP
  - 1 AP leftover at win → 10 XP
  - 10 score points (lose run) → 5 XP
- Unlocks: new cases, new cards, new badges, new shop items.

---

## The Time Pressure Mechanic

**Real-time clock matters in a way that feeds AP economy:**
- Every 2 minutes of real elapsed time → −1 AP from leftover-AP-at-win bucket.
- This does NOT take AP from the player's current pool. It debits the *future* leftover bucket — i.e. the amount that converts to bonus points and XP at win.

**HUD requirement (must implement):**
- Visible counter: "Bonus AP: 23 (−1 in 47s)"
- Running total of AP debited to time so far during this run.
- Otherwise the rule is invisible and players will feel cheated when bonus points come out lower than expected.

**Why this design:** efficiency and speed become the same axis. Sitting and thinking has an explicit, visible cost. The player who finishes fast with AP remaining gets compounded reward (leftover AP × XP rate + leftover AP / 5 → bonus points), the player who dawdles loses both.

---

## Win/Loss Rules

### Win requirements (all required)
1. **Correct diagnosis(es)** — case file specifies how many diagnoses needed. Most cases = 1. Some cases = 2 (e.g. DKA + new T1DM, sepsis + appendicitis perforation).
2. **Correct key treatment(s)** — case file specifies. Appendicitis = appendectomy.
3. **Score ≥ goal_score** — case file specifies the threshold.

### Diagnosis mechanics
- Player can guess at any time, as many times as they want.
- Each guess costs 2 AP regardless of correctness.
- Multi-diagnosis cases: enter one at a time. UI shows "0/2 diagnoses made" until both filled.
- Wrong guesses don't lock anything — keep trying until you get it or run out of AP.

---

## Per-Case Scoring Schema (NEW)

Each condition file gets a top-level `scoring` block:

```json
"scoring": {
  "goal_score": 60,
  "max_score": 145,
  "win_requirements": {
    "diagnoses_required": ["appendicitis"],
    "treatments_required": ["appendectomy"]
  }
}
```

Per-action `score_value` fields get tagged onto:
- Each lab/panel in `appendicitis_labs.json`
- Each imaging study in `appendicitis_imaging.json`
- Each exam system + maneuver in `appendicitis.json`
- Each medication in a NEW per-case medication scoring file (or in `appendicitis.json`)
- Each treatment/procedure in `appendicitis_other_treatments.json` and `appendicitis_surgeries_procedures.json`
- Each disposition outcome in `appendicitis_end_conditions.json`

**Defaults:** if `score_value` is not specified on an action, the action awards 0 score points. Authoring philosophy: don't tag irrelevant actions; only tag relevant ones with their tier value.

---

## Schema Refactor Required

The existing data has `bonus_points` doing two jobs simultaneously — the "did you do the right thing" job (which is now score) AND the "rare cool action" job (which stays bonus). All current references need triage:

### Files affected and triage rules
| File | Current uses | Triage |
|---|---|---|
| `appendicitis.json` | `exam_bonus_points.opportunities` (5 maneuvers + 2 stability checks) | All 5 maneuvers → score points. Stability checks → likely score (they're "did the right thing" markers). |
| `appendicitis.json` | `bonus_points: 1` on `meddy_first_use` (line ~927) | Probably stays as bonus — discovering MEDDY is "cool action." |
| `appendicitis.json` | `harm_points` block | Stays as harm_points. No change. |
| `appendicitis_labs.json` | (none — labs don't currently award) | Add `score_value` per lab/panel. |
| `appendicitis_imaging.json` | (none) | Add `score_value` per imaging study. |
| `appendicitis_other_treatments.json` | `bonus_points` on IV pre-shock, NPO pre-shock | Both → score. They're "did the right thing." |
| `appendicitis_surgeries_procedures.json` | (none currently — note "total_available_bonus_points: 0") | Add `score_value` per procedure. |
| `appendicitis_end_conditions.json` | `bonus_points: 10` for appendectomy, `bonus_points: 3` for mega hospital partial credit, `bonus_points: 0/1` per disposition outcome, `bonus_points_still_awarded_after_wrong_guess: true` flag | Most → score. Appendectomy itself = high score (30+). Disposition decisions → score. The "still awarded after wrong guess" flag becomes a score flag. |

### Engine refactor
- Rename `bonus_points` tracking variable → `score` for run measurement
- Add new `bonus_points` variable for the persistent currency (carries across runs — needs save/load)
- Wherever the engine currently does `add_bonus_point(reason)`, decide per-call whether it's now `add_score_point(amount, reason)` or stays as `award_bonus_point(reason)`
- New persistent state: `bonus_points` (carries between runs), `xp_total` (carries across all runs forever), `unlocks_earned` (cases, badges, etc.)

### PROJECT_NOTES refactor
Schema docs need updating after refactor. The "exam_bonus_points" subsection in particular needs renaming.

---

## Difficulty Ramp System

### How difficulty escalates
**Source: roguelike difficulty cards.**
- After every run, player draws cards based on run quality:
  - Good run (significantly above goal): draw 2 cards
  - Mediocre run (around goal): draw 1 card
  - Bad run (below goal or lose): draw 0 cards or get a "Reprieve" effect (e.g. -15 starting score threshold for next case)
- **Player-selected from 3 options** — drawn 3 cards, pick 1. Cannot decline completely.
- Cards are persistent active modifiers for upcoming runs (until consumed/expired).

### Difficulty tracking is global
- Cross-case. Performance on one case affects difficulty on the next, regardless of what case it is.
- In the final game, cases are random — undifferentiated patients walk in.
- Game keeps getting harder indefinitely. Major XP/bonus rewards for difficult runs.

### Difficulty card examples (TBD — need full deck)
- *Time Crunch* — −15% real-time clock
- *Skeleton Crew* — −20 starting AP
- *Restless Patient* — state transitions 25% faster
- *Score Pressure* — goal score +15 points
- *Stingy Labs* — −5 AP per lab order (or +1 AP cost per lab, equivalent)
- *No MEDDY* — Ask MEDDY tabs disabled this run
- *Anchored Reasoning* — first wrong diagnosis costs 5 AP instead of 2
- *Authoring TBD:* full deck needs design pass — aim for 20-30 cards across multiple categories (clock, AP, patient behavior, info access, scoring).

### Reprieve cards (after bad runs)
- Mirror image of difficulty cards but in player's favor
- *Time Cushion* — +20% real-time clock for next run
- *Field Medicine* — +15 starting AP
- *Lower Bar* — −15 to goal score for next case
- *MEDDY's Back* — free MEDDY hint (no AP cost) once next run

---

## Badge System Architecture

### Categories
- **Boost badges** — positive run modifiers. Earned via shop, achievements, perfect runs.
- **Burnout badges** — negative run modifiers. Earned via harm-triggered draws.
- **Hot Mess badges** — mixed effects. (e.g. "+10 starting AP, −20% real-time clock"). The spicy ones.
- **Achievement badges** — purely cosmetic, earned for milestones (Perfect Run, First Win, etc.) — could also unlock new boost badges in the deck.

### Earning badges in-run
- Successful clinical action → potential boost badge draw (low chance, e.g. on rare correct moves)
- **Any badge draw has a 15% chance of pulling a harm/burnout badge instead** of the intended boost. Roguelike spice.
- Harm-triggered draw (after harm point accrues): 85% burnout, 15% other (could even pull boost). 
- Badges stack on top of each other. Want satisfying combos and multipliers (Balatro DNA).

### Earning between runs
- Bonus point shop: spend bonus points for guaranteed boost badges
- Achievement unlocks: e.g. first perfect appendicitis run unlocks "Gunner" boost badge in deck

### Existing data files to update
- `boost_badges.json` — needs the actual badge catalog
- `burnout_badges.json` — needs catalog
- `badge_youtock_dialogue.json` — exists for one specific burnout badge
- New: `hot_mess_badges.json`
- New: `achievement_badges.json`

---

## Power-Up Catalog (for between-run shop)

This is an open list — needs design pass when shop UI is built. Captured ideas so far:

### Boost badges (most common shop item)
- Cost varies by power tier
- Player can buy and equip into next run

### Score modifiers
- *Lower Bar* — reduce goal score by N (one-time, expires after use)
- *Cushioned Landing* — gain extra time at run start

### Card economy
- Re-roll the difficulty card draw before next run
- Force-pull a specific card from the difficulty deck
- Increase chance of getting boost badges instead of burnout in mid-run draws

### Achievement-locked
- *Gunner* badge — unlocked after first perfect appendicitis run
- (More TBD as cases get authored)

---

## Shop UI (between runs — TBD)

Sketched concept:
- Screen accessible between runs / in main menu
- Press button → screen displays a small set of cards (boost badges, power-ups, etc.)
- Each card has a bonus point cost listed
- Buy with bonus points, OR pay (smaller amount of) bonus points to re-roll the card selection
- Probably also displays current bonus point balance, recent unlocks, etc.

Other shop screen elements TBD.

---

## Implementation Order (when we come back to this)

**Session 31 priorities:**
1. **Schema refactor first** — JSON files cleaned up before engine code changes. New `score_value` fields, refactored `bonus_points`. Update PROJECT_NOTES schema docs.
2. **Engine state additions** — new `score` variable per run, new persistent `bonus_points` and `xp_total` variables (need save/load infrastructure if not present).
3. **HUD additions** — score counter, goal/max display, bonus AP ticker with countdown to next time-debit.
4. **Diagnosis cost mechanic** — 2 AP per guess, multi-diagnosis support.
5. **Score values populated** — go through every action across the JSON files and tag with relevant score values for appendicitis case.
6. **Time → AP debit** — implement the every-2-minutes deduction.
7. **AP → bonus / XP conversions at run-end** — implement the math.

**Session 32+ priorities:**
- Difficulty card system (deck authoring + draw mechanic + UI)
- Badge system implementation (data structures + effects + draw probabilities)
- Shop UI between runs
- Persistent save/load (XP, bonus points, unlocks across sessions)

**Out of scope until later:**
- Full power-up catalog
- Multi-case progression (Balatro-style run mode)
- Character creator
- Cross-case difficulty tracking ramp formulas

---

## Open Questions Recorded for Later

- Exact ratios for partial-credit losses (we said 5 XP per 10 score, but need to validate it doesn't break the economy)
- Bad-run threshold definition (when do you draw 0 cards vs Reprieve? Is it score-based, time-based, harm-based?)
- Mid-run badge draw frequency / probability tuning
- Difficulty card persistence — do they expire after one run, or stack up like in Slay the Spire?
- Specific score values for each action in appendicitis (need full pass)
- Goal score and max score for appendicitis (need to compute after score values assigned)
- Save/load format — JSON, binary, where to store on user's filesystem?

---

## Session 30 conversation context
This design emerged from a long conversation about game philosophy on Session 30. Key decisions logged:
- Three-currency separation (Score / Bonus / XP) — John approved
- Score depends on relevance (tier c — relevant high, irrelevant 0, harmful gets harm points only) — John approved
- Diagnosis any time, 2 AP per wrong — John approved
- Bonus points carry across wins AND losses — John approved
- Hot Mess badges as third badge category — John approved
- Player-select 1 of 3 difficulty cards, cannot decline — John approved
- Per-case score values, not global — John approved
- New file `appendicitis_score_values.json` OR all in `appendicitis.json` — John leaning toward per-case file
- Refactor scoped, deferred to next session
