# Final Documentation and Technical Reflection

**Marks:** 6 / 40 — combined for the 2–3 page summary, GitHub quality, and reflection.

This is not a formality. It is where an assessor who cannot interview you decides whether
you understood the work or merely produced it.

## Deliverables

| Item | Where | Marks live in |
|---|---|---|
| 2–3 page portfolio summary | `portfolio-summary.md` → exported PDF → LMS | Description of all five activities |
| GitHub link | in the LMS submission text | Repository accessibility |
| Evidence | committed across all five folders | Screenshots, plans, outputs |
| Individual reflection | `reflection.md` | `3` marks under "technical reflection" |
| AI use declaration | `../docs/ai-use-declaration.md` | Integrity requirement |

## Submission Checklist (from the brief, p.7)

- [ ] Case study clearly stated
- [ ] All five activities use the same case study consistently
- [ ] All five activities completed
- [ ] Repository properly organised
- [ ] Practical work and supporting evidence included
- [ ] README/documentation explains the work
- [ ] Required files submitted through LMS
- [ ] GitHub link works and is accessible to the assessor
- [ ] Sources, datasets and libraries referenced
- [ ] AI use declared
- [ ] Individual reflection included

## Two Things Easy to Forget

**Repository access.** The repo is private but must be readable by the assessor *before*
submission. Confirm the account to invite, and verify by opening the link in a signed-out
or non-collaborator session. A dead link on a 40-mark submission is an avoidable tragedy.

**Progressive commits.** If the commit graph is a vertical line on the final day, the
evidence-of-development criterion fails regardless of content quality. Check the
contribution graph before submitting.

## Writing the Summary

2–3 pages, so roughly 900–1,300 words. Structure that fits the marks:

| Section | Length |
|---|---|
| Case study and why it was chosen | ¼ page |
| P1 design: the model and the key decisions | ½ page |
| P2 optimisation: what was slow, what fixed it, with numbers | ½ page |
| P3 concurrency: the anomaly and the mechanism chosen | ½ page |
| P4 NoSQL: what moved and why the boundary sits there | ½ page |
| P5 distribution: the trade-off and its evidence | ¼ page |
| Reflection | ¼ page |

Lead each section with a result, not a preamble. "The patient-history query fell from
4,812 ms to 12 ms after a covering index on `(patient_id, collected_at)`" communicates
more than a paragraph describing the intent to optimise queries.

Include 2–3 screenshots inline and reference the rest by repository path.
