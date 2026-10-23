#ifndef PROXIMUS_CRYPTO_H
#define PROXIMUS_CRYPTO_H
#include <stddef.h>
#include <stdint.h>
// Return 0 on success. Caller owns all buffers. Output is unspecified on failure.
int32_t px_random(uint8_t *out, size_t len);
int32_t px_derive_key(const uint8_t *password, size_t password_len,
                      const uint8_t *recovery_secret, const uint8_t *salt,
                      uint8_t *out);
int32_t px_seal(const uint8_t *key, const uint8_t *plain, size_t plain_len,
                const uint8_t *aad, size_t aad_len, uint8_t *out);
int32_t px_open(const uint8_t *key, const uint8_t *sealed, size_t sealed_len,
                const uint8_t *aad, size_t aad_len, uint8_t *out);
int32_t px_generate_password(size_t length, const uint8_t *alphabet,
                            size_t alphabet_len, uint8_t *out);
void px_zero(uint8_t *data, size_t len);
#endif
