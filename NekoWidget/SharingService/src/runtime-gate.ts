import {
  apnsRuntimeEnabled,
  momentRuntimeEnabled,
  reactionRuntimeEnabled,
  reportIngestionRuntimeEnabled,
  windowNameRuntimeEnabled,
  type Env,
} from "./env";

interface RuntimeGateRow {
  generation: number;
  media_enabled: number;
  apns_enabled: number;
  report_ingestion_enabled: number;
}

export interface RuntimeGateSnapshot {
  readonly generation: number;
  readonly mediaEnabled: boolean;
  readonly apnsEnabled: boolean;
  readonly reportIngestionEnabled: boolean;
}

function bit(value: number): boolean | null {
  if (value === 0) return false;
  if (value === 1) return true;
  return null;
}

/** Missing, malformed, or unreadable gate state is always closed. */
export async function loadRuntimeGate(
  env: Pick<Env, "DB">,
): Promise<RuntimeGateSnapshot | null> {
  try {
    const row = await env.DB.prepare(
      `SELECT generation, media_enabled, apns_enabled,
              report_ingestion_enabled
         FROM personal_staging_runtime_gate
        WHERE singleton = 1`,
    ).first<RuntimeGateRow>();
    if (row === null || !Number.isSafeInteger(row.generation) || row.generation < 0) {
      return null;
    }
    const mediaEnabled = bit(row.media_enabled);
    const apnsEnabled = bit(row.apns_enabled);
    const reportIngestionEnabled = bit(row.report_ingestion_enabled);
    if (mediaEnabled === null || apnsEnabled === null
        || reportIngestionEnabled === null || (apnsEnabled && !mediaEnabled)) {
      return null;
    }
    return Object.freeze({
      generation: row.generation,
      mediaEnabled,
      apnsEnabled,
      reportIngestionEnabled,
    });
  } catch {
    return null;
  }
}

export function mediaGateOpen(snapshot: RuntimeGateSnapshot | null): boolean {
  return snapshot?.mediaEnabled === true;
}

export function apnsGateOpen(snapshot: RuntimeGateSnapshot | null): boolean {
  return snapshot?.mediaEnabled === true && snapshot.apnsEnabled;
}

export function reportIngestionGateOpen(
  snapshot: RuntimeGateSnapshot | null,
): boolean {
  return snapshot?.reportIngestionEnabled === true;
}

export function effectiveRuntimeGateHeaders(
  env: Env,
  snapshot: RuntimeGateSnapshot,
): Headers {
  const media = snapshot.mediaEnabled
    && momentRuntimeEnabled(env)
    && reactionRuntimeEnabled(env)
    && windowNameRuntimeEnabled(env);
  const apns = snapshot.mediaEnabled
    && snapshot.apnsEnabled
    && apnsRuntimeEnabled(env);
  const report = snapshot.reportIngestionEnabled
    && reportIngestionRuntimeEnabled(env);
  return new Headers({
    "Cache-Control": "no-store",
    "Neko-Runtime-Gate-Generation": String(snapshot.generation),
    "Neko-Runtime-Media": media ? "ON" : "OFF",
    "Neko-Runtime-Apns": apns ? "ON" : "OFF",
    "Neko-Runtime-Report-Ingestion": report ? "ON" : "OFF",
  });
}
