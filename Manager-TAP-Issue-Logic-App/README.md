# TAP Issuing by Manager

## What this is

`la-idgov-issuetap-prod.json` deploys an Azure Logic App ("Playbook") whose logic is meant to act as an **Entra ID Governance custom extension** for an Access Package assignment policy:

1. Entra ID Entitlement Management calls the Logic App's HTTP endpoint when an access package request reaches a configured pipeline stage.
2. The workflow checks the request is for a specific `AccessPackageCatalog` (placeholder ID `AccessPackageCatalogId` — replace with your real catalog ID) and that the `Stage` is `assignmentRequestApproved`.
3. If both match, it calls Microsoft Graph to generate a **Temporary Access Pass (TAP)** for the target user (`Assignment.Target.ObjectId`).
4. It emails the TAP to a recipient (`EmailRecipient`), using Microsoft Graph `sendMail` from a sender mailbox (placeholder `emailsender@sender.com` — replace with your real sender) via the Logic App's system-assigned managed identity.

The template deploys the workflow with `state: "Disabled"` and a `Recurrence` trigger (every 15 minutes) by default — it is **not wired to Entra ID Governance out of the box**. See "How this template is meant to be used" below.

Parameters:
- `playbookName` — name of the Logic App resource (default `Playbook-Name`).
- `resourceGroupLocation` — location for the resource (defaults to the resource group's location).

## Assigning Microsoft Graph permissions (`LogicApp-Permission.ps1`)

The Logic App authenticates to Microsoft Graph using its **system-assigned managed identity**. Since managed identities can't consent to permissions themselves, `LogicApp-Permission.ps1` grants the required Graph **application permission** (app role) directly via Microsoft Graph PowerShell:

- Connects with `Application.Read.All` and `AppRoleAssignment.ReadWrite.All` delegated scopes (needs an admin who can grant app role assignments).
- Assigns the Microsoft Graph application permission **`TemporaryAccessPassAuthenticationMethod.ReadWrite.All`** to the Logic App's managed identity (identified by `$managedIdentityObjectId`, the **object ID of the managed identity's service principal**, not the Logic App's resource ID) — this is what allows `Generate_TAP_via_Microsoft_Graph` to create a TAP for the target user.

Before running it:
1. Deploy the Logic App first so its managed identity exists.
2. Get the managed identity's service principal object ID (e.g. Azure Portal → Logic App → Identity → Object (principal) ID) and set `$managedIdentityObjectId`.
3. Run the script as a user/role that can grant admin-consented application permissions.

**Note:** the script only grants `TemporaryAccessPassAuthenticationMethod.ReadWrite.All`. The workflow's `Send_Email_via_Microsoft_Graph` action also needs mai send permissions [Role Based Access Control for Applications](https://learn.microsoft.com/en-us/exchange/permissions-exo/application-rbac)

## How this template is meant to be used

As shipped (`Recurrence` trigger, `state: Disabled`), this template can be deployed purely to **inspect/test the TAP generation and email logic** (the `Condition` → `Generate_TAP_via_Microsoft_Graph` → `Parse_JSON` → `Set_variable` → `Send_Email_via_Microsoft_Graph` actions). It is **not** meant to be wired up to Entra ID Governance in this form — a `Recurrence` trigger has no `triggerBody()` payload, so all `triggerBody()?[...]` expressions resolve to `null` until a real trigger/payload is supplied.

To actually use it as a custom extension, do **not** hand-edit the trigger and manually link it to a catalog/access package. Instead:

1. Create the custom extension from the **Entra ID Governance portal** (Identity Governance → Custom extensions → Logic App), which provisions its own manual `Request`/`Http` trigger with the correct schema and `accessControl` (AADPOP) authentication policy already wired to the specific catalog/access package/policy stage you select there.
2. Copy the `actions` block from this Logic App (TAP generation + email) into the Logic App that the portal creates/links, so the generated trigger, its authentication, and the catalog/access package association all come from Entra ID Governance itself instead of being reproduced by hand.
3. Enable the workflow (`state: "Enabled"`) once it is correctly wired.
4. Keep this repo's version around as a reference/sandbox for the TAP + email logic only.