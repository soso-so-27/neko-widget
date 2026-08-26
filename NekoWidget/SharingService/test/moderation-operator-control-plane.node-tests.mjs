import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

const projectDirectory = join(import.meta.dirname, "..");
const caseMigration = await readFile(join(
  projectDirectory,
  "migrations",
  "0012_moderation_case_lifecycle.sql",
), "utf8");
const operatorMigration = await readFile(join(
  projectDirectory,
  "migrations",
  "0013_moderation_operator_control_plane.sql",
), "utf8");

const reportID = "moderation-report-001";
const caseReference = "c".repeat(64);
const actionID = "30000000-0000-4000-8000-000000000001";
const requestPath = "/operator/v1/cases/content-delete";
const requestBodySHA256 = "d".repeat(64);

function database() {
  const value = new DatabaseSync(":memory:");
  value.exec("PRAGMA foreign_keys = ON");
  value.exec(`
    CREATE TABLE moment_report_tombstones (
      report_id TEXT PRIMARY KEY,
      committed_at INTEGER NOT NULL
    ) STRICT;
    INSERT INTO moment_report_tombstones(report_id, committed_at)
    VALUES ('${reportID}', unixepoch() - 60);
  `);
  value.exec(caseMigration);
  value.exec(operatorMigration);
  return value;
}

function registerOperator(value, {
  operatorID,
  subjectCharacter,
  credentialCharacter,
  role,
  hmacKeyVersion = 1,
  registrationSignCount = 0,
}) {
  const credentialID = credentialCharacter.repeat(64);
  value.prepare(`
    INSERT INTO moderation_operators(operator_id)
    VALUES (?)
  `).run(operatorID);
  value.prepare(`
    INSERT INTO moderation_operator_subject_identities(
      operator_id, access_subject_hmac_key_version, access_subject_hmac
    ) VALUES (?, ?, ?)
  `).run(operatorID, hmacKeyVersion, subjectCharacter.repeat(64));
  value.prepare(`
    INSERT INTO moderation_operator_state_events(operator_id, event_type)
    VALUES (?, 'activated')
  `).run(operatorID);
  value.prepare(`
    INSERT INTO moderation_operator_role_events(operator_id, role_code, event_type)
    VALUES (?, ?, 'granted')
  `).run(operatorID, role);
  value.prepare(`
    INSERT INTO moderation_operator_credentials(
      credential_id_sha256, operator_id, public_key_cose,
      registration_sign_count
    ) VALUES (?, ?, ?, ?)
  `).run(
    credentialID,
    operatorID,
    Buffer.alloc(64, 7),
    registrationSignCount,
  );
  value.prepare(`
    INSERT INTO moderation_operator_credential_events(
      credential_id_sha256, event_type
    ) VALUES (?, 'registered')
  `).run(credentialID);
  return { operatorID, credentialID, hmacKeyVersion };
}

function insertCaseReference(value) {
  value.prepare(`
    INSERT INTO moderation_operator_case_references(report_id, case_reference_hmac)
    VALUES (?, ?)
  `).run(reportID, caseReference);
}

function insertChallenge(value, {
  challengeID,
  challengeHash,
  actor,
  purpose,
  targetActionID = actionID,
  bodySHA256 = requestBodySHA256,
  expiresIn = 300,
}) {
  value.prepare(`
    INSERT INTO moderation_operator_challenges(
      challenge_id, operator_id, access_subject_hmac_key_version,
      credential_id_sha256,
      access_session_sha256, challenge_value_sha256, purpose,
      action_type, action_id, case_reference_hmac,
      method, pathname, body_sha256, expires_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, 'content_delete', ?, ?,
              'POST', ?, ?, unixepoch() + ?)
  `).run(
    challengeID,
    actor.operatorID,
    actor.hmacKeyVersion,
    actor.credentialID,
    "a".repeat(64),
    challengeHash,
    purpose,
    targetActionID,
    caseReference,
    requestPath,
    bodySHA256,
    expiresIn,
  );
}

function consumeChallenge(value, {
  challengeID,
  actor,
  assertionHash,
  signCount,
}) {
  value.prepare(`
    INSERT INTO moderation_operator_challenge_consumptions(
      challenge_id, operator_id, credential_id_sha256,
      verified_assertion_sha256, authenticator_sign_count
    ) VALUES (?, ?, ?, ?, ?)
  `).run(
    challengeID,
    actor.operatorID,
    actor.credentialID,
    assertionHash,
    signCount,
  );
}

function insertAction(value, {
  targetActionID = actionID,
  challengeID,
  requester,
  requestSHA256 = requestBodySHA256,
  requestMethod = "POST",
  requestPathname = requestPath,
  expiresIn = 900,
}) {
  value.prepare(`
    INSERT INTO moderation_operator_actions(
      action_id, case_reference_hmac, action_type,
      requester_operator_id, request_challenge_id, request_sha256,
      request_method, request_pathname, required_approvals,
      required_approver_role, expires_at
    ) VALUES (?, ?, 'content_delete', ?, ?, ?, ?, ?, 1,
              'privacy_approver', unixepoch() + ?)
  `).run(
    targetActionID,
    caseReference,
    requester.operatorID,
    challengeID,
    requestSHA256,
    requestMethod,
    requestPathname,
    expiresIn,
  );
}

function insertApproval(value, {
  targetActionID = actionID,
  challengeID,
  approver,
  approvalHash,
  approvalMethod = "POST",
  approvalPathname = requestPath,
}) {
  value.prepare(`
    INSERT INTO moderation_operator_action_approvals(
      action_id, operator_id, approval_challenge_id, approval_sha256
      , approval_method, approval_pathname
    ) VALUES (?, ?, ?, ?, ?, ?)
  `).run(
    targetActionID,
    approver.operatorID,
    challengeID,
    approvalHash,
    approvalMethod,
    approvalPathname,
  );
}

function fixture() {
  const value = database();
  const requester = registerOperator(value, {
    operatorID: "10000000-0000-4000-8000-000000000001",
    subjectCharacter: "1",
    credentialCharacter: "2",
    role: "evidence_reviewer",
  });
  const approver = registerOperator(value, {
    operatorID: "20000000-0000-4000-8000-000000000001",
    subjectCharacter: "3",
    credentialCharacter: "4",
    role: "privacy_approver",
  });
  insertCaseReference(value);
  return { value, requester, approver };
}

test("migration applies with foreign keys and stores no raw identity/token columns", () => {
  const value = database();
  assert.equal(value.prepare("PRAGMA foreign_keys").get().foreign_keys, 1);
  const tables = value.prepare(`
    SELECT name FROM sqlite_schema
     WHERE type = 'table' AND name LIKE 'moderation_operator_%'
     ORDER BY name
  `).all().map((row) => row.name);
  assert.deepEqual(tables, [
    "moderation_operator_action_approvals",
    "moderation_operator_actions",
    "moderation_operator_case_references",
    "moderation_operator_challenge_consumptions",
    "moderation_operator_challenges",
    "moderation_operator_credential_events",
    "moderation_operator_credentials",
    "moderation_operator_role_events",
    "moderation_operator_state_events",
    "moderation_operator_subject_identities",
    "moderation_operators",
  ]);
  for (const table of tables) {
    const columns = value.prepare(`PRAGMA table_info(${table})`).all()
      .map((column) => column.name);
    assert.equal(columns.some((column) => [
      "email", "display_name", "access_jwt", "access_token",
      "credential_id", "assertion", "challenge_value",
    ].includes(column)), false, `${table} contains a raw identity/token column`);
  }
  const actionColumns = value.prepare(`
    PRAGMA table_info(moderation_operator_actions)
  `).all().map((column) => column.name);
  assert.equal(actionColumns.includes("report_id"), false);
  assert.equal(actionColumns.includes("case_reference_hmac"), true);

  const credentialColumns = value.prepare(`
    PRAGMA table_info(moderation_operator_credentials)
  `).all().map((column) => column.name);
  assert.equal(credentialColumns.includes("registration_sign_count"), true);
  const consumptionColumns = value.prepare(`
    PRAGMA table_info(moderation_operator_challenge_consumptions)
  `).all().map((column) => column.name);
  assert.equal(consumptionColumns.includes("credential_id_sha256"), true);
  const consumptionIndexes = value.prepare(`
    PRAGMA index_list(moderation_operator_challenge_consumptions)
  `).all().map((index) => index.name);
  assert.equal(
    consumptionIndexes.includes(
      "moderation_operator_consumptions_credential_counter",
    ),
    true,
  );
  for (const [column, size] of [
    ["operator_id", 36],
    ["access_subject_hmac", 64],
    ["credential_id_sha256", 64],
    ["case_reference_hmac", 64],
    ["challenge_id", 36],
    ["access_session_sha256", 64],
    ["challenge_value_sha256", 64],
    ["action_id", 36],
    ["body_sha256", 64],
    ["verified_assertion_sha256", 64],
    ["request_sha256", 64],
    ["approval_sha256", 64],
  ]) {
    assert.match(
      operatorMigration,
      new RegExp(`length\\(CAST\\(${column} AS BLOB\\)\\) = ${size}`, "u"),
      `${column} must reject a TEXT value with an embedded NUL suffix`,
    );
  }
  value.close();
});

test("rejects embedded-NUL aliases and bounds WebAuthn counters to uint32", () => {
  const { value, requester } = fixture();
  assert.throws(
    () => value.prepare(`
      INSERT INTO moderation_operators(operator_id)
      VALUES (?)
    `).run("80000000-0000-4000-8000-000000000001\0junk"),
    /constraint|CHECK/u,
  );
  assert.throws(
    () => value.prepare(`
      INSERT INTO moderation_operator_subject_identities(
        operator_id, access_subject_hmac_key_version, access_subject_hmac
      ) VALUES (?, 2, ?)
    `).run(requester.operatorID, `${"e".repeat(64)}\0junk`),
    /constraint|CHECK/u,
  );
  assert.throws(
    () => insertChallenge(value, {
      challengeID: "73000000-0000-4000-8000-000000000001",
      challengeHash: "5".repeat(64),
      actor: requester,
      purpose: "request",
      targetActionID: `${actionID}\0junk`,
    }),
    /constraint|CHECK/u,
  );

  value.prepare(`
    INSERT INTO moderation_operator_credentials(
      credential_id_sha256, operator_id, public_key_cose,
      registration_sign_count
    ) VALUES (?, ?, ?, 4294967295)
  `).run("e".repeat(64), requester.operatorID, Buffer.alloc(64, 8));
  assert.throws(
    () => value.prepare(`
      INSERT INTO moderation_operator_credentials(
        credential_id_sha256, operator_id, public_key_cose,
        registration_sign_count
      ) VALUES (?, ?, ?, 4294967296)
    `).run("f".repeat(64), requester.operatorID, Buffer.alloc(64, 9)),
    /constraint|CHECK/u,
  );

  const maximumCounterChallengeID = "73000000-0000-4000-8000-000000000002";
  insertChallenge(value, {
    challengeID: maximumCounterChallengeID,
    challengeHash: "6".repeat(64),
    actor: requester,
    purpose: "request",
  });
  consumeChallenge(value, {
    challengeID: maximumCounterChallengeID,
    actor: requester,
    assertionHash: "7".repeat(64),
    signCount: 4294967295,
  });

  const overflowCounterChallengeID = "73000000-0000-4000-8000-000000000003";
  insertChallenge(value, {
    challengeID: overflowCounterChallengeID,
    challengeHash: "8".repeat(64),
    actor: requester,
    purpose: "request",
  });
  assert.throws(
    () => consumeChallenge(value, {
      challengeID: overflowCounterChallengeID,
      actor: requester,
      assertionHash: "9".repeat(64),
      signCount: 4294967296,
    }),
    /constraint|CHECK/u,
  );
  value.close();
});

test("enforces role separation and immutable non-replaceable operator records", () => {
  const { value, requester } = fixture();
  assert.throws(
    () => value.prepare(`
      INSERT INTO moderation_operator_role_events(operator_id, role_code, event_type)
      VALUES (?, 'privacy_approver', 'granted')
    `).run(requester.operatorID),
    /roles are separated/u,
  );
  assert.throws(
    () => value.prepare(`
      INSERT OR REPLACE INTO moderation_operators(operator_id)
      VALUES (?)
    `).run(requester.operatorID),
    /cannot be replaced/u,
  );
  assert.throws(
    () => value.prepare(`
      INSERT INTO moderation_operators(operator_id)
      VALUES ('-0000000-0000-4000-8000-000000000001')
    `).run(),
    /constraint|CHECK/u,
  );
  assert.throws(
    () => value.exec("UPDATE moderation_operators SET created_at = created_at + 1"),
    /immutable/u,
  );
  assert.throws(
    () => value.exec("DELETE FROM moderation_operators"),
    /cannot be deleted/u,
  );
  value.close();
});

test("rotates versioned subject HMAC aliases without persisting a raw subject", () => {
  const { value, requester } = fixture();
  value.prepare(`
    INSERT INTO moderation_operator_subject_identities(
      operator_id, access_subject_hmac_key_version, access_subject_hmac
    ) VALUES (?, 2, ?)
  `).run(requester.operatorID, "5".repeat(64));

  assert.deepEqual(value.prepare(`
    SELECT access_subject_hmac_key_version, access_subject_hmac
      FROM moderation_operator_subject_identities
     WHERE operator_id = ?
     ORDER BY access_subject_hmac_key_version
  `).all(requester.operatorID).map((row) => ({ ...row })), [
    { access_subject_hmac_key_version: 1, access_subject_hmac: "1".repeat(64) },
    { access_subject_hmac_key_version: 2, access_subject_hmac: "5".repeat(64) },
  ]);
  const rotatedRequester = { ...requester, hmacKeyVersion: 2 };
  insertChallenge(value, {
    challengeID: "71000000-0000-4000-8000-000000000001",
    challengeHash: "8".repeat(64),
    actor: rotatedRequester,
    purpose: "request",
  });
  assert.equal(value.prepare(`
    SELECT access_subject_hmac_key_version
      FROM moderation_operator_challenges
     WHERE challenge_id = '71000000-0000-4000-8000-000000000001'
  `).get().access_subject_hmac_key_version, 2);
  assert.throws(
    () => insertChallenge(value, {
      challengeID: "71000000-0000-4000-8000-000000000002",
      challengeHash: "9".repeat(64),
      actor: { ...requester, hmacKeyVersion: 3 },
      purpose: "request",
    }),
    /FOREIGN KEY/u,
  );
  assert.throws(
    () => value.prepare(`
      INSERT INTO moderation_operator_subject_identities(
        operator_id, access_subject_hmac_key_version, access_subject_hmac
      ) VALUES (?, 1, ?)
    `).run(requester.operatorID, "6".repeat(64)),
    /key version must increase|cannot be replaced/u,
  );
  assert.throws(
    () => value.exec(`
      UPDATE moderation_operator_subject_identities
         SET access_subject_hmac = '${"7".repeat(64)}'
    `),
    /append-only/u,
  );
  assert.throws(
    () => value.exec("DELETE FROM moderation_operator_subject_identities"),
    /cannot be deleted/u,
  );
  value.close();
});

test("enforces the registration sign count on the first assertion", () => {
  const value = database();
  const requester = registerOperator(value, {
    operatorID: "70000000-0000-4000-8000-000000000001",
    subjectCharacter: "5",
    credentialCharacter: "6",
    role: "evidence_reviewer",
    registrationSignCount: 5,
  });
  insertCaseReference(value);
  const challengeID = "70000000-0000-4000-8000-000000000002";
  insertChallenge(value, {
    challengeID,
    challengeHash: "7".repeat(64),
    actor: requester,
    purpose: "request",
  });

  assert.throws(
    () => consumeChallenge(value, {
      challengeID,
      actor: requester,
      assertionHash: "8".repeat(64),
      signCount: 0,
    }),
    /counter rolled back/u,
  );
  assert.throws(
    () => consumeChallenge(value, {
      challengeID,
      actor: requester,
      assertionHash: "9".repeat(64),
      signCount: 5,
    }),
    /counter did not increase/u,
  );
  consumeChallenge(value, {
    challengeID,
    actor: requester,
    assertionHash: "a".repeat(64),
    signCount: 6,
  });
  assert.equal(value.prepare(`
    SELECT credential_id_sha256
      FROM moderation_operator_challenge_consumptions
     WHERE challenge_id = ?
  `).get(challengeID).credential_id_sha256, requester.credentialID);
  value.close();
});

test("caps active unconsumed challenges per operator", () => {
  const { value, requester } = fixture();
  for (let index = 1; index <= 8; index += 1) {
    insertChallenge(value, {
      challengeID: `70000000-0000-4000-8000-${String(index).padStart(12, "0")}`,
      challengeHash: index.toString(16).padStart(64, "0"),
      actor: requester,
      purpose: "request",
    });
  }
  const ninthChallengeID = "70000000-0000-4000-8000-000000000009";
  assert.throws(
    () => insertChallenge(value, {
      challengeID: ninthChallengeID,
      challengeHash: "9".padStart(64, "0"),
      actor: requester,
      purpose: "request",
    }),
    /too many active challenges/u,
  );

  consumeChallenge(value, {
    challengeID: "70000000-0000-4000-8000-000000000001",
    actor: requester,
    assertionHash: "f".repeat(64),
    signCount: 0,
  });
  insertChallenge(value, {
    challengeID: ninthChallengeID,
    challengeHash: "9".padStart(64, "0"),
    actor: requester,
    purpose: "request",
  });
  value.close();
});

test("binds action to consumed step-up and rejects replay, body mismatch and counter rollback", () => {
  const { value, requester } = fixture();
  assert.throws(
    () => insertChallenge(value, {
      challengeID: "400000000000-4000-8000-00000000-0001",
      challengeHash: "0".repeat(64),
      actor: requester,
      purpose: "request",
    }),
    /constraint|CHECK/u,
  );
  assert.throws(
    () => insertChallenge(value, {
      challengeID: "40000000-0000-4000-8000-000000000099",
      challengeHash: "0".repeat(64),
      actor: requester,
      purpose: "request",
      targetActionID: "300000000000-4000-8000-00000000-0001",
    }),
    /constraint|CHECK/u,
  );
  const challengeID = "40000000-0000-4000-8000-000000000001";
  insertChallenge(value, {
    challengeID,
    challengeHash: "5".repeat(64),
    actor: requester,
    purpose: "request",
  });
  consumeChallenge(value, {
    challengeID,
    actor: requester,
    assertionHash: "6".repeat(64),
    signCount: 1,
  });
  assert.throws(
    () => consumeChallenge(value, {
      challengeID,
      actor: requester,
      assertionHash: "7".repeat(64),
      signCount: 2,
    }),
    /already been consumed/u,
  );
  assert.throws(
    () => insertAction(value, {
      challengeID,
      requester,
      requestSHA256: "8".repeat(64),
    }),
    /lacks its bound step-up/u,
  );
  assert.throws(
    () => insertAction(value, {
      challengeID,
      requester,
      requestMethod: "PUT",
    }),
    /lacks its bound step-up/u,
  );
  assert.throws(
    () => insertAction(value, {
      challengeID,
      requester,
      requestPathname: "/operator/v1/cases/other-delete",
    }),
    /lacks its bound step-up/u,
  );
  insertAction(value, { challengeID, requester });
  assert.throws(
    () => value.prepare(`
      INSERT OR REPLACE INTO moderation_operator_actions(
        action_id, case_reference_hmac, action_type,
        requester_operator_id, request_challenge_id, request_sha256,
        request_method, request_pathname, required_approvals,
        required_approver_role, expires_at
      ) SELECT action_id, case_reference_hmac, action_type,
               requester_operator_id, request_challenge_id, ?, request_method,
               request_pathname, required_approvals, required_approver_role,
               expires_at
          FROM moderation_operator_actions WHERE action_id = ?
    `).run("9".repeat(64), actionID),
    /cannot be replaced/u,
  );

  const rollbackID = "40000000-0000-4000-8000-000000000002";
  insertChallenge(value, {
    challengeID: rollbackID,
    challengeHash: "7".repeat(64),
    actor: requester,
    purpose: "approve",
  });
  assert.throws(
    () => consumeChallenge(value, {
      challengeID: rollbackID,
      actor: requester,
      assertionHash: "8".repeat(64),
      signCount: 1,
    }),
    /did not increase/u,
  );

  const revokedCredentialChallengeID = "40000000-0000-4000-8000-000000000003";
  insertChallenge(value, {
    challengeID: revokedCredentialChallengeID,
    challengeHash: "9".repeat(64),
    actor: requester,
    purpose: "approve",
  });
  value.prepare(`
    INSERT INTO moderation_operator_credential_events(
      credential_id_sha256, event_type
    ) VALUES (?, 'revoked')
  `).run(requester.credentialID);
  assert.throws(
    () => consumeChallenge(value, {
      challengeID: revokedCredentialChallengeID,
      actor: requester,
      assertionHash: "a".repeat(64),
      signCount: 2,
    }),
    /credential is not active/u,
  );
  value.close();
});

test("rechecks the consumed credential when creating actions and approvals", () => {
  {
    const { value, requester } = fixture();
    const challengeID = "72000000-0000-4000-8000-000000000001";
    insertChallenge(value, {
      challengeID,
      challengeHash: "5".repeat(64),
      actor: requester,
      purpose: "request",
    });
    consumeChallenge(value, {
      challengeID,
      actor: requester,
      assertionHash: "6".repeat(64),
      signCount: 1,
    });
    value.prepare(`
      INSERT INTO moderation_operator_credential_events(
        credential_id_sha256, event_type
      ) VALUES (?, 'revoked')
    `).run(requester.credentialID);
    assert.throws(
      () => insertAction(value, { challengeID, requester }),
      /request credential is not active/u,
    );
    value.close();
  }

  {
    const { value, requester, approver } = fixture();
    const requestChallengeID = "72000000-0000-4000-8000-000000000002";
    insertChallenge(value, {
      challengeID: requestChallengeID,
      challengeHash: "7".repeat(64),
      actor: requester,
      purpose: "request",
    });
    consumeChallenge(value, {
      challengeID: requestChallengeID,
      actor: requester,
      assertionHash: "8".repeat(64),
      signCount: 1,
    });
    insertAction(value, { challengeID: requestChallengeID, requester });

    const approvalChallengeID = "72000000-0000-4000-8000-000000000003";
    insertChallenge(value, {
      challengeID: approvalChallengeID,
      challengeHash: "9".repeat(64),
      actor: approver,
      purpose: "approve",
    });
    consumeChallenge(value, {
      challengeID: approvalChallengeID,
      actor: approver,
      assertionHash: "a".repeat(64),
      signCount: 1,
    });
    value.prepare(`
      INSERT INTO moderation_operator_credential_events(
        credential_id_sha256, event_type
      ) VALUES (?, 'revoked')
    `).run(approver.credentialID);
    assert.throws(
      () => insertApproval(value, {
        challengeID: approvalChallengeID,
        approver,
        approvalHash: requestBodySHA256,
      }),
      /approval credential is not active/u,
    );
    value.close();
  }
});

test("requires a distinct approver and rejects the same actor's second vote", () => {
  const { value, requester, approver } = fixture();
  const requestChallengeID = "50000000-0000-4000-8000-000000000001";
  insertChallenge(value, {
    challengeID: requestChallengeID,
    challengeHash: "5".repeat(64),
    actor: requester,
    purpose: "request",
  });
  consumeChallenge(value, {
    challengeID: requestChallengeID,
    actor: requester,
    assertionHash: "6".repeat(64),
    signCount: 1,
  });
  insertAction(value, { challengeID: requestChallengeID, requester });

  const selfChallengeID = "50000000-0000-4000-8000-000000000002";
  insertChallenge(value, {
    challengeID: selfChallengeID,
    challengeHash: "7".repeat(64),
    actor: requester,
    purpose: "approve",
  });
  consumeChallenge(value, {
    challengeID: selfChallengeID,
    actor: requester,
    assertionHash: "8".repeat(64),
    signCount: 2,
  });
  assert.throws(
    () => insertApproval(value, {
      challengeID: selfChallengeID,
      approver: requester,
      approvalHash: "9".repeat(64),
    }),
    /cannot approve their own action/u,
  );

  const approvalChallengeID = "50000000-0000-4000-8000-000000000003";
  insertChallenge(value, {
    challengeID: approvalChallengeID,
    challengeHash: "a".repeat(64),
    actor: approver,
    purpose: "approve",
  });
  consumeChallenge(value, {
    challengeID: approvalChallengeID,
    actor: approver,
    assertionHash: "b".repeat(64),
    signCount: 1,
  });
  assert.throws(
    () => insertApproval(value, {
      challengeID: approvalChallengeID,
      approver,
      approvalHash: "f".repeat(64),
    }),
    /lacks its bound step-up/u,
  );
  insertApproval(value, {
    challengeID: approvalChallengeID,
    approver,
    approvalHash: requestBodySHA256,
  });

  const secondChallengeID = "50000000-0000-4000-8000-000000000004";
  insertChallenge(value, {
    challengeID: secondChallengeID,
    challengeHash: "d".repeat(64),
    actor: approver,
    purpose: "approve",
  });
  consumeChallenge(value, {
    challengeID: secondChallengeID,
    actor: approver,
    assertionHash: "e".repeat(64),
    signCount: 2,
  });
  assert.throws(
    () => insertApproval(value, {
      challengeID: secondChallengeID,
      approver,
      approvalHash: "f".repeat(64),
    }),
    /cannot be replaced or repeated|enough approvals/u,
  );
  assert.throws(
    () => value.exec("UPDATE moderation_operator_action_approvals SET recorded_at = recorded_at + 1"),
    /append-only/u,
  );
  assert.throws(
    () => value.exec("DELETE FROM moderation_operator_action_approvals"),
    /cannot be deleted/u,
  );
  value.close();
});

test("rejects expired challenges and actions at database time", () => {
  const { value, requester, approver } = fixture();
  const expiringChallengeID = "60000000-0000-4000-8000-000000000001";
  insertChallenge(value, {
    challengeID: expiringChallengeID,
    challengeHash: "5".repeat(64),
    actor: requester,
    purpose: "request",
    expiresIn: 1,
  });

  const actionRequestChallengeID = "60000000-0000-4000-8000-000000000002";
  const expiringActionID = "60000000-0000-4000-8000-000000000010";
  insertChallenge(value, {
    challengeID: actionRequestChallengeID,
    challengeHash: "6".repeat(64),
    actor: requester,
    purpose: "request",
    targetActionID: expiringActionID,
  });
  consumeChallenge(value, {
    challengeID: actionRequestChallengeID,
    actor: requester,
    assertionHash: "7".repeat(64),
    signCount: 1,
  });
  insertAction(value, {
    targetActionID: expiringActionID,
    challengeID: actionRequestChallengeID,
    requester,
    expiresIn: 1,
  });
  const approvalChallengeID = "60000000-0000-4000-8000-000000000003";
  insertChallenge(value, {
    challengeID: approvalChallengeID,
    challengeHash: "8".repeat(64),
    actor: approver,
    purpose: "approve",
    targetActionID: expiringActionID,
  });
  consumeChallenge(value, {
    challengeID: approvalChallengeID,
    actor: approver,
    assertionHash: "9".repeat(64),
    signCount: 1,
  });

  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 2_100);
  assert.throws(
    () => consumeChallenge(value, {
      challengeID: expiringChallengeID,
      actor: requester,
      assertionHash: "a".repeat(64),
      signCount: 2,
    }),
    /expired or mismatched/u,
  );
  assert.throws(
    () => insertApproval(value, {
      targetActionID: expiringActionID,
      challengeID: approvalChallengeID,
      approver,
      approvalHash: "b".repeat(64),
    }),
    /expired or needs no approval/u,
  );
  value.close();
});
