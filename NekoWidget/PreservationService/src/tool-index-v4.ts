import { ServiceError, sha256, type ToolBackupPart } from './contracts';
import { isToolFragmentPath, parseToolIndex, toolManifests, validToolPath, type ToolIndex, type ToolIndexFile } from './documents';

export interface ToolNodeSummary { fileCount: number; nodeCount: number; toolMask: number; manifestMask: number }
export interface ToolNodeChild extends ToolNodeSummary { prefix: string; snapshotID: string; sha256: string }
interface NodeBase { version: 4; snapshotID: string; uploadSnapshotID: string; createdAt: number; prefix: string; previousIndexID?: string }
export type ToolNode = NodeBase & ({ files: ToolIndexFile[]; children?: never } | { children: ToolNodeChild[]; files?: never });
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu;
const hash = /^[0-9a-f]{64}$/u;
const fail = (): never => { throw new ServiceError('INVALID_RECORD'); };
const object = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);
const keys = (v: Record<string, unknown>, allowed: string[]) => Object.keys(v).every(k => allowed.includes(k));
const integer = (v: unknown, low: number, high: number): v is number => Number.isSafeInteger(v) && (v as number) >= low && (v as number) <= high;
const tools = Object.keys(toolManifests).sort();

/** No recursive fetch is needed to accept one node: immutable children have
 * already authenticated their own descendants. The inventory CAS and reference
 * table preserve that induction across asynchronous reads and retirement. */
export function parseToolNode(part: ToolBackupPart): ToolIndex | ToolNode {
  if (part.kind !== 'index') return fail();
  let raw: Uint8Array, value: unknown;
  try {
    raw = Uint8Array.from(atob(part.payload), c => c.charCodeAt(0));
    value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(raw));
  } catch { return fail(); }
  if (!object(value) || value.version !== 4) return parseToolIndex(part);
  if (raw.length > 128 * 1024 || !keys(value, ['version','snapshotID','uploadSnapshotID','createdAt','prefix','files','children','previousIndexID'])
    || typeof value.snapshotID !== 'string' || !uuid.test(value.snapshotID) || value.snapshotID.toLowerCase() !== part.snapshotId
    || typeof value.uploadSnapshotID !== 'string' || !uuid.test(value.uploadSnapshotID)
    || typeof value.createdAt !== 'number' || !Number.isFinite(value.createdAt)
    || typeof value.prefix !== 'string' || !/^[0-9a-f]{0,64}$/u.test(value.prefix)
    || (value.prefix === '' && value.uploadSnapshotID.toLowerCase() !== part.snapshotId)
    || (Object.hasOwn(value, 'files') === Object.hasOwn(value, 'children'))
    || (value.previousIndexID !== undefined && (typeof value.previousIndexID !== 'string' || !uuid.test(value.previousIndexID)
      || value.previousIndexID.toLowerCase() === part.snapshotId))) return fail();
  const ids = new Set([part.snapshotId]);
  if (Object.hasOwn(value, 'files')) {
    if (!Array.isArray(value.files) || value.files.length < 1 || value.files.length > 128) return fail();
    const paths = new Set<string>();
    for (const file of value.files) {
      if (!object(file) || !keys(file, ['path','bytes','sha256','records','sourceSnapshotID'])
        || typeof file.path !== 'string' || paths.has(file.path) || (!validToolPath(file.path) && !isToolFragmentPath(file.path))
        || !integer(file.bytes, 1, (file.path.endsWith('.jpg') ? 20 : 8) * 1024 * 1024)
        || typeof file.sha256 !== 'string' || !hash.test(file.sha256) || !Array.isArray(file.records)
        || file.records.length !== (file.path.endsWith('.jpg') ? 1 : Math.ceil(file.bytes / 49152))
        || (file.sourceSnapshotID !== undefined && (typeof file.sourceSnapshotID !== 'string' || !uuid.test(file.sourceSnapshotID)))) return fail();
      paths.add(file.path);
      for (const id of file.records) {
        if (typeof id !== 'string' || !uuid.test(id) || ids.has(id.toLowerCase())) return fail();
        ids.add(id.toLowerCase());
      }
    }
    if (ids.size > 257) return fail();
  } else {
    if (!Array.isArray(value.children) || value.children.length < 1 || value.children.length > 16 || value.prefix.length >= 64) return fail();
    const prefixes = new Set<string>();
    for (const child of value.children) {
      if (!object(child) || !keys(child, ['prefix','snapshotID','sha256','fileCount','nodeCount','toolMask','manifestMask'])
        || typeof child.prefix !== 'string' || !/^[0-9a-f]+$/u.test(child.prefix)
        || child.prefix.length !== value.prefix.length + 1 || !child.prefix.startsWith(value.prefix) || prefixes.has(child.prefix)
        || typeof child.snapshotID !== 'string' || !uuid.test(child.snapshotID) || ids.has(child.snapshotID.toLowerCase())
        || typeof child.sha256 !== 'string' || !hash.test(child.sha256)
        || !integer(child.fileCount, 1, 100_000) || !integer(child.nodeCount, 1, 8192)
        || !integer(child.toolMask, 1, 255) || !integer(child.manifestMask, 0, 255)
        || (child.manifestMask & child.toolMask) !== child.manifestMask) return fail();
      prefixes.add(child.prefix); ids.add(child.snapshotID.toLowerCase());
    }
  }
  const node = value as unknown as ToolNode;
  const summary = summarizeToolNode(node);
  if (summary.fileCount > 100_000 || summary.nodeCount > 8192) return fail();
  return node;
}

export function summarizeToolNode(node: ToolNode): ToolNodeSummary {
  if (node.children) return node.children.reduce((sum, child) => ({
    fileCount: sum.fileCount + child.fileCount, nodeCount: sum.nodeCount + child.nodeCount,
    toolMask: sum.toolMask | child.toolMask, manifestMask: sum.manifestMask | child.manifestMask,
  }), { fileCount: 0, nodeCount: 1, toolMask: 0, manifestMask: 0 });
  let toolMask = 0, manifestMask = 0;
  for (const file of node.files) {
    const [tool, name] = file.path.split('/'), bit = 1 << tools.indexOf(tool!);
    toolMask |= bit;
    if (name === toolManifests[tool!]) manifestMask |= bit;
  }
  return { fileCount: node.files.length, nodeCount: 1, toolMask, manifestMask };
}
export async function validateToolNodePaths(node: ToolNode): Promise<void> {
  if (node.files) for (const file of node.files) if (!(await sha256(file.path)).startsWith(node.prefix)) return fail();
}
export function toolNodeReferences(node: ToolNode): string[] {
  return node.children ? node.children.map(child => child.snapshotID.toLowerCase())
    : node.files.flatMap(file => file.records.map(id => id.toLowerCase()));
}
export function isCompleteToolRoot(node: ToolIndex | ToolNode): boolean {
  if (node.version !== 4) return node.version === 3;
  const summary = summarizeToolNode(node);
  return node.prefix === '' && summary.toolMask === summary.manifestMask;
}
