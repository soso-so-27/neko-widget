import {test} from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {readFile} from 'node:fs/promises';

test('atomic key boundary rejects old ciphertext and revoked scope but permits cleanup and legacy installations',async()=>{
 const db=new DatabaseSync(':memory:');
 db.exec(`CREATE TABLE moderation_owner_scope_installation(id);
 CREATE TABLE scopes(target_operator_id,target_credential_id_sha256,enrollment_request_id,transcript_json);
 CREATE VIEW moderation_owner_current_scope_adoptions AS SELECT * FROM scopes;
 CREATE TABLE policies(owner_operator_id,credential_id_sha256,enrollment_admission_id);
 CREATE VIEW moderation_owner_current_policies AS SELECT * FROM policies;
 CREATE TABLE moderation_operator_enrollment_admissions(enrollment_admission_id,enrollment_request_id);
 CREATE TABLE moment_reports(id PRIMARY KEY,moderation_key_id,state);
 INSERT INTO moment_reports VALUES('old','moderation-v1','reserved');
 INSERT INTO moderation_owner_scope_installation VALUES(1);
 INSERT INTO scopes VALUES('owner','credential','request','{"target":{"moderationKeyId":"moderation-v2"}}');
 INSERT INTO policies VALUES('owner','credential','admission');
 INSERT INTO moderation_operator_enrollment_admissions VALUES('admission','request');`);
 db.exec(await readFile(new URL('../migrations/0036_moderation_owner_report_key.sql',import.meta.url),'utf8'));
 assert.throws(()=>db.exec("INSERT INTO moment_reports VALUES('bad','moderation-v1','reserved')"),/current report key required/);
 assert.throws(()=>db.exec("UPDATE moment_reports SET state='uploaded' WHERE id='old'"),/current report key required/);
 db.exec("INSERT INTO moment_reports VALUES('good','moderation-v2','reserved'); UPDATE moment_reports SET state='uploaded' WHERE id='good'");
 db.exec('DELETE FROM policies');
 assert.throws(()=>db.exec("UPDATE moment_reports SET state='committed' WHERE id='good'"),/current report key required/);
 assert.throws(()=>db.exec("INSERT INTO moment_reports VALUES('revoked','moderation-v2','reserved')"),/current report key required/);
 db.exec("UPDATE moment_reports SET state='expired' WHERE id='old'; DELETE FROM moment_reports WHERE id='old'; DELETE FROM moderation_owner_scope_installation; INSERT INTO moment_reports VALUES('legacy','moderation-v1','reserved')");
 db.close();
});
