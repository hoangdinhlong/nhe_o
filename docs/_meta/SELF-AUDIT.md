# End-of-session self-audit

The checklist an agent runs before ending a session. This is what makes "self-maintaining" real:
without a pass like this, docs rot in a way nobody sees until it is too late.

Fix what can be fixed. What needs a human decision, **report it — don't decide it**.

---

## A. Integrity — mechanical errors

| # | Check | If wrong |
|---|-------|----------|
| A1 | Any `{{placeholder}}` left unreplaced | Replace it, or ask the owner |
| A2 | `_Last updated_` in `STATUS.md` is today's date | Fix it |
| A3 | Every path named in the `AGENTS.md` doc map exists | Fix the path, or create the file |
| A4 | Every folder in `docs/epics/` appears in the `STATUS.md` epic overview, and vice versa | Rebuild the table |
| A5 | Every document in `docs/domain/` is listed in the domain index | Add the row |
| A6 | Ids are unique and never reused (`Q-xxx`, ideas `NNNN-`, ADRs) | Issue a new id; never rewrite an old one |

`A1`-`A3` have ready, tested commands under **Quick checks** below. `A4`-`A6` need judgment.

> **A3 has one legitimate exception**: a path that names a file in *another repository* — for
> example Monion's `<monion>/docs/PROJECTS.md` in the Template provenance section. Do not "fix"
> those by creating a local file.

> **A2 is the check most often skipped.** A stale date makes the next session distrust a `STATUS.md`
> that was just updated — or worse, trust one that wasn't.

## B. Consistency — contradictions

| # | Check | If wrong |
|---|-------|----------|
| B1 | A question in `OPEN-QUESTIONS.md` already answered by an ADR, a domain doc, or a shipped task, yet still `Open` | Mark `Answered → <where the answer lives>`; keep the entry |
| B2 | An idea in `ideas/` that has been built, yet still `Exploring` | Set `Promoted → ADR-xxx` |
| B3 | A task marked done with an empty **Tests** column | Test it, or tell the owner it is unverified |
| B4 | An epic marked done while tasks inside it are open | Reopen the epic, or close the tasks |
| B5 | Code, queries, or formulas that contradict a rule written in `docs/domain/` | **Report immediately** |
| B6 | Work in this session contradicts a reference doc, with no ADR explaining what supersedes it | Update the doc, or append the ADR (see **Core rule** in `AGENTS.md`) |
| B7 | The **Template provenance** stamp is behind the archetype's `CHANGELOG.md` in Monion | Apply the Migration notes above the stamp, or record why this project deliberately stays put |

`B5` and `B7` have ready commands under **Quick checks**. Everything else in this table is a judgment call.

> **B5 is the most important line here.** When code and a documented rule disagree, the danger is not
> the disagreement itself — it is that both keep running, and each side believes it is authoritative.

## C. Project health — signals, not defects

These are not documentation errors. They say something about the real state of the project, and the
agent is asked to say it out loud rather than stay quiet.

| # | Signal | What it means |
|---|--------|---------------|
| C1 | `OPEN-QUESTIONS.md` grows while no epic moves | The project is discussing what to ask instead of asking. |
| C2 | A question **Opened** over 14 days ago with nobody named in **Waiting on** | Rarely because it is hard to answer — usually because nobody was sent to ask. |
| C3 | Formulas and business rules live in code while `docs/domain/` stays empty | The knowledge is one refactor away from being lost. |
| C4 | `STATUS.md` reads the same across several sessions | Either nothing is moving, or the sessions are not recording what they did. |
| C5 | Decisions accumulate but `docs/learning/` never grows | The project is collecting choices without collecting understanding. |
| C6 | A whole epic finishes with an empty **Tests** column | "Done" here means "written", not "working". |

---

## Quick checks

Run from the project root. Each check carries **both variants side by side** — keep them equal in
scope and in meaning; two variants kept apart drift from each other without anyone noticing.

`A4`-`A6` carry no command: comparing a table against a directory needs judgment, not a one-liner.

### A1 - unreplaced placeholders

```bash
grep -rn '{{' . --include='*.md' | grep -v '/_meta/'
```

```powershell
Get-ChildItem -Recurse -Filter *.md | Where-Object { $_.FullName -notmatch '[\\/]_meta[\\/]' } | Select-String '\{\{'
```

### A2 - is the `STATUS.md` date today

```bash
grep -nE '^_.*[0-9]{4}-[0-9]{2}-[0-9]{2}_$' docs/STATUS.md; date +%F
```

```powershell
Select-String -Path docs/STATUS.md -Pattern '^_.*\d{4}-\d{2}-\d{2}_$'; Get-Date -Format 'yyyy-MM-dd'
```

### A3 - doc map paths that do not exist

```bash
grep -oE '`docs/[A-Za-z0-9_./-]+`' AGENTS.md | tr -d '`' | sort -u |
while read p; do [ -e "$p" ] || echo "MISSING: $p"; done
```

```powershell
Select-String -Path AGENTS.md -Pattern '`docs/[A-Za-z0-9_./-]+`' -AllMatches |
    ForEach-Object { $_.Matches.Value -replace '`', '' } | Sort-Object -Unique |
    ForEach-Object { if (-not (Test-Path $_)) { Write-Warning "MISSING: $_" } }
```

### B5 - SPARK_Mode boundary (BR-001: only `src/nheo-io.adb` may disable SPARK_Mode)

```bash
grep -rnE 'pragma +SPARK_Mode *\( *Off *\)' src/ | grep -v '^src/nheo-io\.adb:' || true
```

```powershell
Select-String -Path src/* -Pattern 'pragma\s+SPARK_Mode\s*\(\s*Off\s*\)' | Where-Object { $_.Filename -ne 'nheo-io.adb' }
```

### B7 - the template revision stamp

```bash
grep -oE 'revision \*\*R[0-9]+\*\*' AGENTS.md
```

```powershell
Select-String -Path AGENTS.md -Pattern 'revision \*\*R\d+\*\*' | ForEach-Object { $_.Matches.Value }
```

> All ten commands are **ASCII-only, deliberately**. A command carrying non-ASCII text breaks when
> it is extracted to a temp file and run through `powershell -File`, because PowerShell 5.1 reads a
> BOM-less file as ANSI. That is also why `A2` matches the *date* rather than the words next to it:
> the check keeps working in a project whose docs are written in another language.

---

## End-of-session report

```markdown
**Self-audit — <date>**

Fixed: <short list, or "nothing needed fixing">
Needs the owner's decision: <list, or "none">
Signals worth noting: <which C rows fired, or "none">
```

If all three lines are empty, say plainly that there is **nothing to report**. Never invent a finding
to look thorough — a checklist that always finds something is a checklist nobody trusts.
