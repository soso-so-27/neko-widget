import assert from 'node:assert/strict';
import test from 'node:test';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync, readdirSync } from 'node:fs';
import { fixture, seedReviewedFixture } from './fixtures/billing-ledger-before-0062.mjs';

const directory = new URL('../migrations/', import.meta.url);
const migration = readFileSync(new URL('0064_family_environment_policy.sql', directory), 'utf8');
// Exact old Worker column lists. Adding policy must not break old deployments.
const admission = `INSERT INTO family_notebook_admission_events
  (actor_device_id,operation_id,actor_person_id,request_hash,family_id,operation,expected_generation,
    resulting_generation,invitation_id,join_id,proof_public_key,ciphertext,store_environment,maximum_members)
  VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`;
const payer = `INSERT INTO family_notebook_payer_events
  (actor_device_id,operation_id,request_hash,actor_person_id,family_id,operation,
    expected_generation,resulting_generation,store_environment) VALUES (?,?,?,?,?,?,?,?,?)`;
const governance = `INSERT INTO family_notebook_governance_events
  (actor_device_id,operation_id,actor_person_id,family_id,request_hash,action,target_person_id,nomination_id,
    expected_generation,resulting_generation,store_environment) VALUES (?,?,?,?,?,?,?,?,?,?,?)`;
function create(db, id, environment='Sandbox') {
  db.prepare(admission).run('device-a','create-'+id,'person-a','hash',id,'create',0,1,null,null,null,null,environment,6);
}
function populated() {
  const db = new DatabaseSync(':memory:'); db.exec('PRAGMA foreign_keys=ON');
  for (const name of readdirSync(directory).filter(n=>n.endsWith('.sql') && n<'0064').sort()) {
    if(name.startsWith('0062')) {
      seedReviewedFixture(db);
      db.exec('UPDATE billing_reconciliation_jobs SET lease_token=NULL,lease_expires_at=NULL');
    }
    db.exec(readFileSync(new URL(name,directory),'utf8'));
  }
  for(const person of ['a','b']) {
    db.prepare("INSERT INTO group_people VALUES(?,?,'active',unixepoch())").run('person-'+person,'identity-'+person);
    db.prepare("INSERT INTO group_person_devices VALUES(?,?,?,?,?,'active',unixepoch(),NULL)")
      .run('device-'+person,'person-'+person,'signing-'+person,'hpke-'+person,'authorization');
  }
  db.prepare('INSERT INTO group_billing_connections VALUES(?,?,?,?,unixepoch())')
    .run('person-a',fixture.billingAccountId,'device-a',fixture.billingKeyId);
  db.exec('UPDATE billing_runtime_gate SET generation=generation+1,effective_entitlement_enabled=1,updated_at=unixepoch() WHERE singleton=1; UPDATE family_notebook_runtime_gate SET generation=generation+1,enabled=1 WHERE singleton=1');
  create(db,'family-old');
  db.exec("INSERT INTO family_notebook_members VALUES('family-old','person-b','active',1,NULL)");
  db.prepare(governance).run('device-a','nomination','person-a','family-old','hash','nominate','person-b','nomination',1,2,'Sandbox');
  db.prepare(payer).run('device-b','leave-b','hash','person-b','family-old','leave',2,3,'Sandbox');
  db.exec(`INSERT INTO family_notebook_crypto_rosters VALUES('family-old',1,'synthetic-hash','{"synthetic":"roster"}'); INSERT INTO family_notebook_crypto_operations VALUES('family-old',1,'synthetic-operation',1,'person-a','device-a','{"synthetic":"history"}')`);
  return db;
}

test('0064 retains populated audit/history rows, defaults old writers to one store and keeps the eight-column crypto guard',()=>{
  const db=populated();
  try {
    const tables=db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'family_notebook_%' ORDER BY name").all().map(r=>r.name);
    const before=Object.fromEntries(tables.map(name=>[name,db.prepare(`SELECT * FROM ${name} ORDER BY rowid`).all().map(r=>({...r}))]));
    const oldCrypto=db.prepare("SELECT sql FROM sqlite_master WHERE name IN ('family_notebook_crypto_checks','family_notebook_crypto_check_validate') ORDER BY name").all();
    db.exec('BEGIN;'+migration+'COMMIT;');
    for(const name of tables) {
      const rows=db.prepare(`SELECT * FROM ${name} ORDER BY rowid`).all().map(row=>{
        const result={...row};
        if('accept_sandbox_in_production' in result) {assert.equal(result.accept_sandbox_in_production,0);delete result.accept_sandbox_in_production;}
        return result;
      });
      assert.deepEqual(rows,before[name],name);
    }
    assert.deepEqual(db.prepare("SELECT sql FROM sqlite_master WHERE name IN ('family_notebook_crypto_checks','family_notebook_crypto_check_validate') ORDER BY name").all(),oldCrypto);
    db.prepare('INSERT INTO family_notebook_crypto_checks VALUES(?,?,?,?,?,?,?,?)')
      .run('old-read','family-old','person-a','device-a',3,null,'read','Sandbox');
    db.exec("DELETE FROM family_notebook_crypto_checks WHERE id='old-read'");
    db.prepare(payer).run('device-a','leave-a','hash','person-a','family-old','leave',3,4,'Sandbox');
    assert.throws(()=>create(db,'prod-rejected','Production'),/family_notebook_plus_required/u);
    create(db,'family-after');
    db.prepare(governance).run('device-a','dissolve','person-a','family-after','hash','dissolve',null,null,1,2,'Sandbox');
    for(const name of ['payer','admission','governance']) assert.equal(db.prepare(`SELECT MAX(accept_sandbox_in_production) permission FROM family_notebook_${name}_events`).get().permission,0);
    assert.equal(db.prepare('SELECT count(*) n FROM family_notebook_crypto_operations').get().n,1);
    assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(),[]);
  } finally {db.close();}
});

test('0064 changes only the three paid-environment predicates and copies all crypto identity/membership/generation fences',()=>{
  const old=readFileSync(new URL('0062_billing_environment_ledger.sql',directory),'utf8');
  const trigger=(source,name)=>source.replaceAll('\r\n','\n').match(new RegExp('CREATE TRIGGER '+name+'\\b[\\s\\S]*?\\nEND;','u'))[0];
  const normalize=text=>text
    .replaceAll("(p.environment=NEW.store_environment OR (NEW.store_environment='Production' AND NEW.accept_sandbox_in_production=1 AND p.environment='Sandbox'))",'p.environment=NEW.store_environment')
    .replaceAll("(environment=NEW.store_environment OR (NEW.store_environment='Production' AND NEW.accept_sandbox_in_production=1 AND environment='Sandbox'))",'environment=NEW.store_environment');
  for(const name of ['family_notebook_payer_event_validate','family_notebook_admission_validate','family_notebook_governance_validate']) {
    assert.equal(normalize(trigger(migration,name)),trigger(old,name));
  }
  const crypto=normalize(trigger(migration,'family_notebook_crypto_environment_check_validate'))
    .replaceAll('family_notebook_crypto_environment_check_validate','family_notebook_crypto_check_validate')
    .replaceAll('ON family_notebook_crypto_environment_checks','ON family_notebook_crypto_checks');
  assert.equal(crypto,trigger(old,'family_notebook_crypto_check_validate'));
});

test('0064 rolls back schema and existing family rows if the migration transaction aborts before commit',()=>{
  const db=populated();
  const snapshot=()=>{
    const schema=db.prepare("SELECT type,name,sql FROM sqlite_master WHERE name LIKE 'family_notebook_%' ORDER BY type,name").all();
    return {schema,rows:Object.fromEntries(schema.filter(r=>r.type==='table')
      .map(r=>[r.name,db.prepare(`SELECT * FROM ${r.name} ORDER BY rowid`).all()]))};
  };
  try {
    const before=snapshot();db.exec('BEGIN;'+migration);
    assert.throws(()=>db.exec('SELECT * FROM intentionally_absent_migration_probe'),/no such table/u);
    db.exec('ROLLBACK');assert.deepEqual(snapshot(),before);
    assert.deepEqual(db.prepare('PRAGMA foreign_key_check').all(),[]);
  } finally {db.close();}
});
