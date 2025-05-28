use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_ulonglong, c_uint, c_int};
use std::panic;
use std::ptr;
use std::str::FromStr;
use std::fs;
use std::path::PathBuf; // Path is unused
use std::env;

// Ethereum-specific types from ethers crate
use ethers::types::{Address, U256, Bytes as EthersBytes, TransactionRequest, Signature as EthersSignature}; // H256 unused
use ethers::signers::{LocalWallet, Signer};

// k256 for direct crypto operations if LocalWallet isn't used for all parts
use k256::ecdsa::SigningKey;
// generic_array is used by k256::SigningKey::from_bytes
use generic_array::{GenericArray, typenum::U32};

// Dependencies for secure key storage
use aes_gcm::{Aes256Gcm, Key, Nonce}; // Key and Nonce are re-exported GenericArray wrappers
use aes_gcm::aead::Aead; 
use aes_gcm::KeyInit; // Correct trait for Aes256Gcm::new()
use argon2::Argon2; 
// use argon2::password_hash::SaltString; // Not used for now, raw salt bytes are generated
use rand::rngs::OsRng; // For generating cryptographically secure random numbers (for nonce, salt)
use rand::RngCore; // Trait for Rngs like OsRng

use serde::{Serialize, Deserialize};

// For directory/file operations
use directories::ProjectDirs;
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64_STANDARD}; // For base64 operations

const KEY_STORE_DIR_NAME: &str = "cutepanel_secure_keys";
const MASTER_PASSWORD_ENV_VAR: &str = "CUTEPANEL_KEYSTORE_PASSWORD";
const AES_NONCE_SIZE: usize = 12; // 96 bits for AES-GCM
const ARGON2_SALT_SIZE: usize = 16; // 16 bytes for Argon2 salt

#[derive(Serialize, Deserialize)]
struct EncryptedKeyFile {
    salt: String, // base64 encoded salt for Argon2
    nonce: String, // base64 encoded nonce for AES-GCM
    ciphertext: String, // base64 encoded ciphertext
}

// --- Helper: Get key storage path ---
fn get_key_storage_path() -> Result<PathBuf, String> {
    if let Some(proj_dirs) = ProjectDirs::from("org", "CutePanel", "Signer") {
        let data_dir = proj_dirs.data_local_dir();
        let key_store_path = data_dir.join(KEY_STORE_DIR_NAME);
        if !key_store_path.exists() {
            fs::create_dir_all(&key_store_path)
                .map_err(|e| format!("Failed to create key store directory: {}", e))?;
        }
        Ok(key_store_path)
    } else {
        Err("Could not determine application data directory".to_string())
    }
}

// --- Helper: Derive encryption key using Argon2 ---
fn derive_encryption_key(password: &str, salt_bytes: &[u8]) -> Result<[u8; 32], String> {
    let argon2_params = argon2::Params::new(64 * 1024, 4, 2, Some(32)).unwrap(); // 64MB, 4 iter, 2 parallelism, 32 bytes output
    let argon2_context = Argon2::new(
        argon2::Algorithm::Argon2id,
        argon2::Version::V0x13,
        argon2_params,
    );
    let mut output_key_material = [0u8; 32];
    argon2_context.hash_password_into(password.as_bytes(), salt_bytes, &mut output_key_material)
        .map_err(|e| format!("Argon2 key derivation failed: {}", e))?;
    Ok(output_key_material)
}

// --- Helper: Encrypt PK and prepare for file storage ---
fn encrypt_pk_and_prepare_file_data(pk_bytes: &[u8; 32], master_password: &str) -> Result<EncryptedKeyFile, String> {
    // 1. Generate salt for Argon2
    let mut salt_bytes = [0u8; ARGON2_SALT_SIZE];
    OsRng.fill_bytes(&mut salt_bytes);

    // 2. Derive encryption key
    let encryption_key_bytes = derive_encryption_key(master_password, &salt_bytes)?;
    let cipher_key = Key::<Aes256Gcm>::from_slice(&encryption_key_bytes);
    let cipher = Aes256Gcm::new(cipher_key);

    // 3. Generate nonce for AES-GCM
    let mut nonce_bytes = [0u8; AES_NONCE_SIZE];
    OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);

    // 4. Encrypt private key
    let ciphertext = cipher.encrypt(nonce, pk_bytes.as_ref())
        .map_err(|e| format!("Encryption failed: {}", e))?;

    // 5. Prepare data for JSON serialization (base64 encode binary parts)
    Ok(EncryptedKeyFile {
        salt: BASE64_STANDARD.encode(&salt_bytes),
        nonce: BASE64_STANDARD.encode(&nonce_bytes),
        ciphertext: BASE64_STANDARD.encode(&ciphertext),
    })
}


// --- Helper: Load and decrypt private key ---
fn load_and_decrypt_pk(key_identifier: &str, master_password: &str) -> Result<[u8; 32], String> {
    let key_store_path = get_key_storage_path()?;
    let key_file_path = key_store_path.join(format!("{}.json", key_identifier));

    if !key_file_path.exists() {
        return Err(format!("Key file not found for identifier: {}", key_identifier));
    }

    let file_content = fs::read_to_string(key_file_path)
        .map_err(|e| format!("Failed to read key file: {}", e))?;
    
    let encrypted_data: EncryptedKeyFile = serde_json::from_str(&file_content)
        .map_err(|e| format!("Failed to parse key file JSON: {}", e))?;

    let salt_bytes = BASE64_STANDARD.decode(&encrypted_data.salt)
        .map_err(|e| format!("Failed to decode salt: {}", e))?;
    let nonce_bytes = BASE64_STANDARD.decode(&encrypted_data.nonce)
        .map_err(|e| format!("Failed to decode nonce: {}", e))?;
    let ciphertext_bytes = BASE64_STANDARD.decode(&encrypted_data.ciphertext)
        .map_err(|e| format!("Failed to decode ciphertext: {}", e))?;

    let encryption_key_bytes = derive_encryption_key(master_password, &salt_bytes)?;
    let cipher_key = Key::<Aes256Gcm>::from_slice(&encryption_key_bytes);
    let cipher = Aes256Gcm::new(cipher_key); 
    let nonce = Nonce::from_slice(&nonce_bytes); 

    let decrypted_pk_bytes = cipher.decrypt(nonce, ciphertext_bytes.as_ref())
        .map_err(|e| format!("Failed to decrypt private key: {}", e))?;

    if decrypted_pk_bytes.len() != 32 {
        return Err("Decrypted private key is not 32 bytes long".to_string());
    }
    let mut pk_array = [0u8; 32];
    pk_array.copy_from_slice(&decrypted_pk_bytes);
    Ok(pk_array)
}

// --- Helper function to convert C string to Rust String ---
fn c_str_to_string(c_str_ptr: *const c_char) -> Result<String, String> {
    if c_str_ptr.is_null() {
        return Err("Null pointer passed for C string".to_string());
    }
    unsafe {
        CStr::from_ptr(c_str_ptr)
            .to_str()
            .map_err(|e| format!("Invalid UTF-8 sequence in C string: {}", e))
            .map(String::from)
    }
}

// --- FFI Function Definition ---
#[no_mangle]
pub extern "C" fn sign_evm_transaction_ffi(
    key_identifier_cchar: *const c_char,
    to_cchar: *const c_char,
    value_wei_hex_cchar: *const c_char,
    data_hex_cchar: *const c_char,
    nonce_c: c_ulonglong,
    gas_price_wei_hex_cchar: *const c_char,
    gas_limit_c: c_ulonglong,
    chain_id_c: c_ulonglong,
    signed_tx_hex_out_ptr: *mut c_char,
    out_buffer_len_c: c_uint,
) -> c_int {
    let result = panic::catch_unwind(|| {
        let key_id = match c_str_to_string(key_identifier_cchar) {
            Ok(s) => s,
            Err(e) => { eprintln!("Error converting key_identifier: {}", e); return -4; }
        };

        let master_password = match env::var(MASTER_PASSWORD_ENV_VAR) {
            Ok(pass) => pass,
            Err(_) => { 
                eprintln!("Master password ENV var '{}' not set.", MASTER_PASSWORD_ENV_VAR);
                return -1; 
            }
        };

        let pk_bytes_array = match load_and_decrypt_pk(&key_id, &master_password) {
            Ok(pk) => pk,
            Err(e) => {
                eprintln!("Failed to load/decrypt private key for '{}': {}", key_id, e);
                return -1; 
            }
        };
        
        let signing_key_k256 = match SigningKey::from_bytes(GenericArray::<u8, U32>::from_slice(&pk_bytes_array)) {
            Ok(key) => key,
            Err(_) => { eprintln!("Failed to create k256::SigningKey from decrypted bytes."); return -1; }
        };
        let wallet = LocalWallet::from(signing_key_k256).with_chain_id(chain_id_c);


        let to_str = match c_str_to_string(to_cchar) {
            Ok(s) => s,
            Err(e) => { eprintln!("Error converting to_address: {}", e); return -4; }
        };
        let to_addr = match Address::from_str(to_str.strip_prefix("0x").unwrap_or(&to_str)) {
            Ok(addr) => addr,
            Err(e) => { eprintln!("Error parsing to_address '{}': {}", to_str, e); return -4; }
        };

        let value_str = match c_str_to_string(value_wei_hex_cchar) {
            Ok(s) => s,
            Err(e) => { eprintln!("Error converting value_wei_hex: {}", e); return -4; }
        };
        let value_u256 = match U256::from_str_radix(value_str.strip_prefix("0x").unwrap_or(&value_str), 16) {
            Ok(val) => val,
            Err(e) => { eprintln!("Error parsing value_wei_hex '{}': {}", value_str, e); return -4; }
        };
        
        let data_str = match c_str_to_string(data_hex_cchar) {
            Ok(s) => s,
            Err(e) => { eprintln!("Error converting data_hex: {}", e); return -4; }
        };
        let data_bytes_vec = match hex::decode(data_str.strip_prefix("0x").unwrap_or(&data_str)) {
            Ok(b) => b,
            Err(e) => { eprintln!("Error decoding data_hex '{}': {}", data_str, e); return -4; }
        };
        let data_ethers_bytes = EthersBytes::from(data_bytes_vec);

        let nonce_u256 = U256::from(nonce_c);
        let gas_price_str = match c_str_to_string(gas_price_wei_hex_cchar) {
            Ok(s) => s,
            Err(e) => { eprintln!("Error converting gas_price_wei_hex: {}", e); return -4; }
        };
        let gas_price_u256 = match U256::from_str_radix(gas_price_str.strip_prefix("0x").unwrap_or(&gas_price_str), 16) {
            Ok(val) => val,
            Err(e) => { eprintln!("Error parsing gas_price_wei_hex '{}': {}", gas_price_str, e); return -4; }
        };
        
        let gas_limit_u256 = U256::from(gas_limit_c);
        
        let tx_request = TransactionRequest::new()
            .to(to_addr)
            .value(value_u256)
            .data(data_ethers_bytes)
            .nonce(nonce_u256)
            .gas_price(gas_price_u256)
            .gas(gas_limit_u256);

        let typed_tx: ethers::types::transaction::eip2718::TypedTransaction = tx_request.clone().into();

        let signature: EthersSignature = match wallet.sign_transaction_sync(&typed_tx) {
            Ok(sig) => sig,
            Err(e) => { eprintln!("Error signing transaction: {}", e); return -2; }
        };
        
        let signed_tx_rlp_bytes = tx_request.rlp_signed(&signature);
        let signed_tx_hex = format!("0x{}", hex::encode(signed_tx_rlp_bytes));

        if signed_tx_hex.len() + 1 > out_buffer_len_c as usize { 
            eprintln!("Output buffer too small. Needed: {}, Available: {}", signed_tx_hex.len() + 1, out_buffer_len_c);
            return -3; 
        }

        unsafe {
            let c_string = match CString::new(signed_tx_hex.clone()) {
                Ok(cs) => cs,
                Err(_) => { eprintln!("Failed to create CString from signed_tx_hex."); return -4; }
            };
            ptr::copy_nonoverlapping(c_string.as_ptr(), signed_tx_hex_out_ptr, signed_tx_hex.len());
            *signed_tx_hex_out_ptr.add(signed_tx_hex.len()) = 0; 
        }
        
        signed_tx_hex.len() as c_int
    });

    match result {
        Ok(val) => val,
        Err(_) => { eprintln!("Panic caught in sign_evm_transaction_ffi"); -5 }
    }
}

#[no_mangle]
pub extern "C" fn store_new_key_ffi(
    key_identifier_cchar: *const c_char,
    master_password_cchar: *const c_char,
) -> c_int {
    let result = panic::catch_unwind(|| {
        let key_id = match c_str_to_string(key_identifier_cchar) {
            Ok(s) => s,
            Err(e) => { eprintln!("Error converting key_identifier for store: {}", e); return -11; } // New error code
        };
        let master_password = match c_str_to_string(master_password_cchar) {
            Ok(s) => s,
            Err(e) => { eprintln!("Error converting master_password for store: {}", e); return -12; } // New error code
        };

        // 1. Generate new k256 SigningKey (private key)
        let new_signing_key = SigningKey::random(&mut OsRng); // OsRng needs to be in scope
        let pk_bytes: [u8; 32] = new_signing_key.to_bytes().into();

        // 2. Encrypt and prepare for file
        let encrypted_file_data = match encrypt_pk_and_prepare_file_data(&pk_bytes, &master_password) {
            Ok(data) => data,
            Err(e) => { eprintln!("Failed to encrypt new key for '{}': {}", key_id, e); return -13; } // New error code
        };

        // 3. Serialize to JSON
        let json_data = match serde_json::to_string_pretty(&encrypted_file_data) {
            Ok(json) => json,
            Err(e) => { eprintln!("Failed to serialize encrypted key data for '{}': {}", key_id, e); return -14; } // New error code
        };

        // 4. Save to file
        let key_store_path = match get_key_storage_path() {
            Ok(path) => path,
            Err(e) => { eprintln!("Failed to get key_storage_path for store: {}", e); return -15; } // New error code
        };
        let key_file_path = key_store_path.join(format!("{}.json", key_id));

        if key_file_path.exists() {
            eprintln!("Key file already exists for identifier: {}. Will not overwrite.", key_id);
            return -16; // Key already exists
        }

        match fs::write(&key_file_path, json_data) {
            Ok(_) => {
                println!("Successfully stored new encrypted key for identifier: {}", key_id);
                // TODO: Set file permissions to be restrictive (e.g., 600)
                0 // Success
            }
            Err(e) => {
                eprintln!("Failed to write key file for '{}': {}", key_id, e);
                -17 // File write error
            }
        }
    });
     match result {
        Ok(val) => val,
        Err(_) => { eprintln!("Panic caught in store_new_key_ffi"); -5 }
    }
}


#[no_mangle]
pub extern "C" fn rust_lib_health_check() -> c_int {
    println!("Rust library 'rust_cutepanel_signer' is alive and reachable!");
    return 0; 
}
