import { JSONParser, TokenType } from '@streamparser/json';

/** Stream one manifest. Retain at most one visible item, never the entire
 * 128 MiB chunked JSON. Unknown formats remain uncounted rather than zero. */
export function productRecordCounter(tool: string) {
  if (tool==='CatCare' || tool==='FamilyNotebook') return notebookRecordCounter(tool);
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

/** A notebook's revisions/outbox/ACKs are not records. Count stable visible
 * rows, with deletion winning just as FamilyNotebookTarget.removes does. */
function notebookRecordCounter(tool:string) {
  const care=tool==='CatCare', collection=care?'cats':'copies';
  type Target={familyCatID:string;collection:string;recordID?:string|undefined;parentRecordID?:string|undefined;field?:string};
  const targets=new Map<string,Target>(), removed=new Set<string>(), deletedCats=new Set<string>();
  const copyIDs=new Set<string>(), catIDs=new Set<string>();
  let count=0, schema:unknown, found=false, valid=true;
  const key=(t:Target)=>[t.familyCatID,t.collection,t.recordID??'',t.parentRecordID??''].join('/');
  const paths=[`$.${collection}.*`,`$.${collection}`,care?'$.schemaVersion':'$.version'];
  if(!care) for(const list of ['operations','acknowledgements','mappings','ledgerKeys','outboxIDs','farewellDecisions']) paths.push(`$.copies.*.state.${list}.*`);
  const parser=new JSONParser({paths,keepStack:false,stringBufferSize:4096,emitPartialTokens:true});
  let depth=0;
  parser.onToken=({value,token,partial})=>{
    if(typeof value==='string' && value.length>1024*1024)throw new Error('Oversized logical item');
    if(!partial){
      if(token===TokenType.LEFT_BRACE||token===TokenType.LEFT_BRACKET)depth++;
      if(token===TokenType.RIGHT_BRACE||token===TokenType.RIGHT_BRACKET)depth--;
      if(depth>64)throw new Error('Deep logical item');
    }
  };
  const drop=(parent:unknown,k:unknown)=>{if(parent && k!==undefined)delete (parent as Record<string,unknown>)[String(k)];};
  parser.onValue=({key:k,value,parent,stack})=>{
    if(stack.length===1 && k===(care?'schemaVersion':'version')){schema=value;return;}
    if(!care && stack.length===5 && stack[1]?.key==='copies' && stack[3]?.key==='state'){
      if(stack[4]?.key==='operations'){
        const t=(value as {target?:Target})?.target;
        if(!t || typeof t.familyCatID!=='string' || !['cat','weight','medication','vaccination','meal','visit','visitEntry','handoff','handoffMeal'].includes(t.collection)
          || (t.collection!=='cat' && typeof t.recordID!=='string')){valid=false;}
        else if(t.field==null){if(t.collection==='cat')deletedCats.add(t.familyCatID);else removed.add(key(t));}
        else targets.set(key(t),t);
        if(targets.size+removed.size+deletedCats.size>100_000)throw new Error('Too many logical items');
      }
      drop(parent,k);return;
    }
    if(stack.length===2 && stack[1]?.key===collection){
      if(care){
        const cat=value as Record<string,unknown>;
        if(!cat || typeof cat.catID!=='string' || catIDs.has(cat.catID)){valid=false;}
        else {
          catIDs.add(cat.catID);
          if(cat.deletedAt==null){
            count++;
            for(const name of ['weights','medications','vaccinations','meals']){
              const rows=cat[name];
              if(!Array.isArray(rows)){valid=false;continue;}
              const ids=new Set<string>();
              for(const row of rows){
                if(!row || typeof row.id!=='string' || ids.has(row.id)){valid=false;continue;}
                ids.add(row.id);if(row.deletedAt==null)count++;
              }
            }
          }
        }
      } else {
        const copy=value as {id?:string;state?:{schemaVersion?:number;operations?:unknown[]}};
        if(!copy || typeof copy.id!=='string' || copyIDs.has(copy.id) || ![1,2].includes(copy.state?.schemaVersion??0) || !Array.isArray(copy.state?.operations)){valid=false;}
        else copyIDs.add(copy.id);
        for(const [identity,t] of targets){
          if(deletedCats.has(t.familyCatID)||removed.has(identity))continue;
          if(t.collection==='visitEntry' && removed.has(key({...t,collection:'visit',recordID:t.parentRecordID,parentRecordID:undefined})))continue;
          if(t.collection==='handoffMeal' && removed.has(key({...t,collection:'handoff',recordID:t.parentRecordID,parentRecordID:undefined})))continue;
          count++;
        }
        targets.clear();removed.clear();deletedCats.clear();
      }
      if(count>100_000)throw new Error('Too many logical items');
      drop(parent,k);
    }
    if(stack.length===1 && k===collection){
      if(found)throw new Error('Duplicate logical collection');found=true;valid &&= Array.isArray(value);
    }
  };
  return {write(bytes:Uint8Array){parser.write(bytes);},finish():number|null{
    if(!parser.isEnded)parser.end();
    return parser.isEnded && found && valid && schema===1 ? count : null;
  }};
}
