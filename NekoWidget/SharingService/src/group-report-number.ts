const alphabet='0123456789ABCDEFGHJKMNPQRSTVWXYZ';
/** Display-only, 50 uniformly random bits. Never an access credential. */
export function newGroupReceiptNumber():string {
 const digits=Array.from(crypto.getRandomValues(new Uint8Array(10)),byte=>alphabet[byte&31]).join('');
 return `R-${digits.slice(0,4)}-${digits.slice(4,8)}-${digits.slice(8)}`;
}
export function isReceiptNumberCollision(error:unknown):boolean {
 return String(error).includes('UNIQUE constraint failed: group_report_numbers.receipt_number');
}
/** Older rows contain an unissued placeholder. Only the first assignment can
 * update it; concurrent readers return the same winning number. */
export async function groupReceiptNumber(db:D1Database,reportId:string):Promise<string> {
 for(let attempt=0;attempt<4;attempt++){
  const row=await db.prepare('SELECT receipt_number FROM group_report_numbers WHERE report_id=?').bind(reportId).first<{receipt_number:string|null}>();
  if(!row)throw Error('report_number_missing');if(row.receipt_number)return row.receipt_number;
  try {await db.prepare('UPDATE group_report_numbers SET receipt_number=? WHERE report_id=? AND receipt_number IS NULL').bind(newGroupReceiptNumber(),reportId).run();}
  catch(error){if(!isReceiptNumberCollision(error))throw error;}
 }
 const row=await db.prepare('SELECT receipt_number FROM group_report_numbers WHERE report_id=?').bind(reportId).first<{receipt_number:string|null}>();
 if(!row?.receipt_number)throw Error('report_number_unavailable');return row.receipt_number;
}
