# compliance/catalog/

Reference data for the compliance platform: the full text of a control framework and its
mappings onto neighbouring frameworks, keyed by requirement id.

## What is here

- **`nist-800-171r2.json`** — all 110 security requirements of NIST SP 800-171 Rev. 2
  across its 14 families, each carrying its mappings to NIST SP 800-53 Rev. 5, CMMC 2.0
  and FAR 52.204-21.

Shape (spec §3.1):

```json
{
  "framework": "nist-800-171r2",
  "requirements": [
    { "id": "3.5.3", "family": "3.5", "familyName": "Identification and Authentication",
      "title": "Use multifactor authentication for ...",
      "mappings": {
        "nist-800-53r5": ["IA-2(1)", "IA-2(2)"],
        "cmmc-2.0": ["L2-3.5.3"],
        "far-52.204-21": []
      } }
  ]
}
```

The file also carries `frameworkName`, `sourceDocument` and `note` at the top level, so a
copy of it separated from this README still says what it is and where it came from.

## What this catalog is — and is not

**It is authored reference data.** Every value in it was transcribed by hand from a
published document. Nothing in it was measured, collected, or derived from this estate.

**It is not evidence, and it asserts nothing about anyone's compliance.** A requirement
appearing here means only that the standard contains that requirement. The catalog carries
no status field of any kind: it never says `GAP`, never says `CLOSED`, and — consistent
with the **Register vocabulary** in [`../README.md`](../README.md) — never says
`COMPLIANT`. Status for a control comes from `compliance/assessment/` and, later, from the
collectors and the derivation function in spec §3.4, never from this file.

**Its mappings are authored, not machine-derived.** They are a transcription of the
crosswalks NIST and the FAR publish; they are not computed, and no tooling verified them.
NIST itself states that the Appendix D mappings "are included for informational purposes
and do not impart additional security requirements."

**A reader who needs authoritative text should go to the source**, not to this file.
This catalog exists so a board can render a requirement id with a human-readable label
and a framework filter — not to be quoted to an assessor.

## Sources

| Content | Source |
|---|---|
| Requirement ids, family names, requirement text | NIST SP 800-171 Rev. 2, *Protecting Controlled Unclassified Information in Nonfederal Systems and Organizations* (February 2020, updated 28 January 2021), **Chapter Three** |
| `nist-800-53r5` mappings | The same document, **Appendix D**, Tables D-1 through D-14 ("Relevant Security Controls"), adjusted for Rev. 5 as described below |
| `cmmc-2.0` Level 2 practices | CMMC 2.0 Level 2 is exactly the 110 requirements of 800-171 Rev. 2, so `L2-<id>` is an identity mapping generated mechanically for every requirement |
| `cmmc-2.0` Level 1 practices and `far-52.204-21` clauses | FAR 52.204-21(b)(1)(i) through (xv), the basic safeguarding requirements |

Primary source PDF: <https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-171r2.pdf>

Requirement text was extracted from that PDF rather than retyped, then the Appendix D
mappings were cross-checked requirement by requirement against a second transcription of
the same tables. Footnote markers embedded in the published requirement text (for example
the `23` following 3.1.19) were stripped; no other wording was altered.

## Read this before trusting a mapping

Four things in this file are **editorial decisions or known discrepancies**, not
straight transcription. Each is listed here so it can be checked against the source rather
than discovered later.

### 1. CMMC Level 1 is 17 practices, not 15

FAR 52.204-21(b)(1) contains **fifteen** basic safeguarding requirements. CMMC 2.0
Level 1 contains **seventeen** practices. Both statements are true: clause
**(b)(1)(ix)** — *"escort visitors and monitor visitor activity; maintain audit logs of
physical access; and control and manage physical access devices"* — is a single clause
covering three separate 800-171 requirements, **3.10.3, 3.10.4 and 3.10.5**.

So this catalog contains **17 requirements with a `far-52.204-21` clause reference and an
`L1-<id>` practice**, drawn from **15 distinct clauses**. `compliance/tests/catalog.Tests.ps1`
asserts both numbers. Trimming the set to 15 to make the two counts agree would silently
drop two genuine Level 1 practices — and Level 1 coverage is the first thing an adopter
checks.

The 17: 3.1.1, 3.1.2, 3.1.20, 3.1.22, 3.5.1, 3.5.2, 3.8.3, 3.10.1, 3.10.3, 3.10.4,
3.10.5, 3.13.1, 3.13.5, 3.14.1, 3.14.2, 3.14.4, 3.14.5.

### 2. Appendix D cites Rev. 4 controls; the mapping key says Rev. 5

800-171 Rev. 2 was published before 800-53 Rev. 5, so its Appendix D cites **Rev. 4**
control identifiers. Most are unchanged in Rev. 5 and are carried across verbatim. **Seven
were withdrawn in Rev. 5**, and for those this catalog records the Rev. 5 successor
instead, so that no value under the `nist-800-53r5` key names a control that does not
exist in Rev. 5:

| Requirement | Appendix D (Rev. 4) | Recorded here (Rev. 5) | Why |
|---|---|---|---|
| 3.3.3 | AU-2(3) | AU-2 | AU-2(3) withdrawn; incorporated into AU-2 |
| 3.3.7 | AU-8, AU-8(1) | AU-8, SC-45(1) | AU-8(1) withdrawn; moved to SC-45(1) |
| 3.5.3 | IA-2(1), IA-2(2), IA-2(3) | IA-2(1), IA-2(2) | IA-2(3) withdrawn; incorporated into IA-2(1) |
| 3.5.4 | IA-2(8), IA-2(9) | IA-2(8) | IA-2(9) withdrawn; incorporated into IA-2(8) |
| 3.8.6 | MP-5(4) | SC-28(1) | MP-5(4) withdrawn; incorporated into SC-28(1) |
| 3.8.8 | MP-7(1) | MP-7 | MP-7(1) withdrawn; incorporated into MP-7 |
| 3.13.14 | SC-19 | SC-7 | SC-19 withdrawn; incorporated into SC-7 |

**These seven rows are the least certain content in the file.** The withdrawals are
documented in 800-53 Rev. 5, but choosing the successor is a judgment, and 3.8.6 in
particular moves from a media-transport control to a data-at-rest one. Verify these seven
against 800-53 Rev. 5 Appendix A before relying on them.

### 3. Basic requirements share one Appendix D row

In Appendix D, the *Basic Security Requirements* of a family are frequently presented as a
**single merged row** against a single list of controls, rather than one row per
requirement. Where that is so, **every requirement in the merged row carries the whole
list** — which is what the published crosswalks also do, and which is the only reading
that neither invents a correspondence the source does not state nor drops a control the
source does list.

The consequence is that these mappings are deliberately coarse. 3.12.4 (system security
plans) carries `CA-2, CA-5, CA-7, PL-2`, not `PL-2` alone; 3.13.2 (security engineering
principles) carries `SC-7, SA-8`, not `SA-8` alone. The requirements affected are the basic
requirements of families 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.9, 3.10, 3.12, 3.13 and 3.14.
Family 3.8 lists its basic requirements one row each in the source and is recorded that
way; family 3.11 has a single basic requirement, so the question does not arise.

Some *derived* requirements share a row too — 3.5.7 through 3.5.10 against IA-5(1), 3.10.3
through 3.10.5 against PE-3, 3.14.4 and 3.14.5 against SI-3 — but each of those rows lists
one control, so the same rule produces no ambiguity. Every other derived requirement has
its own row and is recorded individually.

### 4. 3.8.1 and 3.8.2 read counterintuitively

Appendix D Table D-8 pairs **3.8.1** ("protect — physically control and securely store —
system media") with **MP-2 Media Access**, and **3.8.2** ("limit access to CUI on system
media") with **MP-4 Media Storage**. Read against the control titles, those look swapped.
They are recorded as the table has them. If a reviewer concludes the table's own row
alignment is being misread here, 3.8.1 → MP-4 and 3.8.2 → MP-2 is the alternative.

## Counts

110 requirements across 14 families — 3.1 (22), 3.2 (3), 3.3 (9), 3.4 (9), 3.5 (11),
3.6 (3), 3.7 (6), 3.8 (9), 3.9 (2), 3.10 (6), 3.11 (3), 3.12 (4), 3.13 (16), 3.14 (7).
All 110 carry a CMMC 2.0 Level 2 practice; 17 also carry a Level 1 practice. 122 distinct
800-53 Rev. 5 controls and control enhancements are referenced.

These are counts of *requirements in a standard*. They are not a score, and no percentage
is derived from them anywhere in this platform — see spec §3.4 on why a blended
"% compliant" figure is the one number a compliance tool must not produce.

## Tests

`compliance/tests/catalog.Tests.ps1` asserts the structure a partial or drifted
transcription would break: the total, the per-family counts, contiguous numbering within
each family, one `familyName` per family, no duplicate ids, a non-empty title and at least
one 800-53 control on every requirement, only the three agreed mapping keys, the Level 2
identity mapping, and the Level 1 / FAR sets described above.

No test can check that a title is the *real* title, or that a mapping is the *real*
mapping. That is what the sources table and the four caveats above are for.
