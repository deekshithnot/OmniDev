# API Key Management — Feature Proposal

## Goal

Improve the **Models & keys** screen so users can manage several credentials for the same provider and decide which models each credential can serve.

## Proposed experience

### Saved keys

- Show saved credentials grouped by provider.
- Let users give each credential a recognizable label (for example, "Personal", "Work", or "Backup").
- Mask secret values by default. Never return a raw secret to the renderer after saving.
- Allow adding, renaming, and deleting a credential.
- Show non-sensitive metadata such as provider, label, and whether the credential is configured.

### Model assignments

- Let a credential be associated with one or more provider model IDs.
- Make it possible to add and remove model assignments without re-entering the secret.
- Keep the existing router fallback order, but make the credential used for each provider/model route explicit.
- Apply cooldowns for credential-specific failures to the affected credential only. Key that cooldown by provider, model, and credential ID so another credential assigned to the same provider/model remains eligible for fallback.
- Keep provider/model-wide cooldowns for failures that cannot be attributed to a specific credential.
- Preserve compatibility with existing provider-level keys and existing router configurations during migration.

## API shape to consider

The current renderer uses provider-level endpoints:

- `GET /models/providers`
- `PUT /models/providers/{provider}`
- `DELETE /models/providers/{provider}`

A future multi-key API could expose:

- `GET /models/providers/{provider}/keys` — list metadata only (never secret values).
- `POST /models/providers/{provider}/keys` — save a credential with a label and secret.
- `PATCH /models/providers/{provider}/keys/{key_id}` — update label or metadata; rotate the secret only when explicitly supplied.
- `DELETE /models/providers/{provider}/keys/{key_id}` — delete one credential.
- `PUT /models/pool` — extend route entries with an optional `key_id`.

The exact schema and migration strategy should be aligned with the engine's current encrypted credential store before implementation.

## Acceptance criteria

1. Multiple credentials can be saved for the same provider.
2. Each credential has a user-editable label.
3. A credential can be assigned to multiple models, and model assignments can be changed independently.
4. Secrets remain encrypted at rest and are never included in list responses or UI text.
5. Existing single-key configurations continue to work after upgrade.
6. Removing one credential does not remove other credentials for that provider.
7. Tests cover credential CRUD, route assignment, legacy migration, and secret redaction.

## Implementation plan

- Add a router regression test where the first credential for a provider/model fails with a credential-specific error and enters cooldown; verify that a second credential for the same provider/model is still attempted in the existing fallback order.
- Also verify that the cooled-down credential is skipped on the next attempt while the second credential remains eligible.

## Implementation note

This document records the proposed behavior only. It does not claim that multi-key storage or routing has been implemented.
