# Final Documentation and Technical Reflection

**Student:** Abdulrasheed Abdulrazak<br>
**Matriculation number:** 2026/A/MIT/0734<br>
**Student ID:** 301926758

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

- [x] Case study clearly stated
- [x] All five activities use the same case study consistently
- [x] All five activities completed
- [x] Repository properly organised
- [x] Practical work and supporting evidence included
- [x] README/documentation explains the work
- [ ] Required files submitted through LMS (summary PDF and repository link)
- [x] GitHub link works and is accessible to the assessor (public repository)
- [x] Sources, datasets and libraries referenced
- [x] AI use declared
- [x] Individual reflection included

## Two Things Easy to Forget

**Repository access.** The repository is **public** (confirmed via the GitHub API on
30 October 2026: `visibility=public`). The assessor does not need an invitation. Verify
by opening <https://github.com/bigphysiology-coder/advanced-database-portfolio> in a
signed-out window; if it asks for a login, access has regressed. A dead link on a
40-mark submission is an avoidable tragedy.

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

The summary leads with measured results and cites the repository path for each piece of
evidence. The raw terminal captures are stronger than cropped screenshots and are kept
in the five portfolio folders, so the PDF stays within the 2–3 page limit.

## Exporting the PDF

The LMS copy is generated from the Markdown source so the text and links stay
consistent:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/export-summary.ps1
```

The script renders `portfolio-summary.md` to A4 PDF with Chrome or Edge and writes
`final-documentation/portfolio-summary.pdf`. Open the PDF and confirm it is 2–3
pages before uploading it.
