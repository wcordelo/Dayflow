#ifndef DAYFLOW_CORE_H
#define DAYFLOW_CORE_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

char *dayflow_core_version(void);
bool dayflow_core_capture_allowed(bool permission_granted,
                                  bool user_paused,
                                  bool device_locked,
                                  bool sleeping,
                                  bool private_context,
                                  bool drm_content);
char *dayflow_core_logical_day_key(long long timestamp_unix,
                                   int timezone_offset_minutes,
                                   unsigned char boundary_hour);
char *dayflow_core_capture_decision_json(const char *context_json,
                                         const char *policy_json);
char *dayflow_core_project_json(const char *envelopes_json,
                                const unsigned char *root_key,
                                size_t root_key_len);
char *dayflow_core_project_keyring_json(const char *envelopes_json,
                                         const char *key_ring_json);
char *dayflow_core_rekey_envelopes_json(const char *envelopes_json,
                                        const char *source_key_ring_json,
                                        const char *destination_key_ring_json);
char *dayflow_core_seal_json(const char *payload_json,
                             const char *event_id,
                             const char *device_id,
                             unsigned long long logical_clock,
                             const unsigned char *root_key,
                             size_t root_key_len);
char *dayflow_core_seal_key_version_json(const char *payload_json,
                                         const char *event_id,
                                         const char *device_id,
                                         unsigned long long logical_clock,
                                         unsigned int key_version,
                                         const unsigned char *root_key,
                                         size_t root_key_len);
char *dayflow_core_wrap_account_key_json(const unsigned char *root_key,
                                         size_t root_key_len,
                                         const char *recipient_device_id,
                                         const unsigned char *recipient_public_key,
                                         size_t recipient_public_key_len);
char *dayflow_core_wrap_account_key_versioned_json(const unsigned char *root_key,
                                                   size_t root_key_len,
                                                   unsigned int key_version,
                                                   const char *recipient_device_id,
                                                   const unsigned char *recipient_public_key,
                                                   size_t recipient_public_key_len);
char *dayflow_core_unwrap_account_key_json(const char *wrapped_key_json,
                                           const unsigned char *private_key,
                                           size_t private_key_len);
char *dayflow_core_export_recovery_kit_json(const unsigned char *root_key,
                                            size_t root_key_len,
                                            const char *passphrase);
char *dayflow_core_restore_recovery_key_json(const char *kit_json,
                                             const char *passphrase);
char *dayflow_core_export_recovery_kit_keyring_json(const char *key_ring_json,
                                                    const char *passphrase);
char *dayflow_core_restore_recovery_keyring_json(const char *kit_json,
                                                 const char *passphrase);
char *dayflow_core_generate_device_keypair_json(void);
char *dayflow_core_generate_device_signing_keypair_json(void);
char *dayflow_core_generate_account_root_key_json(void);
char *dayflow_core_sign_request_json(const char *message,
                                     const unsigned char *private_key,
                                     size_t private_key_len);
char *dayflow_core_canonical_device_request_json(const char *method,
                                                 const char *path_with_query,
                                                 const unsigned char *body,
                                                 size_t body_len,
                                                 int64_t timestamp,
                                                 const char *nonce,
                                                 const char *device_id);
void dayflow_core_free_string(char *value);

#ifdef __cplusplus
}
#endif

#endif /* DAYFLOW_CORE_H */
