# Individual Technical Reflection

Weighted at 3 of the 40 marks, and it is the section an assessor reads to judge whether
the portfolio is yours. Write it in the first person, and be specific — specificity is
what makes it credible.

> Avoid: "I learned a lot about databases and improved my skills."
> Prefer: "I assumed the composite index on `(doctor_id, slot_start)` would serve the
> range query. The plan showed a bitmap heap scan instead, because the leading column
> had low cardinality across the filtered set. Reordering to `(slot_start, doctor_id)`
> changed the plan to an index range scan."

---

## 1. What I Built

_<Three or four sentences. The case study, and the shape of the finished system.>_

## 2. Design Decisions I Would Defend

Pick two or three where there was a genuine fork in the road, and state the trade-off:

**Decision:** _<what it was>_
**Alternatives:** _<what else was plausible>_
**Chose it because:** _<the reason>_
**Cost:** _<what it gives up>_

## 3. What Surprised Me

The most useful paragraph in the document. Look for:

- A query that was slow for a reason you did not predict.
- A constraint that turned out to be doing more work than you thought.
- A "best practice" that made things worse in your specific workload.
- A difference between what the textbook says a database does and what the plan showed.

_<Write it>_

## 4. The Hardest Problem

**What it was:**
**Why it was hard:**
**How I got unstuck:**
**What I would do differently:**

Honest dead ends are valuable here — they are the strongest available evidence of
independent work.

## 5. Mistakes and Corrections

_<Name at least one. A reflection with no mistakes reads as reconstructed after the fact.>_

**What I got wrong:**
**How I noticed:**
**What I changed:**
**What it changed about how I work:**

## 6. Where the Design Is Weak

Not everything needs fixing, but an assessor trusts a student who knows the soft spots:

- What breaks first at 10× the data?
- Which part would you rebuild if you started again?
- What did you leave out under time pressure, and what does that cost?

## 7. What I Would Do Next

_<Two or three concrete items, not a wish list.>_

## 8. On AI Assistance

_<One short, honest paragraph referencing the declaration. Which parts were aided, what
you verified yourself, and what you chose not to use AI for. A specific, calm statement
is far more convincing than an emphatic "I did everything myself.">_

## 9. Skills Carried Forward

_<Two or three things you can now do that you could not do before this assessment. Phrase
them as capabilities, not topics covered.>_
