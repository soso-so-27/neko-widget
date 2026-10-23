import { ServiceError, sha256, type KeyCustody } from './contracts';
import { canonicalJSON, ImmutableRecordTree, type TreeEntry, type TreeNode, type TreeRef } from './immutable-record-tree';
import type { S3RecoveryCopy } from './s3-recovery-copy';

type Child = { prefix: string; before: TreeRef | null; result: TreeRef | null };
type Frame = { prefix: string; before: TreeRef | null; source: TreeRef | null; children: Child[] | null };
export type ResumableTreePlan = {
  version: 1; ownerId: string; tree: string; keyLength: 32 | 64;
  input: { root: TreeRef; changes: TreeEntry[] }; inputHash: string;
  stack: Frame[]; result: TreeRef | null;
};
export type ResumableTreeIO = {
  /** Must durably bind this operation-scoped ID to these exact node bytes/hash
   * before I/O, and return the same verified ref on replay. No random write is
   * performed by this calculator. The caller owns leases and write readback. */
  durablePreparedNode(node: TreeNode, hash: string, count: number, logicalStepID: string): Promise<TreeRef>;
  /** Pure validation: it can run again when a leaf is reopened after resume. */
  validate?(previous: TreeEntry | undefined, next: TreeEntry): void;
};
const bad = () => new ServiceError('RESUMABLE_TREE_UNAVAILABLE', 503);
const encode = (value: unknown) => new TextEncoder().encode(canonicalJSON(value));
const equal = (a: unknown, b: unknown) => canonicalJSON(a) === canonicalJSON(b);
const clone = <T>(value: T): T => JSON.parse(canonicalJSON(value)) as T;
const exact = (value: unknown, keys: string): value is Record<string, unknown> => !!value
  && typeof value === 'object' && !Array.isArray(value) && Object.getPrototypeOf(value) === Object.prototype
  && Object.keys(value).sort().join(',') === keys;
const maximumCheckpointBytes = 1024 * 1024;
const maximumNodeBytes = 2 * 1024 * 1024;
const maximumCount = 1_000_000;

/** The caller MUST authenticate the complete checkpoint and bind it to its
 * owner/epoch/generation/operation before step(). inputHash is a consistency
 * check, not a signature. Checkpoints retain refs, never decrypted old leaves
 * or key material. Sequential I/O means a rejection leaves no sibling work. */
export class ResumableRecordTree {
  private readonly reader: ImmutableRecordTree;
  constructor(private readonly ownerId: string, private readonly tree: string,
    keys: KeyCustody, s3: S3RecoveryCopy, private readonly keyLength: 32 | 64 = 32) {
    if (keyLength !== 32 && keyLength !== 64) throw bad();
    this.reader = new ImmutableRecordTree(ownerId, tree, keys, s3, keyLength);
  }
  private ref(ref: TreeRef, prefix?: string): void {
    this.reader.validateReference(ref);
    if (typeof ref.object.key !== 'string'
      || ref.object.key !== `recovery/v1/${this.ownerId}/record/${ref.object.key.split('/').at(-1)}`
      || (prefix !== undefined && ref.prefix !== prefix)) throw bad();
  }
  private entries(entries: TreeEntry[], prefix = '', limit = 16): void {
    if (!Array.isArray(entries) || entries.length > limit) throw bad();
    let previous = '';
    for (const entry of entries) {
      if (!exact(entry, 'key,value') || typeof entry.key !== 'string' || entry.key.length !== this.keyLength
        || !/^[0-9a-f]+$/u.test(entry.key) || !entry.key.startsWith(prefix) || entry.key <= previous
        || encode(entry.value).length > 24 * 1024) throw bad();
      previous = entry.key;
    }
  }
  private closure(plan: ResumableTreePlan): unknown {
    return { version: 1, ownerId: this.ownerId, tree: this.tree, keyLength: this.keyLength, input: plan.input };
  }
  private bounded(plan: ResumableTreePlan): void {
    if (encode(plan).length > maximumCheckpointBytes) throw bad();
  }
  async begin(root: TreeRef, changes: TreeEntry[]): Promise<ResumableTreePlan> {
    this.ref(root, '');
    if (!Array.isArray(changes) || !changes.length || changes.length > 16) throw bad();
    const sorted = clone(changes).sort((a, b) => a.key.localeCompare(b.key));
    this.entries(sorted);
    const plan: ResumableTreePlan = { version: 1, ownerId: this.ownerId, tree: this.tree, keyLength: this.keyLength,
      input: { root: clone(root), changes: sorted }, inputHash: '',
      stack: [{ prefix: '', before: clone(root), source: null, children: null }], result: null };
    plan.inputHash = await sha256(encode(this.closure(plan)));
    this.bounded(plan);
    return plan;
  }
  private async validate(plan: ResumableTreePlan): Promise<void> {
    this.bounded(plan);
    if (!exact(plan, 'input,inputHash,keyLength,ownerId,result,stack,tree,version') || plan.version !== 1
      || plan.ownerId !== this.ownerId || plan.tree !== this.tree || plan.keyLength !== this.keyLength
      || !exact(plan.input, 'changes,root') || !Array.isArray(plan.stack) || plan.stack.length > this.keyLength + 1
      || typeof plan.inputHash !== 'string' || !/^[0-9a-f]{64}$/u.test(plan.inputHash)) throw bad();
    this.ref(plan.input.root, ''); this.entries(plan.input.changes);
    if (!plan.input.changes.length || await sha256(encode(this.closure(plan))) !== plan.inputHash) throw bad();
    if (plan.result !== null) {
      this.ref(plan.result, '');
      if (plan.stack.length || plan.result.count < plan.input.root.count
        || plan.result.count > plan.input.root.count + plan.input.changes.length) throw bad();
      return;
    }
    if (!plan.stack.length) throw bad();
    for (let at = 0; at < plan.stack.length; at++) {
      const frame = plan.stack[at]!;
      if (!exact(frame, 'before,children,prefix,source') || typeof frame.prefix !== 'string'
        || frame.prefix.length > this.keyLength || !/^[0-9a-f]*$/u.test(frame.prefix)) throw bad();
      if (frame.before !== null) this.ref(frame.before, frame.prefix);
      if (frame.source !== null) {
        this.ref(frame.source);
        if (!frame.prefix.startsWith(frame.source.prefix) || frame.source.count < 1 || frame.source.count > 64
          || (frame.before !== null && !equal(frame.before, frame.source))) throw bad();
      }
      if (!at) {
        if (frame.prefix !== '' || !equal(frame.before, plan.input.root)) throw bad();
      } else {
        const parent = plan.stack[at - 1]!;
        const slot = parent.children?.find(child => child.result === null);
        if (!slot || slot.prefix !== frame.prefix || !equal(slot.before, frame.before)) throw bad();
        const source = parent.source;
        if (source !== null ? !equal(frame.source, source)
          : frame.source !== null && (!frame.children || !equal(frame.source, frame.before))) throw bad();
      }
      if (frame.children !== null) {
        if (!Array.isArray(frame.children) || !frame.children.length || frame.children.length > 16
          || frame.prefix.length >= this.keyLength) throw bad();
        let previous = '';
        for (const child of frame.children) {
          if (!exact(child, 'before,prefix,result') || typeof child.prefix !== 'string'
            || child.prefix.length !== frame.prefix.length + 1 || !child.prefix.startsWith(frame.prefix)
            || !/^[0-9a-f]+$/u.test(child.prefix) || child.prefix <= previous) throw bad();
          previous = child.prefix;
          for (const ref of [child.before, child.result]) if (ref !== null) {
            this.ref(ref, child.prefix); if (ref.count < 1) throw bad();
          }
          if (frame.source !== null && child.before !== null) throw bad();
          if (child.before === null && child.result === null
            && frame.source === null && !plan.input.changes.some(entry => entry.key.startsWith(child.prefix))) throw bad();
        }
      }
    }
  }
  private merged(node: TreeNode | null, frame: Frame, changes: TreeEntry[], io: ResumableTreeIO): TreeEntry[] {
    if (node !== null && !('entries' in node)) throw bad();
    const previous = new Map((node?.entries ?? []).filter(entry => entry.key.startsWith(frame.prefix))
      .map(entry => [entry.key, entry]));
    for (const entry of changes) {
      const old = previous.get(entry.key);
      io.validate?.(old === undefined ? undefined : clone(old), clone(entry));
      previous.set(entry.key, entry);
    }
    const entries = [...previous.values()].sort((a, b) => a.key.localeCompare(b.key));
    this.entries(entries, frame.prefix, 80);
    return entries;
  }
  private groups(entries: TreeEntry[], prefix: string): string[] {
    return [...new Set(entries.map(entry => entry.key.slice(0, prefix.length + 1)))].sort();
  }
  private finish(plan: ResumableTreePlan, result: TreeRef): void {
    const frame = plan.stack.pop()!;
    this.ref(result, frame.prefix);
    if (!plan.stack.length) { plan.result = result; return; }
    const slot = plan.stack.at(-1)!.children!.find(child => child.prefix === frame.prefix);
    if (!slot || slot.result !== null) throw bad();
    slot.result = result;
  }
  async step(input: ResumableTreePlan, budget: { maxReads: number; maxWrites: number }, io: ResumableTreeIO): Promise<{
    plan: ResumableTreePlan; root?: TreeRef; reads: number; writes: number;
  }> {
    if (!Number.isInteger(budget.maxReads) || budget.maxReads < 1 || budget.maxReads > 4
      || !Number.isInteger(budget.maxWrites) || budget.maxWrites < 1 || budget.maxWrites > 4
      || typeof io?.durablePreparedNode !== 'function') throw bad();
    await this.validate(input);
    const plan = clone(input); let reads = 0, writes = 0;
    const read = async (ref: TreeRef): Promise<TreeNode> => {
      if (++reads > budget.maxReads) throw bad();
      return this.reader.readAuthenticatedNode(ref);
    };
    const write = async (node: TreeNode, before: TreeRef | null): Promise<TreeRef> => {
      const count = 'entries' in node ? node.entries.length : node.children.reduce((sum, child) => sum + child.count, 0);
      if (count > maximumCount || encode(node).length > maximumNodeBytes) throw bad();
      const semantic = 'entries' in node ? node : { ...node,
        children: node.children.map(({ prefix, count, hash }) => ({ prefix, count, hash })) };
      const hash = await sha256(encode(semantic));
      if (before?.hash === hash && before.count === count) return before;
      if (++writes > budget.maxWrites) throw bad();
      this.bounded(plan);
      const result = await io.durablePreparedNode(clone(node), hash, count, `${plan.inputHash}:${node.prefix || '-'}:${hash}`);
      this.ref(result, node.prefix);
      if (result.count !== count || result.hash !== hash) throw bad();
      return clone(result);
    };
    if (plan.result !== null) {
      await read(plan.result);
      return { plan, root: clone(plan.result), reads, writes };
    }
    while (plan.stack.length) {
      const frame = plan.stack.at(-1)!;
      const changes = plan.input.changes.filter(entry => entry.key.startsWith(frame.prefix));
      if (frame.children !== null) {
        const pending = frame.children.find(child => child.result === null);
        if (pending) {
          plan.stack.push({ prefix: pending.prefix, before: pending.before, source: frame.source, children: null });
          this.bounded(plan); continue;
        }
        if (writes >= budget.maxWrites || ((frame.before || frame.source) && reads >= budget.maxReads)) break;
        // Reopen the authenticated old parent/source on the publishing step.
        // Do not turn a prior request's decrypted node into an authority cache.
        const node = frame.source ? await read(frame.source) : frame.before ? await read(frame.before) : null;
        if (frame.source !== null) {
          const entries = this.merged(node, frame, changes, io), groups = this.groups(entries, frame.prefix);
          if (entries.length <= 64 || !equal(groups, frame.children.map(child => child.prefix))) throw bad();
          for (const child of frame.children) if (child.result!.count !== entries.filter(entry => entry.key.startsWith(child.prefix)).length) throw bad();
        } else {
          if (!node || !('children' in node)) throw bad();
          const old = new Map(node.children.map(ref => [ref.prefix, ref]));
          const groups = [...new Set([...old.keys(), ...this.groups(changes, frame.prefix)])].sort();
          if (!equal(groups, frame.children.map(child => child.prefix))) throw bad();
          for (const child of frame.children) {
            if (!equal(child.before, old.get(child.prefix) ?? null)) throw bad();
            const delta = changes.filter(entry => entry.key.startsWith(child.prefix));
            if (!delta.length && !equal(child.result, child.before)) throw bad();
            if (child.result!.count < (child.before?.count ?? 0)
              || child.result!.count > (child.before?.count ?? 0) + delta.length) throw bad();
          }
        }
        const next: TreeNode = { version: 1, ownerId: this.ownerId, tree: this.tree, prefix: frame.prefix,
          children: frame.children.map(child => child.result!) };
        this.finish(plan, await write(next, frame.before));
      } else {
        if (writes >= budget.maxWrites || ((frame.before || frame.source) && reads >= budget.maxReads)) break;
        const node = frame.source ? await read(frame.source) : frame.before ? await read(frame.before) : null;
        if (node && 'children' in node) {
          if (frame.source !== null) throw bad();
          const children = new Map(node.children.map(ref => [ref.prefix, ref]));
          frame.children = [...new Set([...children.keys(), ...this.groups(changes, frame.prefix)])].sort()
            .map(prefix => ({ prefix, before: children.get(prefix) ?? null,
              result: changes.some(entry => entry.key.startsWith(prefix)) ? null : children.get(prefix)! }));
        } else {
          const entries = this.merged(node, frame, changes, io);
          if (entries.length <= 64) {
            const next: TreeNode = { version: 1, ownerId: this.ownerId, tree: this.tree, prefix: frame.prefix, entries };
            this.finish(plan, await write(next, frame.before));
          } else {
            if (frame.prefix.length >= this.keyLength || (!frame.source && !frame.before)) throw bad();
            frame.source ??= frame.before;
            frame.children = this.groups(entries, frame.prefix).map(prefix => ({ prefix, before: null, result: null }));
          }
        }
      }
      this.bounded(plan);
    }
    await this.validate(plan);
    return { plan, ...(plan.result ? { root: clone(plan.result) } : {}), reads, writes };
  }
}
