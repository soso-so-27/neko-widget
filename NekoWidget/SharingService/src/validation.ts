import { base64urlDecode } from "./encoding";
import { ApiError } from "./errors";

export type JsonRecord = Record<string, unknown>;

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const opaqueIdPattern = /^[A-Za-z0-9_-]{22}$/u;

export function asObject(value: unknown): JsonRecord {
  if (value === null || Array.isArray(value) || typeof value !== "object") {
    throw new ApiError(400, "invalid_json", "The JSON body must be an object.");
  }
  return value as JsonRecord;
}

export function exactKeys(object: JsonRecord, expected: readonly string[]): void {
  const actual = Object.keys(object).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    throw new ApiError(400, "invalid_fields", "The JSON body has missing or unknown fields.");
  }
}

export function stringField(object: JsonRecord, key: string): string {
  const value = object[key];
  if (typeof value !== "string") {
    throw new ApiError(400, "invalid_field", `${key} must be a string.`);
  }
  return value;
}

export function integerField(object: JsonRecord, key: string, minimum: number, maximum: number): number {
  const value = object[key];
  if (!Number.isInteger(value) || (value as number) < minimum || (value as number) > maximum) {
    throw new ApiError(400, "invalid_field", `${key} is outside its allowed range.`);
  }
  return value as number;
}

export function protocolVersion(object: JsonRecord): 1 {
  if (object.protocolVersion !== 1) {
    throw new ApiError(400, "unsupported_protocol", "protocolVersion must be 1.");
  }
  return 1;
}

export function uuidField(object: JsonRecord, key: string): string {
  const value = stringField(object, key);
  if (!uuidPattern.test(value)) {
    throw new ApiError(400, "invalid_field", `${key} must be a lowercase UUIDv4.`);
  }
  return value;
}

export function opaqueId(value: string, name: string): string {
  if (!opaqueIdPattern.test(value)) {
    throw new ApiError(404, "not_found", `${name} was not found.`);
  }
  return value;
}

export function binaryField(object: JsonRecord, key: string, bytes: number): string {
  const value = stringField(object, key);
  base64urlDecode(value, bytes);
  return value;
}
