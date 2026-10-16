# [ID: DOM-xxx] — <Domain Rule / Workflow Title>

_Date: YYYY-MM-DD · Authors: <Names / AI Agent>_

---

## 1. Context & Scope
* **Business Area**: <e.g., Billing, Payroll, Order Fulfillment, Inventory>
* **Problem / Requirement**: <What business problem does this rule solve?>

---

## 2. Input Data & Signals
* **Inputs**: <List of input variables, fields, or source tables>
* **Outputs**: <Expected results, outputs, or state changes>

---

## 3. Business Rule & Formula (Ground Truth)
The verified, authoritative business logic:

* **Rule Statement**: <Clear human-language explanation of the rule>
* **Mathematical Formula / Logic**:
  ```text
  <Formula or pseudo-code expressing the logic>
  ```
* **Edge Cases & Exceptions**:
  * <Condition 1: What happens if input is 0 or negative?>
  * <Condition 2: Special tiers, exemptions, or overrides>

---

## 4. Implementation Reference
Where this rule lives in the codebase:
* **Code / Measure / Module**: `<e.g., src/billing/tax.ts or DAX [Net_Revenue]>`
* **Test Verification**: `<Reference to unit tests or test cases verifying this rule>`
