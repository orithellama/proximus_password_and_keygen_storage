//! Restricted native-coin transfers. No arbitrary contract calldata or opaque signing.
use bitcoin::{
    absolute, consensus,
    hashes::Hash,
    secp256k1::{Message, Secp256k1},
    sighash::{EcdsaSighashType, SighashCache},
    transaction, Address, Amount, CompressedPublicKey, Network, OutPoint, PrivateKey, ScriptBuf,
    Sequence, Transaction, TxIn, TxOut, Witness,
};
use ed25519_dalek::Signer;
use monero::cryptonote::hash::Hash as Keccak;
use serde::{Deserialize, Serialize};
use std::{ptr, slice, str::FromStr};
use zeroize::{Zeroize, Zeroizing};

const LIMIT: usize = 2 * 1024 * 1024;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Prevout {
    transaction: String,
    vout: u32,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    action: String,
    network: u32,
    from: String,
    to: String,
    amount: String,
    #[serde(default)]
    chain_id: u64,
    #[serde(default)]
    nonce: u64,
    #[serde(default)]
    gas_price: String,
    #[serde(default)]
    gas_limit: u64,
    #[serde(default)]
    blockhash: String,
    #[serde(default)]
    fee_rate: u64,
    #[serde(default)]
    prevouts: Vec<Prevout>,
    #[serde(default)]
    private_key: String,
}
impl Drop for Request {
    fn drop(&mut self) {
        self.private_key.zeroize();
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Prepared {
    unsigned: String,
    fee: String,
    signed: String,
    transaction_id: String,
    inputs: Vec<InputReference>,
}

#[derive(Serialize)]
struct InputReference {
    txid: String,
    vout: u32,
}

fn amount(s: &str) -> Result<u128, ()> {
    if s.is_empty()
        || s.len() > 39
        || !s.bytes().all(|b| b.is_ascii_digit())
        || (s.len() > 1 && s.starts_with('0'))
    {
        return Err(());
    }
    s.parse().map_err(|_| ())
}
fn eth_address(s: &str) -> Result<Vec<u8>, ()> {
    let raw = s.strip_prefix("0x").ok_or(())?;
    if raw.len() != 40 {
        return Err(());
    }
    let data = hex::decode(raw).map_err(|_| ())?;
    if raw.chars().any(|c| c.is_ascii_lowercase())
        && raw.chars().any(|c| c.is_ascii_uppercase())
        && crate::wallets::checksum_address(&data) != s
    {
        return Err(());
    }
    Ok(data)
}
fn base58_32(s: &str) -> Result<[u8; 32], ()> {
    bs58::decode(s)
        .into_vec()
        .map_err(|_| ())?
        .try_into()
        .map_err(|_| ())
}

fn solana(r: &Request, sign: bool) -> Result<Prepared, ()> {
    let from = base58_32(&r.from)?;
    let to = base58_32(&r.to)?;
    let value = u64::try_from(amount(&r.amount)?).map_err(|_| ())?;
    if value == 0 || from == to || from == [0; 32] || to == [0; 32] {
        return Err(());
    }
    let hash = base58_32(&r.blockhash)?;
    // Legacy message: one signer, two writable accounts, System Program, one transfer.
    let mut message = vec![1, 0, 1, 3];
    message.extend(from);
    message.extend(to);
    message.extend([0; 32]);
    message.extend(hash);
    message.extend([1, 2, 2, 0, 1, 12]);
    message.extend(2u32.to_le_bytes());
    message.extend(value.to_le_bytes());
    let mut result = Prepared {
        unsigned: hex::encode(&message),
        fee: "0".into(),
        signed: String::new(),
        transaction_id: String::new(),
        inputs: vec![],
    };
    if sign {
        let mut key = Zeroizing::new([0u8; 64]);
        if bs58::decode(&r.private_key)
            .onto(&mut key[..])
            .map_err(|_| ())?
            != 64
        {
            return Err(());
        }
        let signer = ed25519_dalek::SigningKey::from_keypair_bytes(&key).map_err(|_| ())?;
        if signer.verifying_key().to_bytes() != from {
            return Err(());
        }
        let signature = signer.sign(&message).to_bytes();
        let mut wire = vec![1];
        wire.extend(signature);
        wire.extend(message);
        result.signed = hex::encode(wire);
        result.transaction_id = bs58::encode(signature).into_string();
    }
    Ok(result)
}

fn be(v: u128) -> Vec<u8> {
    let bytes = v.to_be_bytes();
    bytes[bytes.iter().position(|b| *b != 0).unwrap_or(16)..].to_vec()
}
fn rlp_payload(bytes: &[u8], list: bool) -> Vec<u8> {
    if !list && bytes.len() == 1 && bytes[0] < 128 {
        return bytes.to_vec();
    }
    let base = if list { 192 } else { 128 };
    let mut out = if bytes.len() < 56 {
        vec![base + bytes.len() as u8]
    } else {
        let len = be(bytes.len() as u128);
        let mut v = vec![base + 55 + len.len() as u8];
        v.extend(len);
        v
    };
    out.extend(bytes);
    out
}
fn rlp(fields: &[Vec<u8>]) -> Vec<u8> {
    rlp_payload(
        &fields
            .iter()
            .flat_map(|b| rlp_payload(b, false))
            .collect::<Vec<_>>(),
        true,
    )
}
fn evm(r: &Request, sign: bool) -> Result<Prepared, ()> {
    let from = eth_address(&r.from)?;
    let to = eth_address(&r.to)?;
    let value = amount(&r.amount)?;
    let price = amount(&r.gas_price)?;
    if value == 0
        || price == 0
        || r.chain_id == 0
        || !(21_000..=1_000_000).contains(&r.gas_limit)
        || to == [0; 20]
    {
        return Err(());
    }
    let fee = price.checked_mul(r.gas_limit as u128).ok_or(())?;
    let mut fields = vec![
        be(r.nonce as u128),
        be(price),
        be(r.gas_limit as u128),
        to,
        be(value),
        vec![],
        be(r.chain_id as u128),
        vec![],
        vec![],
    ];
    let unsigned = rlp(&fields);
    let mut result = Prepared {
        unsigned: hex::encode(&unsigned),
        fee: fee.to_string(),
        signed: String::new(),
        transaction_id: String::new(),
        inputs: vec![],
    };
    if sign {
        let mut bytes = Zeroizing::new([0u8; 32]);
        hex::decode_to_slice(&r.private_key, &mut bytes[..]).map_err(|_| ())?;
        let mut key = bitcoin::secp256k1::SecretKey::from_slice(&bytes[..]).map_err(|_| ())?;
        let result_inner = (|| {
            let mut secp = Secp256k1::new();
            let mut random = Zeroizing::new([0u8; 32]);
            getrandom::getrandom(&mut random[..]).map_err(|_| ())?;
            secp.seeded_randomize(&random);
            let public = key.public_key(&secp).serialize_uncompressed();
            if Keccak::new(&public[1..]).to_bytes()[12..] != from {
                return Err(());
            }
            let message = Message::from_digest(Keccak::new(&unsigned).to_bytes());
            let (recovery, signature) = secp
                .sign_ecdsa_recoverable(&message, &key)
                .serialize_compact();
            if recovery.to_i32() > 1 {
                return Err(());
            }
            fields[6] = be(r.chain_id as u128 * 2 + 35 + recovery.to_i32() as u128);
            fields[7] = trim_integer(&signature[..32]);
            fields[8] = trim_integer(&signature[32..]);
            let wire = rlp(&fields);
            result.transaction_id = "0x".to_owned() + &hex::encode(Keccak::new(&wire).to_bytes());
            result.signed = hex::encode(wire);
            Ok(())
        })();
        key.non_secure_erase();
        result_inner?;
    }
    Ok(result)
}
fn trim_integer(bytes: &[u8]) -> Vec<u8> {
    bytes[bytes.iter().position(|b| *b != 0).unwrap_or(bytes.len())..].to_vec()
}

fn bitcoin(r: &Request, sign: bool) -> Result<Prepared, ()> {
    let from = Address::from_str(&r.from)
        .map_err(|_| ())?
        .require_network(Network::Bitcoin)
        .map_err(|_| ())?;
    let to = Address::from_str(&r.to)
        .map_err(|_| ())?
        .require_network(Network::Bitcoin)
        .map_err(|_| ())?;
    if !from.script_pubkey().is_p2wpkh()
        || !(1..=32).contains(&r.prevouts.len())
        || !(1..=1_000).contains(&r.fee_rate)
    {
        return Err(());
    }
    let value = u64::try_from(amount(&r.amount)?).map_err(|_| ())?;
    if !(546..=2_100_000_000_000_000).contains(&value) {
        return Err(());
    }
    let mut selected = Vec::new();
    let mut total = 0u64;
    let mut seen = std::collections::HashSet::new();
    let output_bytes = 18 + from.script_pubkey().len() + to.script_pubkey().len();
    let mut fee = 0;
    for input in &r.prevouts {
        if input.transaction.len() > 800_000 {
            return Err(());
        }
        let previous: Transaction =
            consensus::deserialize(&hex::decode(&input.transaction).map_err(|_| ())?)
                .map_err(|_| ())?;
        let output = previous.output.get(input.vout as usize).ok_or(())?;
        let outpoint = OutPoint::new(previous.compute_txid(), input.vout);
        if output.script_pubkey != from.script_pubkey() || !seen.insert(outpoint) {
            return Err(());
        }
        total = total.checked_add(output.value.to_sat()).ok_or(())?;
        if total > 2_100_000_000_000_000 {
            return Err(());
        }
        selected.push((outpoint, output.value));
        // Conservative upper bound for native SegWit signatures and two outputs.
        fee = (12 + 70 * selected.len() as u64 + output_bytes as u64)
            .checked_mul(r.fee_rate)
            .ok_or(())?;
        if total >= value.checked_add(fee).ok_or(())? {
            break;
        }
    }
    let change = total
        .checked_sub(value.checked_add(fee).ok_or(())?)
        .ok_or(())?;
    let mut outputs = vec![TxOut {
        value: Amount::from_sat(value),
        script_pubkey: to.script_pubkey(),
    }];
    if change >= 546 {
        outputs.push(TxOut {
            value: Amount::from_sat(change),
            script_pubkey: from.script_pubkey(),
        });
    } else {
        fee = fee.checked_add(change).ok_or(())?;
    }
    let mut tx = Transaction {
        version: transaction::Version::TWO,
        lock_time: absolute::LockTime::ZERO,
        input: selected
            .iter()
            .map(|(previous_output, _)| TxIn {
                previous_output: *previous_output,
                script_sig: ScriptBuf::new(),
                sequence: Sequence::MAX,
                witness: Witness::new(),
            })
            .collect(),
        output: outputs,
    };
    let mut result = Prepared {
        unsigned: hex::encode(consensus::serialize(&tx)),
        fee: fee.to_string(),
        signed: String::new(),
        transaction_id: tx.compute_txid().to_string(),
        inputs: selected
            .iter()
            .map(|(point, _)| InputReference {
                txid: point.txid.to_string(),
                vout: point.vout,
            })
            .collect(),
    };
    if sign {
        let mut key = PrivateKey::from_wif(&r.private_key).map_err(|_| ())?;
        let result_inner = (|| {
            let mut secp = Secp256k1::new();
            let mut random = Zeroizing::new([0u8; 32]);
            getrandom::getrandom(&mut random[..]).map_err(|_| ())?;
            secp.seeded_randomize(&random);
            let public = CompressedPublicKey(key.inner.public_key(&secp));
            if Address::p2wpkh(&public, Network::Bitcoin) != from
                || !key.compressed
                || key.network != Network::Bitcoin.into()
            {
                return Err(());
            }
            let mut cache = SighashCache::new(&mut tx);
            for (i, (_, value)) in selected.iter().enumerate() {
                let hash = cache
                    .p2wpkh_signature_hash(i, &from.script_pubkey(), *value, EcdsaSighashType::All)
                    .map_err(|_| ())?;
                let signature = bitcoin::ecdsa::Signature::sighash_all(
                    secp.sign_ecdsa(&Message::from_digest(hash.to_byte_array()), &key.inner),
                );
                *cache.witness_mut(i).ok_or(())? = Witness::p2wpkh(&signature, &public.0);
            }
            result.signed = hex::encode(consensus::serialize(&tx));
            Ok(())
        })();
        key.inner.non_secure_erase();
        result_inner?;
    }
    Ok(result)
}

fn process(r: &Request) -> Result<Prepared, ()> {
    let sign = match r.action.as_str() {
        "prepare" => false,
        "sign" => true,
        _ => return Err(()),
    };
    if r.private_key.len() > 256 || r.from.len() > 128 || r.to.len() > 128 || r.blockhash.len() > 64
    {
        return Err(());
    }
    match r.network {
        1 => solana(r, sign),
        2 => evm(r, sign),
        3 => bitcoin(r, sign),
        _ => Err(()),
    }
}

/// # Safety
/// All buffers must be valid and disjoint. Input and output are bounded by LIMIT.
#[no_mangle]
pub unsafe extern "C" fn px_transaction(
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
    if out.is_null() || capacity == 0 || capacity > LIMIT {
        return 1;
    }
    unsafe { slice::from_raw_parts_mut(out, capacity) }.zeroize();
    if input.is_null() || input_len == 0 || input_len > LIMIT {
        return 1;
    }
    let result =
        serde_json::from_slice::<Request>(unsafe { slice::from_raw_parts(input, input_len) })
            .map_err(|_| ())
            .and_then(|r| process(&r))
            .and_then(|v| serde_json::to_vec(&v).map_err(|_| ()));
    match result {
        Ok(bytes) if bytes.len() <= capacity => {
            unsafe {
                ptr::copy_nonoverlapping(bytes.as_ptr(), out, bytes.len());
                *length = bytes.len();
            }
            0
        }
        _ => 2,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request(network: u32) -> Request {
        serde_json::from_value(serde_json::json!({"action":"prepare","network":network,"from":"","to":"","amount":"1"})).unwrap()
    }
    #[test]
    fn eip155_reference_vector() {
        let mut r = request(2);
        r.action = "sign".into();
        r.from = "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F".into();
        r.to = "0x3535353535353535353535353535353535353535".into();
        r.amount = "1000000000000000000".into();
        r.gas_price = "20000000000".into();
        r.gas_limit = 21000;
        r.chain_id = 1;
        r.nonce = 9;
        r.private_key = "46".repeat(32);
        let p = process(&r).unwrap();
        assert_eq!(p.unsigned, "ec098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a764000080018080");
        assert_eq!(p.signed, "f86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83");
        assert_eq!(p.fee, "420000000000000");
        r.chain_id = 0;
        assert!(process(&r).is_err());
        r.chain_id = 1;
        r.to = "0x353535353535353535353535353535353535353".into();
        assert!(process(&r).is_err());
    }
    #[test]
    fn solana_wire_signature_and_recipient_are_bound() {
        let key = ed25519_dalek::SigningKey::from_bytes(&[7; 32]);
        let mut r = request(1);
        r.from = bs58::encode(key.verifying_key().as_bytes()).into_string();
        r.to = bs58::encode([8; 32]).into_string();
        r.blockhash = bs58::encode([9; 32]).into_string();
        r.amount = "1000".into();
        r.private_key = bs58::encode(key.to_keypair_bytes()).into_string();
        r.action = "sign".into();
        let p = process(&r).unwrap();
        let wire = hex::decode(p.signed).unwrap();
        assert_eq!(wire.len(), 215);
        assert_eq!(&wire[65..], &hex::decode(p.unsigned).unwrap());
        key.verifying_key()
            .verify_strict(
                &wire[65..],
                &ed25519_dalek::Signature::from_slice(&wire[1..65]).unwrap(),
            )
            .unwrap();
        r.from = r.to.clone();
        assert!(process(&r).is_err());
    }
    #[test]
    fn bitcoin_verifies_prevouts_fee_and_signature() {
        let secp = Secp256k1::new();
        let key = PrivateKey::new(
            bitcoin::secp256k1::SecretKey::from_slice(&[7; 32]).unwrap(),
            Network::Bitcoin,
        );
        let public = CompressedPublicKey(key.inner.public_key(&secp));
        let address = Address::p2wpkh(&public, Network::Bitcoin);
        let prev = Transaction {
            version: transaction::Version::TWO,
            lock_time: absolute::LockTime::ZERO,
            input: vec![],
            output: vec![TxOut {
                value: Amount::from_sat(100_000),
                script_pubkey: address.script_pubkey(),
            }],
        };
        let mut r = request(3);
        r.from = address.to_string();
        r.to = "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu".into();
        r.amount = "50000".into();
        r.fee_rate = 2;
        r.prevouts.push(Prevout {
            transaction: hex::encode(consensus::serialize(&prev)),
            vout: 0,
        });
        r.action = "sign".into();
        r.private_key = key.to_wif();
        let p = process(&r).unwrap();
        let tx: Transaction = consensus::deserialize(&hex::decode(p.signed).unwrap()).unwrap();
        assert_eq!(tx.input[0].previous_output.txid, prev.compute_txid());
        assert_eq!(tx.output[0].value.to_sat(), 50_000);
        assert_eq!(
            100_000 - tx.output.iter().map(|o| o.value.to_sat()).sum::<u64>(),
            p.fee.parse::<u64>().unwrap()
        );
        let hash = SighashCache::new(&tx)
            .p2wpkh_signature_hash(
                0,
                &address.script_pubkey(),
                Amount::from_sat(100_000),
                EcdsaSighashType::All,
            )
            .unwrap();
        let signature =
            bitcoin::ecdsa::Signature::from_slice(tx.input[0].witness.iter().next().unwrap())
                .unwrap();
        secp.verify_ecdsa(
            &Message::from_digest(hash.to_byte_array()),
            &signature.signature,
            &public.0,
        )
        .unwrap();
        r.prevouts[0].vout = 1;
        assert!(process(&r).is_err());
    }

    #[test]
    fn transaction_ffi_rejects_malformed_requests_and_clears_output() {
        let requests: &[&[u8]] = &[
            b"{}",
            b"{\"action\":\"sign\",\"network\":4,\"from\":\"x\",\"to\":\"y\",\"amount\":\"1\"}",
            b"{\"action\":\"prepare\",\"network\":2,\"from\":\"x\",\"to\":\"y\",\"amount\":\"1\",\"data\":\"unreviewed calldata\"}",
            &[0xff, 0xfe],
        ];
        for request in requests {
            let mut output = [0x55; 512];
            let mut length = 99;
            let status = unsafe {
                px_transaction(
                    request.as_ptr(),
                    request.len(),
                    output.as_mut_ptr(),
                    output.len(),
                    &mut length,
                )
            };
            assert_ne!(status, 0);
            assert_eq!(length, 0);
            assert!(output.iter().all(|b| *b == 0));
        }
        for invalid in [
            "",
            "01",
            "-1",
            "1e18",
            "340282366920938463463374607431768211456",
        ] {
            assert!(amount(invalid).is_err());
        }
    }

    #[test]
    fn evm_rejects_wrong_signer_bad_checksum_and_fee_overflow() {
        let mut r = request(2);
        r.from = "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F".into();
        r.to = "0x3535353535353535353535353535353535353535".into();
        r.gas_price = "20000000000".into();
        r.gas_limit = 21000;
        r.chain_id = 1;
        r.action = "sign".into();
        r.private_key = "47".repeat(32);
        assert!(process(&r).is_err());
        r.private_key = "46".repeat(32);
        assert!(process(&r).is_ok());
        r.to = "0x9D8A62f656a8d1615C1294fd71e9CFb3E4855A4F".into();
        assert!(process(&r).is_err());
        r.to = "0x3535353535353535353535353535353535353535".into();
        r.gas_price = u128::MAX.to_string();
        assert!(process(&r).is_err());
        r.gas_price = "1".into();
        r.gas_limit = 20999;
        assert!(process(&r).is_err());
    }
}
