//! Small C boundary. Every unsafe operation is limited to a caller-owned buffer.
//! The Apple wrapper checks buffer sizes before crossing this boundary.
use aes_gcm::{
    aead::{Aead, Payload},
    Aes256Gcm, KeyInit, Nonce,
};
use argon2::{Algorithm, Argon2, Params, Version};
use std::{ptr, slice};
use zeroize::{Zeroize, Zeroizing};

const MAX_PAYLOAD: usize = 8 * 1024 * 1024;
const OVERHEAD: usize = 12 + 16;

fn derive(password: &[u8], recovery: &[u8], salt: &[u8]) -> Result<Zeroizing<[u8; 32]>, ()> {
    if password.len() < 12 || password.len() > 1024 || recovery.len() != 32 || salt.len() != 16 {
        return Err(());
    }
    // Fixed, versioned profile. Untrusted files cannot request weaker or unbounded KDF work.
    let params = Params::new(65536, 3, 1, Some(32)).map_err(|_| ())?;
    let kdf = Argon2::new_with_secret(recovery, Algorithm::Argon2id, Version::V0x13, params)
        .map_err(|_| ())?;
    let mut key = Zeroizing::new([0u8; 32]);
    kdf.hash_password_into(password, salt, &mut *key)
        .map_err(|_| ())?;
    Ok(key)
}

fn seal(key: &[u8], plain: &[u8], aad: &[u8]) -> Result<Zeroizing<Vec<u8>>, ()> {
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| ())?;
    let mut nonce = [0u8; 12];
    getrandom::getrandom(&mut nonce).map_err(|_| ())?;
    let encrypted = cipher
        .encrypt(Nonce::from_slice(&nonce), Payload { msg: plain, aad })
        .map_err(|_| ())?;
    let mut result = Zeroizing::new(Vec::with_capacity(plain.len() + OVERHEAD));
    result.extend_from_slice(&nonce);
    result.extend_from_slice(&encrypted);
    Ok(result)
}

fn open(key: &[u8], sealed: &[u8], aad: &[u8]) -> Result<Zeroizing<Vec<u8>>, ()> {
    if sealed.len() < OVERHEAD {
        return Err(());
    }
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| ())?;
    cipher
        .decrypt(
            Nonce::from_slice(&sealed[..12]),
            Payload {
                msg: &sealed[12..],
                aad,
            },
        )
        .map(Zeroizing::new)
        .map_err(|_| ())
}

/// # Safety
/// `out` must point to `len` writable bytes, with no overlapping aliases.
#[no_mangle]
pub unsafe extern "C" fn px_random(out: *mut u8, len: usize) -> i32 {
    if out.is_null() || len == 0 || len > MAX_PAYLOAD {
        return 1;
    }
    match getrandom::getrandom(unsafe { slice::from_raw_parts_mut(out, len) }) {
        Ok(_) => 0,
        Err(_) => 2,
    }
}

/// # Safety
/// Input lengths must be valid. Recovery, salt and output need 32, 16 and 32 bytes respectively.
#[no_mangle]
pub unsafe extern "C" fn px_derive_key(
    password: *const u8,
    password_len: usize,
    recovery: *const u8,
    salt: *const u8,
    out: *mut u8,
) -> i32 {
    if password.is_null()
        || recovery.is_null()
        || salt.is_null()
        || out.is_null()
        || !(12..=1024).contains(&password_len)
    {
        return 1;
    }
    let result = derive(
        unsafe { slice::from_raw_parts(password, password_len) },
        unsafe { slice::from_raw_parts(recovery, 32) },
        unsafe { slice::from_raw_parts(salt, 16) },
    );
    match result {
        Ok(key) => {
            unsafe {
                ptr::copy_nonoverlapping(key.as_ptr(), out, 32);
            }
            0
        }
        Err(_) => 2,
    }
}

/// # Safety
/// Key needs 32 bytes. Output needs plain_len + 28 bytes. All buffers must be disjoint and valid.
#[no_mangle]
pub unsafe extern "C" fn px_seal(
    key: *const u8,
    plain: *const u8,
    plain_len: usize,
    aad: *const u8,
    aad_len: usize,
    out: *mut u8,
) -> i32 {
    if key.is_null()
        || plain.is_null()
        || aad.is_null()
        || out.is_null()
        || plain_len > MAX_PAYLOAD
        || aad_len > 4096
    {
        return 1;
    }
    let result = seal(
        unsafe { slice::from_raw_parts(key, 32) },
        unsafe { slice::from_raw_parts(plain, plain_len) },
        unsafe { slice::from_raw_parts(aad, aad_len) },
    );
    match result {
        Ok(data) => {
            unsafe {
                ptr::copy_nonoverlapping(data.as_ptr(), out, data.len());
            }
            0
        }
        Err(_) => 2,
    }
}

/// # Safety
/// Key needs 32 bytes. Output needs sealed_len - 28 bytes. All buffers must be disjoint and valid.
#[no_mangle]
pub unsafe extern "C" fn px_open(
    key: *const u8,
    sealed: *const u8,
    sealed_len: usize,
    aad: *const u8,
    aad_len: usize,
    out: *mut u8,
) -> i32 {
    if key.is_null()
        || sealed.is_null()
        || aad.is_null()
        || out.is_null()
        || !(OVERHEAD..=MAX_PAYLOAD + OVERHEAD).contains(&sealed_len)
        || aad_len > 4096
    {
        return 1;
    }
    let result = open(
        unsafe { slice::from_raw_parts(key, 32) },
        unsafe { slice::from_raw_parts(sealed, sealed_len) },
        unsafe { slice::from_raw_parts(aad, aad_len) },
    );
    match result {
        Ok(data) => {
            unsafe {
                ptr::copy_nonoverlapping(data.as_ptr(), out, data.len());
            }
            0
        }
        Err(_) => 3,
    }
}

/// # Safety
/// `alphabet` needs alphabet_len bytes and `out` needs length bytes, without overlap.
#[no_mangle]
pub unsafe extern "C" fn px_generate_password(
    length: usize,
    alphabet: *const u8,
    alphabet_len: usize,
    out: *mut u8,
) -> i32 {
    if alphabet.is_null()
        || out.is_null()
        || !(12..=128).contains(&length)
        || !(2..=128).contains(&alphabet_len)
    {
        return 1;
    }
    let chars = unsafe { slice::from_raw_parts(alphabet, alphabet_len) };
    if chars.iter().any(|c| !c.is_ascii_graphic())
        || chars
            .iter()
            .enumerate()
            .any(|(i, c)| chars[..i].contains(c))
    {
        return 1;
    }
    let output = unsafe { slice::from_raw_parts_mut(out, length) };
    let limit = 256 - (256 % alphabet_len);
    for slot in output.iter_mut() {
        loop {
            let mut byte = [0u8; 1];
            if getrandom::getrandom(&mut byte).is_err() {
                output.zeroize();
                return 2;
            }
            if (byte[0] as usize) < limit {
                *slot = chars[byte[0] as usize % alphabet_len];
                break;
            }
        }
    }
    0
}

/// # Safety
/// `data` must point to len writable bytes.
#[no_mangle]
pub unsafe extern "C" fn px_zero(data: *mut u8, len: usize) {
    if !data.is_null() && len <= MAX_PAYLOAD {
        unsafe { slice::from_raw_parts_mut(data, len) }.zeroize();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn authenticated_encryption_rejects_changes() {
        let key = [7; 32];
        let aad = b"vault/record/revision";
        let sealed = seal(&key, b"private password", aad).unwrap();
        assert_eq!(&**open(&key, &sealed, aad).unwrap(), b"private password");
        assert!(open(&key, &sealed, b"different vault").is_err());
        assert!(open(&[8; 32], &sealed, aad).is_err());
        for i in 0..sealed.len() {
            let mut bad = sealed.to_vec();
            bad[i] ^= 1;
            assert!(open(&key, &bad, aad).is_err());
        }
        assert_ne!(&*sealed, &*seal(&key, b"private password", aad).unwrap());
    }
    #[test]
    fn nist_gcm_known_answer_vector() {
        let c = Aes256Gcm::new_from_slice(&[0; 32]).unwrap();
        let result = c
            .encrypt(Nonce::from_slice(&[0; 12]), &[0u8; 16][..])
            .unwrap();
        let expected = [
            0xce, 0xa7, 0x40, 0x3d, 0x4d, 0x60, 0x6b, 0x6e, 0x07, 0x4e, 0xc5, 0xd3, 0xba, 0xf3,
            0x9d, 0x18, 0xd0, 0xd1, 0xc8, 0xa7, 0x99, 0x99, 0x6b, 0xf0, 0x26, 0x5b, 0x98, 0xb5,
            0xd4, 0x8a, 0xb9, 0x19,
        ];
        assert_eq!(result, expected);
    }
    #[test]
    fn recovery_requires_both_factors() {
        let p = b"correctly generated long passphrase";
        let k = derive(p, &[1; 32], &[2; 16]).unwrap();
        assert_eq!(*k, *derive(p, &[1; 32], &[2; 16]).unwrap());
        assert_ne!(*k, *derive(p, &[3; 32], &[2; 16]).unwrap());
        assert_ne!(
            *k,
            *derive(b"different long passphrase", &[1; 32], &[2; 16]).unwrap()
        );
        assert!(derive(b"short", &[1; 32], &[2; 16]).is_err());
    }
    #[test]
    fn ffi_bounds_and_generator() {
        let mut output = [0u8; 24];
        unsafe {
            assert_ne!(px_random(ptr::null_mut(), 32), 0);
            assert_ne!(
                px_generate_password(24, b"aaa".as_ptr(), 3, output.as_mut_ptr()),
                0
            );
            assert_eq!(
                px_generate_password(24, b"abcdefgh0123456789".as_ptr(), 18, output.as_mut_ptr()),
                0
            );
        }
        assert!(output.iter().all(|c| b"abcdefgh0123456789".contains(c)));
    }
}
