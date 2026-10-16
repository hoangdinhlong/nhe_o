# Domain Knowledge & Business Logic

The single source of truth for **domain rules, business formulas, and workflows**.

---

## Why this exists

Technical architecture (`docs/reference/ARCHITECTURE.md`) captures *how the software is built* (tech stack, databases, frameworks).
Domain knowledge (`docs/domain/`) captures *how the business actually works* (pricing rules, tax calculations, commission tiers, order lifecycles).

Without this directory, business logic gets buried inside code, SQL queries, or DAX formulas — and when requirements change, no one remembers *why* the formula was designed that way.

## How to capture domain knowledge

Whether you are:
1. **Writing new software**: Documenting client business requirements and domain models (Domain-Driven Design).
2. **Modernizing legacy systems**: Reverse-engineering formulas from old scripts, stored procedures, or legacy codebases.
3. **Building data analytics / BI**: Reverse-engineering business logic from raw database tables or spreadsheets.

Follow the 4-step reverse-engineering / codification cycle:
1. **Observe & Fingerprint**: Note data fields, input/output relationships, or code flow.
2. **Formulate Hypothesis**: Work with your AI Agent to deduce the underlying rule or formula.
3. **Verify with Stakeholders**: Ask targeted, domain-specific questions to confirm edge cases.
4. **Codify**: Record the confirmed truth using `_TEMPLATE.md` and index it in [business-rules.md](business-rules.md).

## Index of Domain Modules

| ID | Domain / Concept | Source / Owner | Status |
|---|---|---|---|
| `RULE-001` | [Core Business Rules Index](business-rules.md) | Business Stakeholders | Active |
