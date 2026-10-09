export interface OwnerBrowserCredential {
  id: string;
  rawId: ArrayBuffer;
  type: string;
  authenticatorAttachment?: string | null;
  getClientExtensionResults(): unknown;
  response: { clientDataJSON: ArrayBuffer; authenticatorData: ArrayBuffer; signature: ArrayBuffer; userHandle?: ArrayBuffer | null };
}
/** Shared by the actual inline UI and real-signature integration tests.
 * userHandle is not identity proof; identity is selected by Access plus the
 * admitted credential. Preserve the existing verifier's strict contract. */
export function ownerAssertionPayload(credential: OwnerBrowserCredential) {
  function encode(value: ArrayBuffer): string {
    return btoa(String.fromCharCode(...new Uint8Array(value))).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
  }
  return { id: credential.id, rawId: encode(credential.rawId), type: credential.type,
    ...(credential.authenticatorAttachment ? { authenticatorAttachment: credential.authenticatorAttachment } : {}),
    clientExtensionResults: credential.getClientExtensionResults(), response: {
      clientDataJSON: encode(credential.response.clientDataJSON),
      authenticatorData: encode(credential.response.authenticatorData), signature: encode(credential.response.signature),
    } };
}
