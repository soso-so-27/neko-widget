import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import test from "node:test";
import {
  bodySHA256,
  requestTranscript,
  responseTranscript,
  signTranscript,
  verifyTranscript,
} from "../src/internal-auth.js";

interface Fixture {
  secret: string;
  timestamp: number;
  nonce: string;
  requestBody: string;
  requestBodySHA256: string;
  requestSignature: string;
  responseStatus: number;
  responseBody: string;
  responseBodySHA256: string;
  responseSignature: string;
}

const fixture = JSON.parse(await readFile(join(
  import.meta.dirname,
  "../../ci/fixtures/billing-verifier-protocol-v1.json",
), "utf8")) as Fixture;
const secret = Buffer.from(fixture.secret, "base64url");

test("matches the cross-runtime billing verifier protocol vector", () => {
  const requestBody = Buffer.from(fixture.requestBody);
  assert.equal(bodySHA256(requestBody), fixture.requestBodySHA256);
  const request = requestTranscript(
    fixture.timestamp,
    fixture.nonce,
    fixture.requestBodySHA256,
  );
  assert.equal(signTranscript(secret, request), fixture.requestSignature);
  assert.equal(verifyTranscript(secret, fixture.requestSignature, request), true);

  const responseBody = Buffer.from(fixture.responseBody);
  assert.equal(bodySHA256(responseBody), fixture.responseBodySHA256);
  const response = responseTranscript(
    fixture.nonce,
    fixture.responseStatus,
    fixture.responseBodySHA256,
  );
  assert.equal(signTranscript(secret, response), fixture.responseSignature);
  assert.equal(verifyTranscript(secret, fixture.responseSignature, response), true);
  assert.equal(verifyTranscript(secret, fixture.responseSignature, request), false);
});
