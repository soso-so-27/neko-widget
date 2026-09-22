// Matches the app's explicit, transformed viewing copy, not a full-resolution original.
export const MAX_PHOTO_BYTES = 20 * 1024 * 1024;
export const MAX_SIDE = 4096;
export const MAX_PIXELS = MAX_SIDE * MAX_SIDE;
export const MAX_BASE64_LENGTH = Math.ceil(MAX_PHOTO_BYTES / 3) * 4;
export const MAX_REQUEST_BYTES = MAX_BASE64_LENGTH + 64;
export const MAX_BODY_CHUNKS = 4096;
export const MAX_MARKERS = 4096;
export const MAX_SCANS = 64;
export const BODY_TIMEOUT_MS = 2000;
export const DECODE_TIMEOUT_MS = 6000;

export class Unavailable extends Error {
  constructor() { super('DEPENDENCY_UNAVAILABLE'); }
}
