/** Synthetic reconstructible work only; no save acknowledgement or authority. */
export async function insertOwnerWork(db: D1Database, ownerId: string): Promise<void> {
  const workId = crypto.randomUUID();
  await db.prepare(`INSERT INTO pa_tool_metadata_batches(owner_id,batch_id,batch_nonce,owner_epoch,manifest_json,state,created_at)
    VALUES(?,?,?,1,'{}','open',1)`).bind(ownerId, crypto.randomUUID(),crypto.randomUUID()).run();
  await db.prepare(`INSERT INTO pa_owner_delta_work(owner_id,work_id,generation,inventory_generation,
    record_sequence,record_count,plan_json,plan_mac) VALUES(?,?,1,0,0,0,'{}',?)`)
    .bind(ownerId, workId, 'a'.repeat(64)).run();
  await db.prepare(`INSERT INTO pa_owner_delta_nodes(owner_id,work_id,step_id,object_key,ciphertext)
    VALUES(?,?,?,?,?)`).bind(ownerId, workId, 'synthetic-step', `recovery/v1/${ownerId}/tree/synthetic`,
      new Uint8Array([1, 2, 3]).buffer).run();
}
