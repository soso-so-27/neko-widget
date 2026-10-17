import { calculateJwkThumbprint, decodeProtectedHeader, importJWK, jwtVerify } from 'jose';
import { type DeviceBinding, type DevicePublicKey, ServiceError } from './contracts';

const denied = () => new ServiceError('unauthorized', 401);
const coordinate = /^[A-Za-z0-9_-]{43}$/u;

/** A public-only P-256 key, independent of the billing credential. */
export async function deviceBinding(value: unknown, origin: string): Promise<DeviceBinding> {
  try {
    if (!value || typeof value !== 'object' || Array.isArray(value)
      || Object.keys(value).sort().join(',') !== 'crv,kty,x,y') throw denied();
    const key = value as DevicePublicKey;
    const url = new URL(origin);
    if (url.protocol !== 'https:' || url.origin !== origin || key.kty !== 'EC' || key.crv !== 'P-256'
      || !coordinate.test(key.x) || !coordinate.test(key.y)) throw denied();
    // Import rejects coordinates that are not a point on the required curve.
    await importJWK({ ...key }, 'ES256');
    return { publicKey: { kty: 'EC', crv: 'P-256', x: key.x, y: key.y },
      thumbprint: await calculateJwkThumbprint({ ...key }, 'sha256'), origin };
  } catch { throw denied(); }
}

export async function verifyDeviceProof(proof: unknown, binding: DeviceBinding, expected: {
  challengeId: string; subject: string; nonce: string; path: string; origin: string; now: number;
}): Promise<void> {
  try {
    if (typeof proof !== 'string' || proof.length < 64 || proof.length > 8192
      || expected.origin !== binding.origin) throw denied();
    const header = decodeProtectedHeader(proof);
    if (Object.keys(header).sort().join(',') !== 'alg,jwk,typ'
      || header.alg !== 'ES256' || header.typ !== 'dpop+jwt') throw denied();
    const supplied = await deviceBinding(header.jwk, binding.origin);
    if (supplied.thumbprint !== binding.thumbprint) throw denied();
    const { payload } = await jwtVerify(proof, await importJWK({ ...binding.publicKey }, 'ES256'), {
      algorithms: ['ES256'], typ: 'dpop+jwt', currentDate: new Date(expected.now), clockTolerance: 0,
      requiredClaims: ['jti', 'sub', 'iat', 'exp'],
    });
    if (Object.keys(payload).sort().join(',') !== 'exp,htm,htu,iat,jti,nonce,sub,v'
      || payload.v !== 1 || payload.jti !== expected.challengeId || payload.sub !== expected.subject
      || payload.nonce !== expected.nonce || payload.htm !== 'POST'
      || payload.htu !== binding.origin + expected.path
      || !Number.isSafeInteger(payload.iat) || !Number.isSafeInteger(payload.exp)
      || payload.iat! < 0 || payload.iat! > Math.floor(expected.now / 1000) + 30
      || payload.exp! <= payload.iat! || payload.exp! - payload.iat! > 120) throw denied();
  } catch { throw denied(); }
}
