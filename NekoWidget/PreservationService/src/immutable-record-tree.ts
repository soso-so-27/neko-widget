import { ServiceError, sha256, type KeyCustody } from './contracts';
import type { RecoveryObject, S3RecoveryCopy } from './s3-recovery-copy';

export type TreeEntry = { key: string; value: unknown };
export type TreeRef = { object: RecoveryObject; prefix: string; count: number; hash: string };
export type TreeDiffFrame = { before:TreeRef|null; after:TreeRef };
type Leaf = { version: 1; ownerId: string; tree: string; prefix: string; entries: TreeEntry[] };
type Branch = { version: 1; ownerId: string; tree: string; prefix: string; children: TreeRef[] };
export type TreeNode = Leaf | Branch;
type Node = TreeNode;
type Expected = { prefix: string; count: number; hash: string; entries?: TreeEntry[]; children?: Expected[] };
const bad = () => new ServiceError('IMMUTABLE_TREE_UNAVAILABLE',503);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const hex = /^[0-9a-f]{64}$/u;
const maximumNodeBytes = 2 * 1024 * 1024;
// A previously authenticated root can be updated without materializing its
// inventory. Keep that lifetime bound separate from all-array operations.
const maximumTreeEntries = 1_000_000;
const maximumMaterializedEntries = 100_000;
const maximumValueBytes = 24 * 1024;
// Shared within this Worker isolate, including independently constructed owner
// and application trees. A permit is transferred directly to the next waiter.
let inFlight = 0;
const waiting: (() => void)[] = [];
async function treeIO<T>(work: () => Promise<T>): Promise<T> {
  if (inFlight < 8) inFlight++;
  else await new Promise<void>(resolve => waiting.push(resolve));
  try { return await work(); }
  finally { const next = waiting.shift(); if (next) next(); else inFlight--; }
}
export function canonicalJSON(value: unknown, depth=0): string {
  if(depth>64)throw bad();
  if (value === null || typeof value === 'boolean' || typeof value === 'string') return JSON.stringify(value);
  if (typeof value === 'number' && Number.isFinite(value)) return JSON.stringify(value);
  if (Array.isArray(value)) return '[' + value.map(item=>canonicalJSON(item,depth+1)).join(',') + ']';
  if (value && typeof value === 'object' && Object.getPrototypeOf(value) === Object.prototype) {
    const object = value as Record<string,unknown>;
    return '{' + Object.keys(object).sort().map(key => JSON.stringify(key) + ':' + canonicalJSON(object[key],depth+1)).join(',') + '}';
  }
  throw bad();
}
const bytes = (value: unknown) => new TextEncoder().encode(canonicalJSON(value));
const exact = (value: object, keys: string) => Object.keys(value).sort().join(',') === keys;
/** Owner-bound immutable radix pages. One logical change rewrites only its
 * bounded leaf and ancestor path. History is retained; refs name exact S3
 * versions and sealed SHA256 values, never mutable object locations.
 */
export class ImmutableRecordTree {
  constructor(private readonly ownerId: string, private readonly tree: string,
    private readonly keys: KeyCustody, private readonly s3: S3RecoveryCopy,
    private readonly keyLength: 32 | 64 = 32) {
    if (!uuid.test(ownerId) || !/^[a-z0-9-]{1,40}$/u.test(tree)) throw bad();
  }
  private validKey(key: string) {
    if (key.length !== this.keyLength || !/^[0-9a-f]+$/u.test(key)) throw bad();
  }
  private validRef(ref: TreeRef) {
    if (!ref || !exact(ref,'count,hash,object,prefix') || typeof ref.prefix !== 'string'
      || ref.prefix.length > this.keyLength || !/^[0-9a-f]*$/u.test(ref.prefix)
      || !Number.isSafeInteger(ref.count) || ref.count < 0 || ref.count > maximumTreeEntries || !hex.test(ref.hash)
      || !ref.object || !exact(ref.object,'bytes,key,sha256,versionId')
      || !ref.object.key.startsWith('recovery/v1/' + this.ownerId + '/record/')
      || !uuid.test(ref.object.key.split('/').at(-1) ?? '')
      || !hex.test(ref.object.sha256) || !Number.isSafeInteger(ref.object.bytes)
      || ref.object.bytes < 1 || ref.object.bytes > maximumNodeBytes + 8192
      || typeof ref.object.versionId !== 'string' || !ref.object.versionId || ref.object.versionId === 'null') throw bad();
  }
  private semantic(node: Node) {
    return 'entries' in node ? node : { ...node, children: node.children.map(ref => ({
      prefix:ref.prefix,count:ref.count,hash:ref.hash,
    })) };
  }
  private async readNode(ref: TreeRef): Promise<Node> {
    this.validRef(ref);
    const opened = await treeIO(async()=>this.keys.open(await this.s3.getVerified(ref.object),{ ownerId:this.ownerId,purpose:'recovery' }));
    if (opened.length > maximumNodeBytes) throw bad();
    const node = JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(opened)) as Node;
    if (!node || node.version !== 1 || node.ownerId !== this.ownerId || node.tree !== this.tree
      || node.prefix !== ref.prefix) throw bad();
    if ('entries' in node) {
      if (!exact(node,'entries,ownerId,prefix,tree,version') || !Array.isArray(node.entries)
        || node.entries.length > 64 || node.entries.length !== ref.count) throw bad();
      let previous = '';
      for (const entry of node.entries) {
        if (!entry || !exact(entry,'key,value')) throw bad();
        this.validKey(entry.key);
        if (!entry.key.startsWith(ref.prefix) || entry.key <= previous) throw bad();
        previous=entry.key; if(bytes(entry.value).length>maximumValueBytes)throw bad();
      }
    } else {
      if (!exact(node,'children,ownerId,prefix,tree,version') || !Array.isArray(node.children)
        || node.children.length < 1 || node.children.length > 16) throw bad();
      let previous=''; let count=0;
      for (const child of node.children) {
        this.validRef(child);
        if (child.prefix.length !== ref.prefix.length+1 || !child.prefix.startsWith(ref.prefix)
          || child.prefix <= previous || child.count < 1) throw bad();
        previous=child.prefix;count+=child.count;
      }
      if (count !== ref.count) throw bad();
    }
    if (await sha256(bytes(this.semantic(node))) !== ref.hash) throw bad();
    return node;
  }
  /** Continuation callers share the exact reference and authenticated-node checks. */
  validateReference(ref: TreeRef): void { this.validRef(ref); }
  async readAuthenticatedNode(ref: TreeRef): Promise<TreeNode> { return this.readNode(ref); }
  private async expected(entries: TreeEntry[], prefix=''): Promise<Expected> {
    if (entries.length <= 64 && bytes(entries).length < maximumNodeBytes-512) {
      const node: Leaf={version:1,ownerId:this.ownerId,tree:this.tree,prefix,entries};
      return {prefix,count:entries.length,hash:await sha256(bytes(node)),entries};
    }
    if (prefix.length >= this.keyLength) throw bad();
    const groups=new Map<string,TreeEntry[]>();
    for (const entry of entries) {
      const key=entry.key.slice(0,prefix.length+1);
      const group=groups.get(key) ?? [];group.push(entry);groups.set(key,group);
    }
    const children: Expected[]=[];
    for (const [child,group] of [...groups].sort(([a],[b])=>a.localeCompare(b))) children.push(await this.expected(group,child));
    const semantic={version:1,ownerId:this.ownerId,tree:this.tree,prefix,
      children:children.map(child=>({prefix:child.prefix,count:child.count,hash:child.hash}))};
    return {prefix,count:entries.length,hash:await sha256(bytes(semantic)),children};
  }
  private async writeNode(node: Node, hash: string, count: number): Promise<TreeRef> {
    const data=bytes(node);if(data.length>maximumNodeBytes)throw bad();
    const object=await treeIO(async()=>this.s3.putVersioned('recovery/v1/'+this.ownerId+'/record/'+crypto.randomUUID(),
      await this.keys.seal(data,{ownerId:this.ownerId,purpose:'recovery'})));
    const result={object,prefix:node.prefix,count,hash};this.validRef(result);return result;
  }
  private async store(expected: Expected, previous?: TreeRef): Promise<TreeRef> {
    if(previous){
      this.validRef(previous);
      if(previous.prefix!==expected.prefix)throw bad();
      if(previous.count===expected.count && previous.hash===expected.hash)return previous;
    }
    if(expected.entries) return this.writeNode({version:1,ownerId:this.ownerId,tree:this.tree,
      prefix:expected.prefix,entries:expected.entries},expected.hash,expected.count);
    const old=previous?await this.readNode(previous):null;
    const prior=new Map(old && 'children' in old?old.children.map(ref=>[ref.prefix,ref]):[]);
    const children:TreeRef[]=[];
    // Bound external calls. No unbounded node download/encryption fan-out.
    for(let offset=0;offset<expected.children!.length;offset+=8) {
      const results = await Promise.allSettled(expected.children!.slice(offset,offset+8)
        .map(child=>this.store(child,prior.get(child.prefix))));
      // Keep the caller's payload permit until every sibling I/O has drained.
      const failure = results.find(result=>result.status === 'rejected');
      if (failure?.status === 'rejected') throw failure.reason;
      for (const result of results) if (result.status === 'fulfilled') children.push(result.value);
    }
    return this.writeNode({version:1,ownerId:this.ownerId,tree:this.tree,prefix:expected.prefix,children},expected.hash,expected.count);
  }
  async create(input: TreeEntry[], previous?: TreeRef): Promise<TreeRef> {
    if(input.length>maximumMaterializedEntries)throw bad();
    const entries=input.map(entry=>({key:entry.key,value:JSON.parse(canonicalJSON(entry.value)) as unknown})).sort((a,b)=>a.key.localeCompare(b.key));let prior='';
    for(const entry of entries){
      this.validKey(entry.key);
      if(entry.key<=prior || bytes(entry.value).length>maximumValueBytes)throw bad();
      prior=entry.key;
    }
    if(previous && previous.prefix!=='')throw bad();
    return this.store(await this.expected(entries),previous);
  }
  async entries(root: TreeRef): Promise<TreeEntry[]> {
    if(root.prefix!=='' || root.count>maximumMaterializedEntries)throw bad();
    const output:TreeEntry[]=[];const seen=new Set<string>();
    const walk=async(ref:TreeRef):Promise<void>=>{
      if(seen.has(ref.object.key))throw bad();seen.add(ref.object.key);
      const node=await this.readNode(ref);
      if('entries' in node)output.push(...node.entries);
      else for(const child of node.children)await walk(child);
      if(output.length>maximumMaterializedEntries)throw bad();
    };
    await walk(root);
    if(output.length!==root.count)throw bad();
    return output;
  }
  /** A bounded, authenticated keyset walk. The caller persists only after and
   * binds it to this exact immutable root. No whole-tree Set or output array. */
  async page(root: TreeRef, after='', limit=200): Promise<{entries:TreeEntry[];nextAfter:string|null;nodes:number}> {
    this.validRef(root);
    if(root.prefix!=='' || !Number.isInteger(limit) || limit<1 || limit>200)throw bad();
    if(after)this.validKey(after);
    const output:TreeEntry[]=[];let nodes=0,stopped=false;
    const walk=async(ref:TreeRef):Promise<void>=>{
      if(stopped || ref.prefix+'f'.repeat(this.keyLength-ref.prefix.length)<=after)return;
      if(nodes===256 || output.length===limit){stopped=true;return;}
      const node=await this.readNode(ref);nodes++;
      if('entries' in node){
        for(const item of node.entries){
          if(item.key<=after)continue;
          if(output.length===limit){stopped=true;break;}
          if(output.length && item.key<=output.at(-1)!.key)throw bad();
          output.push(item);
        }
      } else for(const child of node.children)await walk(child);
    };
    await walk(root);
    if(stopped && !output.length)throw bad();
    return {entries:output,nextAfter:stopped?output.at(-1)!.key:null,nodes};
  }
  /** Offline journal-owned traversal state, never a client cursor. Unchanged
   * authenticated subtrees need no fetch. The journal keeps earlier IDs and
   * compares the final count, so disappearance cannot be mistaken for deletion. */
  async differencePage(before:TreeRef|null,after:TreeRef,pending?:TreeDiffFrame[]):Promise<{
    entries:TreeEntry[];pending:TreeDiffFrame[];nodes:number}> {
    this.validRef(after);if(before)this.validRef(before);
    if(after.prefix!=='' || (before && before.prefix!==''))throw bad();
    const stack=pending?[...pending]:[{before,after}];
    if(stack.length>512)throw bad();
    const entries:TreeEntry[]=[];let nodes=0;
    while(stack.length && nodes<=14){
      const frame=stack.pop()!;this.validRef(frame.after);if(frame.before)this.validRef(frame.before);
      if(frame.before?.hash===frame.after.hash && frame.before.count===frame.after.count)continue;
      const next=await this.readNode(frame.after);nodes++;
      if('entries' in next){
        if(entries.length+next.entries.length>200){stack.push(frame);break;}
        entries.push(...next.entries);
      }else{
        const old=frame.before?await this.readNode(frame.before):null;if(old)nodes++;
        const previous=new Map(old && 'children' in old?old.children.map(child=>[child.prefix,child]):[]);
        for(const child of [...next.children].reverse())stack.push({before:previous.get(child.prefix)??null,after:child});
        if(stack.length>512)throw bad();
      }
    }
    return {entries,pending:stack,nodes};
  }
  /** Verify the authenticated root page without expanding unchanged leaves. */
  async verifyRoot(root: TreeRef): Promise<void> {
    if (root.prefix !== '') throw bad();
    await this.readNode(root);
  }
  async logicalHash(input: TreeEntry[]): Promise<string> {
    if(input.length>maximumMaterializedEntries)throw bad();
    const entries=[...input].sort((a,b)=>a.key.localeCompare(b.key));return (await this.expected(entries)).hash;
  }
  /** Apply a bounded logical delta without downloading unchanged subtrees. */
  async update(root: TreeRef, changes: TreeEntry[], validate?: (previous:TreeEntry|undefined,next:TreeEntry)=>void): Promise<TreeRef> {
    this.validRef(root);if(root.prefix!=='' || changes.length>200)throw bad();
    changes=changes.map(entry=>({key:entry.key,value:JSON.parse(canonicalJSON(entry.value)) as unknown}));
    const unique=new Set<string>();for(const entry of changes){this.validKey(entry.key);if(unique.has(entry.key) || bytes(entry.value).length>maximumValueBytes)throw bad();unique.add(entry.key);}
    const apply=async(ref:TreeRef,delta:TreeEntry[]):Promise<TreeRef>=>{
      if(!delta.length)return ref;
      const node=await this.readNode(ref);
      if('entries' in node){
        const values=new Map(node.entries.map(entry=>[entry.key,entry]));
        for(const entry of delta){validate?.(values.get(entry.key),entry);values.set(entry.key,entry);}
        return this.store(await this.expected([...values.values()].sort((a,b)=>a.key.localeCompare(b.key)),ref.prefix),ref);
      }
      const children=new Map(node.children.map(child=>[child.prefix,child]));
      const groups=new Map<string,TreeEntry[]>();
      for(const entry of delta){const prefix=entry.key.slice(0,ref.prefix.length+1);const items=groups.get(prefix)??[];items.push(entry);groups.set(prefix,items);}
      for(const [prefix,items] of groups){
        const child=children.get(prefix);
        if(!child)for(const item of items)validate?.(undefined,item);
        const next=child?await apply(child,items):await this.store(await this.expected(items.sort((a,b)=>a.key.localeCompare(b.key)),prefix));
        children.set(prefix,next);
      }
      const list=[...children.values()].sort((a,b)=>a.prefix.localeCompare(b.prefix));
      const next:Branch={...node,children:list};const count=list.reduce((sum,child)=>sum+child.count,0);
      if(count>maximumTreeEntries)throw bad();
      const hash=await sha256(bytes(this.semantic(next)));
      if(hash===ref.hash && count===ref.count)return ref;
      return this.writeNode(next,hash,count);
    };
    return apply(root,changes);
  }
}
