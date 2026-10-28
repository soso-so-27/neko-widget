import { describe, expect, it } from "vitest";
import { sendGroupReportMail, type GroupReportMailEnv } from "../src/group-report-mail";

function fixture(failure?: Error) {
  const messages: (EmailMessage | EmailMessageBuilder)[] = [];
  const binding: SendEmail = {
    async send(message: EmailMessage | EmailMessageBuilder): Promise<EmailSendResult> {
      messages.push(message);
      if (failure) throw failure;
      return { messageId: "synthetic-message" };
    },
  };
  const env: GroupReportMailEnv = {
    GROUP_REPORT_EMAIL_ENABLED: "YES",
    GROUP_REPORT_EMAIL_TO: "operator@example.com",
    GROUP_REPORT_EMAIL_FROM: "report-notice@notify.example.com",
    GROUP_REPORT_EMAIL: binding,
  };
  return { env, messages };
}

describe("fixed group report operator mail", () => {
  it.each([
    ["received", "通報が 1 件届きました"],
    ["undecided", "判断がまだの通報があります"],
  ] as const)("sends only the configured addresses and fixed %s text", async (kind, text) => {
    const { env, messages } = fixture();
    const withUnrelatedData = {
      ...env,
      reportId: "private-report-id",
      catName: "private-cat-name",
      windowName: "private-window-name",
      photo: "private-photo-bytes",
      subject: "untrusted subject",
      cc: "other@example.com",
      headers: { "X-Report-ID": "private-report-id" },
    };
    await expect(sendGroupReportMail(withUnrelatedData, kind)).resolves.toBeUndefined();
    // Inspect the entire argument actually passed to the native binding, not a
    // separate formatter: no HTML, attachment, link, extra recipient or header.
    expect(messages).toEqual([{
      from: "report-notice@notify.example.com",
      to: "operator@example.com",
      subject: text,
      text,
    }]);
  });

  it.each([undefined, "", "NO", "yes", "YES "])("does not send with enabled=%s", async enabled => {
    const { env, messages } = fixture();
    if (enabled === undefined) delete env.GROUP_REPORT_EMAIL_ENABLED;
    else env.GROUP_REPORT_EMAIL_ENABLED = enabled;
    await expect(sendGroupReportMail(env, "received")).rejects.toThrow("group_report_email_disabled");
    expect(messages).toHaveLength(0);
  });

  const invalidAddresses = [
    "", " operator@example.com", "operator@example.com ",
    "operator@example.com\r\nBcc: other@example.com", "operator@example.com\n",
    "operator\u0000@example.com", "operator\t@example.com", "operator\u007f@example.com",
    "Operator <operator@example.com>", "operator@example.com,other@example.com",
    "operator@example.com;other@example.com", "mailto:operator@example.com",
    "operator@@example.com", ".operator@example.com", "operator..notice@example.com",
    "operator@example", "operator@-example.com", "operator@example..com",
    "operator@例え.com", '"operator"@example.com',
    `${"a".repeat(65)}@example.com`, `operator@${"a".repeat(64)}.com`,
    `operator@${Array(5).fill("a".repeat(50)).join(".")}`,
  ];
  for (const field of ["GROUP_REPORT_EMAIL_TO", "GROUP_REPORT_EMAIL_FROM"] as const) {
    it.each(invalidAddresses)(`rejects invalid ${field}: %j before sending`, async address => {
      const { env, messages } = fixture();
      env[field] = address;
      await expect(sendGroupReportMail(env, "received")).rejects.toThrow("group_report_email_invalid_configuration");
      expect(messages).toHaveLength(0);
    });
    it(`rejects missing ${field}`, async () => {
      const { env, messages } = fixture();
      delete env[field];
      await expect(sendGroupReportMail(env, "received")).rejects.toThrow("group_report_email_invalid_configuration");
      expect(messages).toHaveLength(0);
    });
  }

  it("rejects a missing or invalid binding", async () => {
    const { env, messages } = fixture();
    delete env.GROUP_REPORT_EMAIL;
    await expect(sendGroupReportMail(env, "received")).rejects.toThrow("group_report_email_invalid_configuration");
    env.GROUP_REPORT_EMAIL = {} as SendEmail;
    await expect(sendGroupReportMail(env, "received")).rejects.toThrow("group_report_email_invalid_configuration");
    expect(messages).toHaveLength(0);
  });

  it("rejects unknown runtime kinds instead of turning them into reminders", async () => {
    const { env, messages } = fixture();
    await expect(sendGroupReportMail(env, "private report text" as "received"))
      .rejects.toThrow("group_report_email_invalid_kind");
    expect(messages).toHaveLength(0);
  });

  it("rejects delivery failure without logging provider data or retrying internally", async () => {
    const { env, messages } = fixture(new Error("provider echoed private-address@example.com"));
    await expect(sendGroupReportMail(env, "undecided")).rejects.toThrow(/^group_report_email_delivery_failed$/);
    expect(messages).toHaveLength(1);
  });

  it("waits for the binding to accept the message before resolving", async () => {
    const { env } = fixture();
    let accept!: (result: EmailSendResult) => void;
    env.GROUP_REPORT_EMAIL = { send: () => new Promise<EmailSendResult>(resolve => { accept = resolve; }) };
    let completed = false;
    const pending = sendGroupReportMail(env, "received").then(() => { completed = true; });
    await Promise.resolve();
    expect(completed).toBe(false);
    accept({ messageId: "synthetic-message" });
    await pending;
    expect(completed).toBe(true);
  });
});
