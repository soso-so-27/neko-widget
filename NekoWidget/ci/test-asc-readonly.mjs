import test from 'node:test';
import assert from 'node:assert/strict';
import { safeText, validationSummary } from './asc-readonly.mjs';
test('summary excludes identities, links, and remediation command IDs', () => {
  const result=validationSummary({appId:'1234567890',versionId:'private-version',summary:{errors:1},checks:[{
    id:'build.missing',severity:'error',resourceId:'private-build',message:'App 1234567890 private-version key-secret person@example.com',
    remediation:'https://example.com/private-build private-build',resourceType:'builds'}]},['key-secret']);
  const text=JSON.stringify(result);
  for (const value of ['1234567890','private-version','private-build','key-secret','person@example.com','https://']) assert.ok(!text.includes(value));
  assert.equal(result.checks[0].id,'build.missing');
  assert.equal(result.summary.errors,1);
});
test('unknown IDs and newlines cannot leak through free-form findings',()=>{
  assert.equal(safeText('1234567890\nabc@example.com'), '[resource] [email]');
});
