import assert from 'node:assert/strict';

/** The caller obtains the ARN from owner-protected local configuration.
 * Never persist a rendered production policy in the public checkout. */
export function renderProductionKmsPolicy(template, keyArn) {
  assert.equal(typeof keyArn, 'string');
  assert.match(keyArn, /^arn:aws:kms:ap-northeast-1:\d{12}:key\/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/);
  assert.equal(template.Statement.length, 1);
  const statement = template.Statement[0];
  assert.equal(statement.Resource, '${PRODUCTION_PRESERVATION_KMS_KEY_ARN}');
  assert.equal(statement.Effect, 'Allow');
  assert.deepEqual([...statement.Action].sort(), ['kms:Decrypt', 'kms:Encrypt']);
  assert.deepEqual(statement.Condition, {
    Null: { 'kms:EncryptionContextKeys': false },
    'ForAllValues:StringEquals': { 'kms:EncryptionContextKeys': 'neko-preservation-context-sha256' },
  });
  return { ...structuredClone(template), Statement: [{ ...structuredClone(statement), Resource: keyArn }] };
}
