import type { Env } from './env';
import { ApiError } from './errors';

export interface GroupModerationScope {
  spaceId?:string|undefined; senderPersonId?:string|undefined; momentId?:string|undefined; actorPersonId?:string|undefined;
}
export function groupModerationChecks(env:Env,scope:GroupModerationScope):D1PreparedStatement[] {
  if(env.GROUP_MODERATION_RUNTIME_ENABLED!=='YES')return [];
  if(!scope.spaceId && !scope.momentId)throw new Error('A group moderation scope is required');
  const id=crypto.randomUUID();
  return [env.DB.prepare(`INSERT INTO group_moderation_checks VALUES (?,
    COALESCE(?,(SELECT space_id FROM group_moments WHERE id=?)),?,?,?)`)
    .bind(id,scope.spaceId??null,scope.momentId??null,scope.senderPersonId??null,scope.momentId??null,scope.actorPersonId??null),
    env.DB.prepare('DELETE FROM group_moderation_checks WHERE id=?').bind(id)];
}
export async function requireGroupMediaAllowed(env:Env,scope:GroupModerationScope):Promise<void> {
  const statements=groupModerationChecks(env,scope);if(statements.length===0)return;
  try { await env.DB.batch(statements); }
  catch(error) {
    if(String(error).includes('group_moderation_restricted'))
      throw new ApiError(404,'group_moderation_restricted','The group photo is not available.');
    // Runtime ON with a missing migration is an error, never an implicit allow.
    throw error;
  }
}

/** Trusted SQL column references only. Values remain bound by the caller.
 * A person restriction concerns their outgoing content in this space; being
 * the recipient alone never makes another person's content unavailable. */
export function groupModerationPredicate(env:Env,columns:{space:string;photo:string;actor?:string}):string {
  if(env.GROUP_MODERATION_RUNTIME_ENABLED!=='YES')return '1';
  for(const column of Object.values(columns))if(!/^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$/u.test(column))
    throw new Error('Use trusted qualified group moderation columns');
  return `NOT EXISTS (SELECT 1 FROM group_moderation_restrictions restriction
    WHERE restriction.active=1 AND restriction.space_id=${columns.space} AND (
      (restriction.target_kind='window' AND restriction.target_id=${columns.space})
      OR (restriction.target_kind='photo' AND restriction.target_id=${columns.photo})
      OR (restriction.target_kind='person' AND (restriction.target_id=(
        SELECT sender.person_id FROM group_moments source JOIN group_members sender
          ON sender.participant_id=source.sender_participant_id AND sender.space_id=source.space_id
        WHERE source.id=${columns.photo} AND source.space_id=${columns.space})
        ${columns.actor?`OR restriction.target_id=${columns.actor}`:''}))
    ))`;
}
