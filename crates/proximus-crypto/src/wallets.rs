//! Offline derivation only. No RPC, signing, or transaction handling.
use bip39::{Language, Mnemonic};
use bitcoin::{
    bip32::{DerivationPath, Xpriv},
    hashes::{sha512, Hash, HashEngine, Hmac, HmacEngine},
    secp256k1::Secp256k1,
    Address, CompressedPublicKey, Network, PrivateKey,
};
use curve25519_dalek::scalar::Scalar;
use monero::{
    cryptonote::hash::Hash as Keccak,
    util::{
        address::Address as MoneroAddress,
        key::{PrivateKey as MoneroPrivate, PublicKey as MoneroPublic},
    },
};
use serde::Serialize;
use std::{ptr, slice, str::FromStr};
use zeroize::{Zeroize, Zeroizing};

#[derive(Serialize, Zeroize)]
#[serde(rename_all = "camelCase")]
struct Wallet {
    address: String,
    public_key: String,
    derivation_path: String,
    recovery: String,
    private_key: String,
    secondary_private_key: String,
}
impl Drop for Wallet {
    fn drop(&mut self) {
        self.zeroize();
    }
}

fn mnemonic() -> Result<Mnemonic, ()> {
    let mut entropy = Zeroizing::new([0u8; 32]);
    getrandom::getrandom(&mut *entropy).map_err(|_| ())?;
    Mnemonic::from_entropy(&*entropy).map_err(|_| ())
}
fn hmac(key: &[u8], data: &[u8]) -> Zeroizing<[u8; 64]> {
    let mut engine = HmacEngine::<sha512::Hash>::new(key);
    engine.input(data);
    Zeroizing::new(Hmac::<sha512::Hash>::from_engine(engine).to_byte_array())
}
fn ed25519_child(seed: &[u8], path: &[u32]) -> Result<Zeroizing<[u8; 32]>, ()> {
    let mut node = hmac(b"ed25519 seed", seed);
    for index in path {
        if *index >= 0x8000_0000 {
            return Err(());
        }
        let mut input = Zeroizing::new([0u8; 37]);
        input[1..33].copy_from_slice(&node[..32]);
        input[33..].copy_from_slice(&(index | 0x8000_0000).to_be_bytes());
        node = hmac(&node[32..], &*input);
    }
    let mut key = Zeroizing::new([0u8; 32]);
    key.copy_from_slice(&node[..32]);
    Ok(key)
}
fn checksum_address(bytes: &[u8]) -> String {
    let lower = hex::encode(bytes);
    let digest = Keccak::new(lower.as_bytes()).to_bytes();
    let mut result = String::from("0x");
    for (i, c) in lower.chars().enumerate() {
        let nibble = if i % 2 == 0 {
            digest[i / 2] >> 4
        } else {
            digest[i / 2] & 15
        };
        result.push(if nibble >= 8 {
            c.to_ascii_uppercase()
        } else {
            c
        });
    }
    result
}
fn wallet(network: u32, recovery: &str) -> Result<Wallet, ()> {
    if !(1..=4).contains(&network) {
        return Err(());
    }
    if network == 4 {
        let mut scalar = if recovery.is_empty() {
            let mut random = Zeroizing::new([0u8; 64]);
            getrandom::getrandom(&mut *random).map_err(|_| ())?;
            Scalar::from_bytes_mod_order_wide(&random)
        } else {
            let mut bytes = Zeroizing::new([0u8; 32]);
            hex::decode_to_slice(recovery, &mut *bytes).map_err(|_| ())?;
            Option::<Scalar>::from(Scalar::from_canonical_bytes(*bytes)).ok_or(())?
        };
        if scalar == Scalar::ZERO {
            scalar.zeroize();
            return Err(());
        }
        let mut spend = MoneroPrivate::from_scalar(scalar);
        scalar.zeroize();
        let mut view = Keccak::hash_to_scalar(spend.as_bytes());
        let public_spend = MoneroPublic::from_private_key(&spend);
        let public_view = MoneroPublic::from_private_key(&view);
        let result = Wallet {
            address: MoneroAddress::standard(monero::Network::Mainnet, public_spend, public_view)
                .to_string(),
            public_key: format!("{} / {}", public_spend, public_view),
            derivation_path: "Monero deterministic spend/view keys".into(),
            recovery: hex::encode(spend.as_bytes()),
            private_key: hex::encode(spend.as_bytes()),
            secondary_private_key: hex::encode(view.as_bytes()),
        };
        spend.scalar.zeroize();
        view.scalar.zeroize();
        return Ok(result);
    }
    let words = if recovery.is_empty() {
        mnemonic()?
    } else {
        Mnemonic::parse_in(Language::English, recovery).map_err(|_| ())?
    };
    let seed = Zeroizing::new(words.to_seed(""));
    let mut result = Wallet {
        address: String::new(),
        public_key: String::new(),
        derivation_path: String::new(),
        recovery: words.to_string(),
        private_key: String::new(),
        secondary_private_key: String::new(),
    };
    if network == 1 {
        result.derivation_path = "m/44'/501'/0'/0'".into();
        let key = ed25519_child(&*seed, &[44, 501, 0, 0])?;
        let signing = ed25519_dalek::SigningKey::from_bytes(&key);
        result.public_key = bs58::encode(signing.verifying_key().as_bytes()).into_string();
        result.address = result.public_key.clone();
        let pair = Zeroizing::new(signing.to_keypair_bytes());
        result.private_key = bs58::encode(&*pair).into_string();
    } else {
        result.derivation_path = if network == 2 {
            "m/44'/60'/0'/0/0"
        } else {
            "m/84'/0'/0'/0/0"
        }
        .into();
        let mut secp = Secp256k1::new();
        let mut blinding = Zeroizing::new([0u8; 32]);
        getrandom::getrandom(&mut *blinding).map_err(|_| ())?;
        secp.seeded_randomize(&blinding);
        let path = DerivationPath::from_str(&result.derivation_path).map_err(|_| ())?;
        let mut root = Xpriv::new_master(Network::Bitcoin, &*seed).map_err(|_| ())?;
        let child = root.derive_priv(&secp, &path);
        root.private_key.non_secure_erase();
        let mut child = child.map_err(|_| ())?;
        let public = child.private_key.public_key(&secp);
        if network == 2 {
            let public_bytes = public.serialize_uncompressed();
            result.public_key = hex::encode(public_bytes);
            let digest = Keccak::new(&public_bytes[1..]).to_bytes();
            result.address = checksum_address(&digest[12..]);
            let bytes = Zeroizing::new(child.private_key.secret_bytes());
            result.private_key = hex::encode(bytes.as_slice());
        } else {
            result.public_key = hex::encode(public.serialize());
            result.address =
                Address::p2wpkh(&CompressedPublicKey(public), Network::Bitcoin).to_string();
            let mut private = PrivateKey::new(child.private_key, Network::Bitcoin);
            result.private_key = private.to_wif();
            private.inner.non_secure_erase();
        }
        child.private_key.non_secure_erase();
    }
    Ok(result)
}
unsafe fn write_output(value: &[u8], out: *mut u8, capacity: usize, length: *mut usize) -> i32 {
    if value.len() > capacity {
        return 1;
    }
    unsafe {
        ptr::copy_nonoverlapping(value.as_ptr(), out, value.len());
        *length = value.len();
    }
    0
}
/// # Safety
/// `out` is a disjoint writable capacity-byte buffer, `length` a writable usize.
#[no_mangle]
pub unsafe extern "C" fn px_mnemonic(out: *mut u8, capacity: usize, length: *mut usize) -> i32 {
    if length.is_null() {
        return 1;
    }
    unsafe {
        *length = 0;
    }
    if out.is_null() || capacity == 0 || capacity > 8192 {
        return 1;
    }
    unsafe { slice::from_raw_parts_mut(out, capacity) }.zeroize();
    match mnemonic() {
        Ok(words) => {
            let text = Zeroizing::new(words.to_string());
            unsafe { write_output(text.as_bytes(), out, capacity, length) }
        }
        Err(_) => 2,
    }
}
/// # Safety
/// All buffers must be valid and disjoint. Input may be null only when input_len is zero.
#[no_mangle]
pub unsafe extern "C" fn px_wallet(
    network: u32,
    input: *const u8,
    input_len: usize,
    out: *mut u8,
    capacity: usize,
    length: *mut usize,
) -> i32 {
    if length.is_null() {
        return 1;
    }
    unsafe {
        *length = 0;
    }
    if out.is_null() || capacity == 0 || capacity > 8192 {
        return 1;
    }
    unsafe { slice::from_raw_parts_mut(out, capacity) }.zeroize();
    if input_len > 1024 || (input.is_null() && input_len != 0) {
        return 1;
    }
    let bytes = if input_len == 0 {
        &[][..]
    } else {
        unsafe { slice::from_raw_parts(input, input_len) }
    };
    let input = match std::str::from_utf8(bytes) {
        Ok(v) => v,
        Err(_) => return 1,
    };
    match wallet(network, input)
        .and_then(|w| serde_json::to_vec(&w).map(Zeroizing::new).map_err(|_| ()))
    {
        Ok(json) => unsafe { write_output(&json, out, capacity, length) },
        Err(_) => 3,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const WORDS: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    #[test]
    fn bip39_and_bip84_vectors() {
        assert_eq!(
            Mnemonic::from_entropy(&[0u8; 16]).unwrap().to_string(),
            WORDS
        );
        let btc = wallet(3, WORDS).unwrap();
        assert_eq!(btc.address, "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu");
        assert_eq!(
            btc.private_key,
            "KyZpNDKnfs94vbrwhJneDi77V6jF64PWPF8x5cdJb8ifgg2DUc9d"
        );
        assert!(wallet(3, "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon").is_err());
    }
    #[test]
    fn slip10_vector() {
        let seed = hex::decode("000102030405060708090a0b0c0d0e0f").unwrap();
        assert_eq!(
            hex::encode(ed25519_child(&seed, &[]).unwrap().as_slice()),
            "2b4be7f19ee27bbf30c667b642d5f4aa69fd169872f8fc3059c08ebae2eb19e7"
        );
        assert_eq!(
            hex::encode(ed25519_child(&seed, &[0]).unwrap().as_slice()),
            "68e0fe46dfb67e368c75379acec591dad19df3cde26e63b93a8e704f1dade7a3"
        );
        let key = ed25519_child(&seed, &[0]).unwrap();
        assert_eq!(
            hex::encode(
                ed25519_dalek::SigningKey::from_bytes(&key)
                    .verifying_key()
                    .as_bytes()
            ),
            "8c8a13df77a28f3445213a0f432fde644acaa215fc72dcdf300d5efaa85d350c"
        );
    }
    #[test]
    fn ethereum_vectors() {
        for address in [
            "0x52908400098527886E0F7030069857D2E4169EE7",
            "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
            "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
        ] {
            assert_eq!(
                checksum_address(&hex::decode(&address[2..]).unwrap()),
                address
            );
        }
        let evm = wallet(
            2,
            "test test test test test test test test test test test junk",
        )
        .unwrap();
        assert_eq!(evm.address, "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266");
    }
    #[test]
    fn monero_reference_vector() {
        // Published spendkey recovery example: github.com/moneroexamples/spendkey
        let restored = wallet(
            4,
            "af6082af29108abda69cc385dfed2102b892a871695367cb22a4b9b6df8b3206",
        )
        .unwrap();
        assert_eq!(
            restored.secondary_private_key,
            "157874dc4e2961c872f87aaf4346146d0f596e2f116a51fbac01b693a8e3020a"
        );
        assert_eq!(restored.address, "46HSxE7KoiDaxWFWR1wmJfcrunNj4TLiPJqiCJkQn345A4JJzgBNhUvbkrYWJX4EVJZS4kJGfGj7CTW8GEUHsbEZCEupMt6");
    }
    #[test]
    fn recovery_and_network_separation() {
        for network in 1..=4 {
            let generated = wallet(network, "").unwrap();
            let restored = wallet(network, &generated.recovery).unwrap();
            assert_eq!(generated.address, restored.address);
            assert_eq!(generated.private_key, restored.private_key);
            assert_eq!(
                generated.secondary_private_key,
                restored.secondary_private_key
            );
            if network == 4 {
                assert_eq!(generated.address.len(), 95);
                assert!(MoneroAddress::from_str(&generated.address).is_ok());
            } else {
                assert_eq!(generated.recovery.split_whitespace().count(), 24);
            }
        }
        assert_ne!(
            wallet(1, WORDS).unwrap().private_key,
            wallet(2, WORDS).unwrap().private_key
        );
        assert!(wallet(4, &"00".repeat(32)).is_err());
        assert!(wallet(4, &"ff".repeat(32)).is_err());
        assert!(wallet(5, "").is_err());
    }
    #[test]
    fn ffi_rejects_and_clears_output() {
        let mut out = [0xa5u8; 4096];
        let mut len = 99;
        unsafe {
            assert_ne!(
                px_wallet(0, ptr::null(), 0, out.as_mut_ptr(), out.len(), &mut len),
                0
            );
            assert_eq!(len, 0);
            assert!(out.iter().all(|b| *b == 0));
            assert_eq!(
                px_wallet(1, ptr::null(), 0, out.as_mut_ptr(), out.len(), &mut len),
                0
            );
        }
        assert!(len > 0 && len < out.len());
    }
}
