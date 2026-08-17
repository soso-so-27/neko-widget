import { ApiError } from "./errors";

export function base64urlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

export function base64urlDecode(value: string, expectedBytes?: number): Uint8Array {
  if (!/^[A-Za-z0-9_-]+$/u.test(value)) {
    throw new ApiError(400, "invalid_base64url", "A binary field is not canonical base64url.");
  }
  const padding = "=".repeat((4 - (value.length % 4)) % 4);
  let binary: string;
  try {
    binary = atob(value.replaceAll("-", "+").replaceAll("_", "/") + padding);
  } catch {
    throw new ApiError(400, "invalid_base64url", "A binary field is not canonical base64url.");
  }
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  if (base64urlEncode(bytes) !== value) {
    throw new ApiError(400, "invalid_base64url", "A binary field is not canonical base64url.");
  }
  if (expectedBytes !== undefined && bytes.length !== expectedBytes) {
    throw new ApiError(400, "invalid_binary_length", `A binary field must be ${expectedBytes} bytes.`);
  }
  return bytes;
}

export function randomBase64url(byteCount: number): string {
  const bytes = new Uint8Array(byteCount);
  crypto.getRandomValues(bytes);
  return base64urlEncode(bytes);
}

function arrayBufferCopy(bytes: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(bytes.length);
  copy.set(bytes);
  return copy.buffer;
}

export async function sha256(bytes: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", arrayBufferCopy(bytes)));
}

export async function sha256Base64url(bytes: Uint8Array): Promise<string> {
  return base64urlEncode(await sha256(bytes));
}

export async function verifyEd25519(
  publicKeyValue: string,
  signatureValue: string,
  message: Uint8Array,
): Promise<boolean> {
  const publicKey = await crypto.subtle.importKey(
    "raw",
    arrayBufferCopy(base64urlDecode(publicKeyValue, 32)),
    { name: "Ed25519" },
    false,
    ["verify"],
  );
  return crypto.subtle.verify(
    { name: "Ed25519" },
    publicKey,
    arrayBufferCopy(base64urlDecode(signatureValue, 64)),
    arrayBufferCopy(message),
  );
}
