import { JSONParser, TokenType } from '@streamparser/json';

/** Stream one manifest. Retain at most one visible item, never the entire
 * 128 MiB chunked JSON. Unknown formats remain uncounted rather than zero. */
export function productRecordCounter(tool: string) {
  const field = ({ PhotoMemoryNotes:'notes',VeterinaryVisits:'visits',CareHandoff:'cats',
    EvacuationPreparation:'cats',ShowcasePhotos:'entries' } as Record<string,string>)[tool];
  const dictionary = ['LostCatDrafts','CatPreparedness'].includes(tool);
  let count=0, valid=tool==='CatIdentity', schema:unknown, found=false;
  const keys=new Set<string>();
  const paths = field ? [`$.${field}.*`,`$.${field}`,'$.schemaVersion','$.schema']
    : dictionary ? ['$.*'] : ['$.schemaVersion'];
  if(tool==='ShowcasePhotos')paths.push('$.*');
  const parser = new JSONParser({paths,keepStack:false,stringBufferSize:4096,emitPartialTokens:true});
  let depth=0;
  parser.onToken = ({value,token,partial}) => {
    if (typeof value==='string' && value.length>1024*1024) throw new Error('Oversized logical item');
    if(!partial){
      if(token===TokenType.LEFT_BRACE || token===TokenType.LEFT_BRACKET)depth++;
      if(token===TokenType.RIGHT_BRACE || token===TokenType.RIGHT_BRACKET)depth--;
      if(depth>64)throw new Error('Deep logical item');
    }
  };
  parser.onValue = ({key,value,parent,stack}) => {
    if (stack.length===1 && (key==='schemaVersion'||key==='schema') && !dictionary) {schema=value;return;}
    const item = dictionary ? stack.length===1 : stack.length===2 && stack[1]?.key===field
      || tool==='ShowcasePhotos' && stack.length===1 && typeof key==='number';
    if (item) {
      const identity=String(key);
      if (!keys.has(identity)) { keys.add(identity);count++; }
      if (count>100_000) throw new Error('Too many logical items');
      // A selected container must not accumulate already-counted siblings.
      if (parent && key!==undefined) delete (parent as Record<string,unknown>)[key];
    }
    if (field && stack.length===1 && key===field) {
      if(found)throw new Error('Duplicate logical collection');
      found=true;
      valid=tool==='PhotoMemoryNotes' ? !!value && typeof value==='object' && !Array.isArray(value) : Array.isArray(value);
    }
  };
  let first: number | undefined;
  return {
    write(bytes:Uint8Array) {
      first ??= bytes.find(value=>![9,10,13,32].includes(value));
      parser.write(bytes);
    },
    finish():number|null {
      if (!parser.isEnded) parser.end();
      if (!parser.isEnded) return null;
      if(tool==='ShowcasePhotos' && first===91)return count;
      if(first!==123)return null;
      if (dictionary) return count;
      if (tool==='CatIdentity') return typeof schema==='number' ? 0 : null;
      if (!found || !valid) return null;
      if (tool==='PhotoMemoryNotes' && schema!==undefined && ![1,2,3,4].includes(schema as number)) return null;
      return count;
    },
  };
}
