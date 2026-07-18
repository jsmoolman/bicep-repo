# Policy Tests

## Overview

This document tracks manual and automated test cases for Azure Policy assignments deployed through this repository.

## Test Cases

### TC-001: Mandatory Tags Enforcement

| Field | Value |
|---|---|
| Policy | `nfi-mandatory-tags` initiative |
| Scope | nfi root management group |
| Effect | Deny |

**Steps:**
1. Attempt to create a resource group without the `Environment` tag.
2. Verify the deployment is denied.
3. Add all mandatory tags and re-deploy.
4. Verify the deployment succeeds.

**Expected result:** Deployment without mandatory tags is blocked; deployment with all tags succeeds.

---

### TC-002: Allowed Locations

| Field | Value |
|---|---|
| Policy | `Allowed locations` (built-in) |
| Scope | nfi root management group |
| Allowed | West Europe, North Europe |
| Effect | Deny |

**Steps:**
1. Attempt to deploy a resource to East US.
2. Verify the deployment is denied.

**Expected result:** Deployment to non-allowed region is blocked.

---

### TC-003: Diagnostic Settings — DeployIfNotExists

| Field | Value |
|---|---|
| Policy | `Deploy diagnostic settings to Log Analytics` |
| Scope | Platform management group |
| Effect | DeployIfNotExists |

**Steps:**
1. Deploy a Key Vault without diagnostic settings.
2. Trigger policy evaluation (or wait for compliance scan).
3. Verify diagnostic settings are automatically deployed.

**Expected result:** Diagnostic settings are created automatically by the policy remediation task.
