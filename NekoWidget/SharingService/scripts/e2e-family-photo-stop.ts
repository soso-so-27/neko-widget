import { sha256Base64url } from '../src/encoding';
import type { Env } from '../src/env';
import { ApiError } from '../src/errors';
import { routeFamilyPhotoOperator, type FamilyPhotoOperatorEnvironment } from '../src/family-photo-moderation-operator';
import { registerTestOperator } from '../test/fixtures/moderation-operator';

// Called only by the loopback fixture Worker. All credentials are generated
// in the disposable D1. The real review receipt and decision routes still run.
export async function stopTestPhoto(request: Request, env: Env): Promise<Response> {
  const { reportId } = await request.json<{ reportId?: string }>();
  if (typeof reportId !== 'string' || !/^[A-Za-z0-9_-]{22}$/u.test(reportId)) {
    throw new ApiError(400, 'expected_report_id', 'Pass a family photo report ID.');
  }
  const report = await env.DB.prepare('SELECT outcome FROM family_photo_report_records WHERE report_id=?')
    .bind(reportId).first<{ outcome: string }>();
  if (!report) throw new ApiError(404, 'fixture_report_not_found', 'Report a photo before stopping it.');
  if (report.outcome !== 'received') throw new ApiError(409, 'fixture_report_already_reviewed', 'The report already has a decision.');

  const operator = await registerTestOperator(env.DB);
  await env.DB.prepare(`INSERT INTO moderation_owner_policies(policy_revision,owner_operator_id,enrollment_admission_id,session_rowid_floor)
    SELECT COALESCE((SELECT MAX(policy_revision) FROM moderation_owner_policies),0)+1,?,enrollment_admission_id,
    COALESCE((SELECT MAX(rowid) FROM moderation_operator_access_sessions),0)
    FROM moderation_operator_enrollment_admissions a JOIN moderation_operator_enrollment_requests e USING(enrollment_request_id)
    WHERE e.target_operator_id=? ORDER BY a.rowid DESC LIMIT 1`).bind(operator.operatorId, operator.operatorId).run();
  const local: FamilyPhotoOperatorEnvironment = {
    ...operator.local,
    familyPhoto: {
      runtimeEnabled: 'YES',
      caseHmacKey: crypto.getRandomValues(new Uint8Array(32)),
      async reviewEvidence(review) {
        await review.audit('started');
        const source = await review.readCurrentSource();
        if (source.metadata.reportId !== reportId) throw new Error('Wrong fixture evidence');
        const object = await env.MODERATION_MEDIA?.get(source.objectKey);
        if (!object || object.size !== source.metadata.ciphertextSize ||
            await sha256Base64url(new Uint8Array(await object.arrayBuffer())) !== source.metadata.ciphertextSHA256) {
          throw new Error('Missing fixture evidence');
        }
        await review.audit('disclosure_ready');
        // A synthetic image stands in for the human review host's JPEG.
        return new Uint8Array([255, 216, 255, 217]);
      },
    },
  };
  let counter = 0;
  const prefix = '/operator/family-photo/v1';
  async function verifiedPost(path: string): Promise<Response> {
    const issued = await routeFamilyPhotoOperator(operator.request(path, 'POST'), local);
    if (issued.status !== 202) {
      throw new ApiError(503, 'fixture_operator_challenge_failed', 'The test operator could not start this step.');
    }
    const { challenge, assertionPath } = await issued.json<{ challenge: string; assertionPath: string }>();
    const response = await routeFamilyPhotoOperator(
      operator.request(assertionPath, 'POST', await operator.assertion(challenge, { counter: ++counter })), local,
    );
    if (!response.ok) throw new ApiError(503, 'fixture_operator_step_failed', 'The test operator could not finish this step.');
    return response;
  }
  const queue = await (await verifiedPost(prefix + '/queue'))
    .json<{ cases: { caseReference: string; receiptNumber: string }[] }>();
  const item = queue.cases.find(entry => entry.receiptNumber === reportId);
  if (!item) throw new ApiError(503, 'fixture_report_not_listed', 'The test operator did not find the report.');
  const detail = prefix + '/cases/' + item.caseReference;
  const reviewed = await verifiedPost(detail + '/read');
  const receipt = reviewed.headers.get('X-Moderation-Read-Receipt');
  await reviewed.body?.cancel();
  if (!receipt) throw new ApiError(503, 'fixture_review_missing', 'The test operator did not receive a review receipt.');
  const decision = await verifiedPost(detail + '/photo/' + receipt);
  const { outcome, revision, replyAvailable } = await decision.json<{
    outcome: string; revision: number; replyAvailable: boolean;
  }>();
  return Response.json({ reportId, outcome, revision, replyAvailable });
}
