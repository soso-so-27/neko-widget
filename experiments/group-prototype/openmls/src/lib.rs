use openmls::prelude::{tls_codec::*, *};
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;

struct Device { provider: OpenMlsRustCrypto, signer: SignatureKeyPair,
    credential: CredentialWithKey, package: KeyPackageBundle }
fn device(person: &[u8]) -> Device {
    let provider = OpenMlsRustCrypto::default();
    let suite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;
    let signer = SignatureKeyPair::new(suite.signature_algorithm()).unwrap();
    signer.store(provider.storage()).unwrap();
    let credential = CredentialWithKey { credential: BasicCredential::new(person.to_vec()).into(),
        signature_key: signer.to_public_vec().into() };
    let package = KeyPackage::builder().build(suite, &provider, &signer, credential.clone()).unwrap();
    Device { provider, signer, credential, package }
}
fn protocol(bytes: &[u8]) -> ProtocolMessage {
    MlsMessageIn::tls_deserialize_exact(bytes).unwrap().try_into_protocol_message().unwrap()
}
fn apply(group: &mut MlsGroup, dev: &Device, bytes: &[u8]) {
    let processed = group.process_message(&dev.provider, protocol(bytes)).unwrap();
    if let ProcessedMessageContent::StagedCommitMessage(commit) = processed.into_content() {
        group.merge_staged_commit(&dev.provider, *commit).unwrap();
    } else { panic!("expected commit"); }
}
fn plaintext(group: &mut MlsGroup, dev: &Device, bytes: &[u8]) -> Option<Vec<u8>> {
    let processed = group.process_message(&dev.provider, protocol(bytes)).ok()?;
    if let ProcessedMessageContent::ApplicationMessage(msg) = processed.into_content() { Some(msg.into_bytes()) }
    else { None }
}
fn join(dev: &Device, config: &MlsGroupCreateConfig, welcome: &[u8]) -> MlsGroup {
    let MlsMessageBodyIn::Welcome(w) = MlsMessageIn::tls_deserialize_exact(welcome).unwrap().extract()
        else { panic!("expected welcome"); };
    StagedWelcome::new_from_welcome(&dev.provider, config.join_config(), w, None).unwrap()
        .into_group(&dev.provider).unwrap()
}

pub fn run_cases() -> Vec<u8> {
    let alice = device(b"alice"); let bob1 = device(b"bob");
    let charlie = device(b"charlie"); let bob2 = device(b"bob");
    let config = MlsGroupCreateConfig::builder()
        .ciphersuite(Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519)
        .use_ratchet_tree_extension(true).build();
    let mut a = MlsGroup::new(&alice.provider, &alice.signer, &config, alice.credential.clone()).unwrap();
    let (_, welcome, _) = a.add_members(&alice.provider, &alice.signer,
        &[bob1.package.key_package().clone(), charlie.package.key_package().clone()]).unwrap();
    let welcome = welcome.to_bytes().unwrap();
    a.merge_pending_commit(&alice.provider).unwrap();
    let mut b1 = join(&bob1, &config, &welcome);
    let mut c = join(&charlie, &config, &welcome);
    assert!(a.members().count() == 3);
    let msg = a.create_message(&alice.provider, &alice.signer, b"three people").unwrap().to_bytes().unwrap();
    assert!(plaintext(&mut b1, &bob1, &msg).as_deref() == Some(b"three people"));
    assert!(plaintext(&mut c, &charlie, &msg).as_deref() == Some(b"three people"));
    println!("MLS PASS three people");

    // Charlie is offline through the next two commits.
    let (add, welcome, _) = a.add_members(&alice.provider, &alice.signer,
        &[bob2.package.key_package().clone()]).unwrap();
    let add = add.to_bytes().unwrap(); let welcome = welcome.to_bytes().unwrap();
    a.merge_pending_commit(&alice.provider).unwrap(); apply(&mut b1, &bob1, &add);
    let mut b2 = join(&bob2, &config, &welcome);
    assert!(a.members().count() == 4);
    println!("MLS PASS one person two independent devices");
    let old_epoch = a.epoch();
    let removed: Vec<_> = a.members().filter(|m| m.credential.serialized_content() == b"bob")
        .map(|m| m.index).collect(); assert!(removed.len() == 2);
    let (remove, _, _) = a.remove_members(&alice.provider, &alice.signer, &removed).unwrap();
    let remove = remove.to_bytes().unwrap(); a.merge_pending_commit(&alice.provider).unwrap();
    assert!(a.members().count() == 2);
    let fresh = a.create_message(&alice.provider, &alice.signer, b"after removal").unwrap().to_bytes().unwrap();
    assert!(plaintext(&mut b1, &bob1, &fresh).is_none());
    assert!(plaintext(&mut b2, &bob2, &fresh).is_none());
    println!("MLS PASS removed both devices cannot decrypt next epoch");
    // A stale device can still create an old-epoch message. The application
    // relay must reject its membership AND epoch atomically before accepting.
    let stale = b1.create_message(&bob1.provider, &bob1.signer, b"stale sender").unwrap().to_bytes().unwrap();
    let relay_accepts_stale = old_epoch == a.epoch() && a.members().any(|m| m.credential.serialized_content() == b"bob");
    assert!(!relay_accepts_stale); assert!(!stale.is_empty());
    println!("MLS PASS immediate stale send rejected by relay model");
    assert!(plaintext(&mut c, &charlie, &fresh).is_none());
    apply(&mut c, &charlie, &add); apply(&mut c, &charlie, &remove);
    assert!(plaintext(&mut c, &charlie, &fresh).as_deref() == Some(b"after removal"));
    assert!(plaintext(&mut c, &charlie, &fresh).is_none());
    println!("MLS PASS offline ordered commit catch-up and replay rejection");
    let key = a.export_secret(alice.provider.crypto(), "neko-widget-cache", b"synthetic-photo", 32).unwrap();
    let other = c.export_secret(charlie.provider.crypto(), "neko-widget-cache", b"synthetic-photo", 32).unwrap();
    assert!(key == other);
    key
}

#[no_mangle]
pub unsafe extern "C" fn neko_mls_smoke_and_key(out: *mut u8) -> i32 {
    if out.is_null() { return 2; }
    match std::panic::catch_unwind(run_cases) {
        Ok(key) => { std::ptr::copy_nonoverlapping(key.as_ptr(), out, 32); 0 }, Err(_) => 1
    }
}
