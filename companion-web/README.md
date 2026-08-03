# Dayflow web materials

This directory is no longer a user-facing companion product.

- `workers/api/src/` is the encrypted account/device sync relay source.
- `apps/web/dist/` is a preserved compiled migration artifact and must not be
  reintroduced as the Dayflow product surface.

Native Dayflow clients own capture, timeline, journal, chat, account, and
device-management experiences. Keep new relay work opaque, account-scoped,
and free of plaintext timeline or journal state. See
[`docs/multi-device/MIGRATION_AND_DEPRECATION.md`](../docs/multi-device/MIGRATION_AND_DEPRECATION.md).
