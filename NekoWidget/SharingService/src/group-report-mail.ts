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

/** Sends only fixed operator text. Configuration comes from Env, never a report. */
export async function sendGroupReportMail(
  env: GroupReportMailEnv,
  kind: OperatorMailKind,
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
  const text = operatorMailTexts[kind];
  try {
    // The native structured API creates MIME. Do not forward arbitrary Env or
    // report fields, custom headers, HTML, attachments, CC or BCC.
    await binding.send({ from, to, subject: text, text });
  } catch {
    // Provider diagnostics may include addresses or message contents. Keep the
    // queue retryable without carrying those diagnostics into logs/status.
    throw new Error("group_report_email_delivery_failed");
  }
}
