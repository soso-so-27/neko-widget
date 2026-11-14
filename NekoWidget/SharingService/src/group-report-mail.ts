export interface GroupReportMailEnv {
  GROUP_REPORT_EMAIL_ENABLED?: string;
  GROUP_REPORT_EMAIL_TO?: string;
  GROUP_REPORT_EMAIL_FROM?: string;
  GROUP_REPORT_EMAIL?: SendEmail;
}

// Operator configuration accepts one plain ASCII mailbox, never display names,
// address lists or header syntax. Domain/recipient verification remains the
// provider's responsibility; the binding must also restrict its destination.
function isMailbox(value: unknown): value is string {
  if (typeof value !== "string" || value.length > 254 || /[^\x21-\x7e]/.test(value)) return false;
  const parts = value.split("@");
  if (parts.length !== 2) return false;
  const [local, domain] = parts;
  if (!local || local.length > 64 || !domain) return false;
  if (!/^[A-Za-z0-9_+-]+(?:\.[A-Za-z0-9_+-]+)*$/.test(local)) return false;
  const labels = domain.split(".");
  return labels.length >= 2 && labels.every(label =>
    /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/.test(label));
}

export const operatorMailTexts = Object.freeze({
  received: '通報が 1 件届きました',
  undecided: '判断がまだの通報があります',
  warning: '保存の実測費用が警戒額に達しました',
  closed: '新しい保存の受付を閉じました',
  expired: '保存の受付または更新許可の期限が切れました',
  credentials: '費用の取得資格が拒否されました。保存の受付は閉じています',
});
export type OperatorMailKind = keyof typeof operatorMailTexts;

// Only these fixed reasons may enter a closure email. Never interpolate errors,
// provider responses, account identifiers or database values into mail.
export const intakeClosureReasons = Object.freeze({
  'cost-unavailable': '費用を安全に確認できなかったため、保存の受付を閉じました。',
  budget: '費用の見込みが停止額に達したため、保存の受付を閉じました。',
  limits: '保存の上限設定が承認済みの設定と一致しなかったため、受付を閉じました。',
  expired: '保存の受付・更新許可・安全確認のいずれかの期限が切れたため、受付を閉じました。',
  credentials: '費用を取得するための認証が拒否されたため、保存の受付を閉じました。',
  stopped: '保存の受付が停止状態になっています。記録だけでは停止した理由を特定できません。',
  unknown: '保存を続けるための安全確認が完了しませんでした。記録だけでは詳しい理由を特定できません。',
});
export type IntakeClosureReason = keyof typeof intakeClosureReasons;

/** Sends only fixed operator text. Configuration comes from Env, never a report. */
export async function sendOperatorMail(
  env: GroupReportMailEnv,
  kind: OperatorMailKind,
  reason?: IntakeClosureReason,
): Promise<void> {
  if (env.GROUP_REPORT_EMAIL_ENABLED !== "YES") {
    throw new Error("group_report_email_disabled");
  }
  if (!Object.hasOwn(operatorMailTexts, kind)) {
    throw new Error("group_report_email_invalid_kind");
  }
  const to = env.GROUP_REPORT_EMAIL_TO;
  const from = env.GROUP_REPORT_EMAIL_FROM;
  const binding = env.GROUP_REPORT_EMAIL;
  if (!isMailbox(to) || !isMailbox(from) || typeof binding?.send !== "function") {
    throw new Error("group_report_email_invalid_configuration");
  }
  const subject = operatorMailTexts[kind];
  const closure = kind === 'closed' || kind === 'expired' || kind === 'credentials';
  const selectedReason = kind === 'expired' ? 'expired' : kind === 'credentials' ? 'credentials' : reason ?? 'unknown';
  if (closure && !Object.hasOwn(intakeClosureReasons, selectedReason)) {
    throw new Error('group_report_email_invalid_reason');
  }
  const text = closure ? [
    `理由：${intakeClosureReasons[selectedReason]}`,
    '現在：新しい保存は受け付けません。保存済みの記録は消えず、戻せます。',
    '対応：続けて試す場合は、原因を確認し、持ち主の承認後に受付を開け直してください。続けない場合は、そのままで構いません。',
  ].join('\n') : subject;
  try {
    // The native structured API creates MIME. Do not forward arbitrary Env or
    // report fields, custom headers, HTML, attachments, CC or BCC.
    await binding.send({ from, to, subject, text });
  } catch {
    // Provider diagnostics may include addresses or message contents. Keep the
    // queue retryable without carrying those diagnostics into logs/status.
    throw new Error("group_report_email_delivery_failed");
  }
}

/** Report queues remain restricted to their two report kinds. */
export async function sendGroupReportMail(env: GroupReportMailEnv, kind: 'received' | 'undecided'): Promise<void> {
  if (kind !== 'received' && kind !== 'undecided') throw new Error('group_report_email_invalid_kind');
  await sendOperatorMail(env, kind);
}
