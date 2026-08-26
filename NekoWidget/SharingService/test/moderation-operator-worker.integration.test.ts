import { describe, expect, it } from "vitest";

import moderationOperatorWorker, {
  routeModerationOperatorRequest,
  type ModerationOperatorWorkerEnv,
} from "../src/moderation-operator-worker";

async function expectError(
  response: Response,
  status: number,
  code: string,
): Promise<void> {
  expect(response.status).toBe(status);
  expect(response.headers.get("cache-control")).toBe("no-store");
  expect(response.headers.get("content-type")).toBe("application/json; charset=utf-8");
  expect(response.headers.get("x-content-type-options")).toBe("nosniff");
  expect(await response.json()).toEqual({ error: { code } });
}

describe("isolated moderation operator worker shell", () => {
  it("returns one disabled response for the operator namespace without touching protected inputs", async () => {
    const observed: string[] = [];
    const originalRequest = new Request(
      "https://operator.invalid/operator/v1/cases?access_token=query-secret&duplicate=1&duplicate=2",
      {
        method: "POST",
        headers: {
          "Cf-Access-Jwt-Assertion": "access-secret",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ secret: "body-secret" }),
      },
    );
    const request = new Proxy(originalRequest, {
      get(target, property) {
        if (property === "url") {
          observed.push("request.url");
          return target.url;
        }
        throw new Error(`request property must not be read while disabled: ${String(property)}`);
      },
    });
    const env = new Proxy(
      { OPERATOR_RUNTIME_ENABLED: "NO" } as ModerationOperatorWorkerEnv,
      {
        get(target, property, receiver) {
          if (property === "OPERATOR_RUNTIME_ENABLED") {
            observed.push("env.OPERATOR_RUNTIME_ENABLED");
            return Reflect.get(target, property, receiver);
          }
          throw new Error(`binding must not be read while disabled: ${String(property)}`);
        },
      },
    );

    const response = moderationOperatorWorker.fetch(
      request as unknown as Parameters<typeof moderationOperatorWorker.fetch>[0],
      env,
    );
    const responseCopy = response.clone();

    expect(observed).toEqual(["request.url", "env.OPERATOR_RUNTIME_ENABLED"]);
    await expectError(response, 503, "operator_runtime_disabled");
    expect(await responseCopy.text()).not.toContain("secret");
  });

  it("treats every value other than exact YES as disabled", async () => {
    const invalidValues: unknown[] = [
      undefined,
      null,
      "",
      "NO",
      "yes",
      "Yes",
      "TRUE",
      "1",
      " YES",
      "YES ",
      { toString: () => "YES" },
    ];

    for (const value of invalidValues) {
      const response = routeModerationOperatorRequest(
        new Request("https://operator.invalid/operator/v1"),
        { OPERATOR_RUNTIME_ENABLED: value } as unknown as ModerationOperatorWorkerEnv,
      );
      await expectError(response, 503, "operator_runtime_disabled");
    }
  });

  it("covers the operator root and descendants independent of method and query", async () => {
    for (const [path, method] of [
      ["/operator/v1", "GET"],
      ["/operator/v1/", "HEAD"],
      ["/operator/v1/cases", "DELETE"],
      ["/operator/v1/cases?unknown=%ZZ", "POST"],
    ] as const) {
      const response = routeModerationOperatorRequest(
        new Request(`https://operator.invalid${path}`, { method }),
        { OPERATOR_RUNTIME_ENABLED: "NO" },
      );
      await expectError(response, 503, "operator_runtime_disabled");
    }
  });

  it("does not expose public-worker or lookalike paths", async () => {
    for (const path of [
      "/health",
      "/v1/spaces",
      "/v2/moments",
      "/operator",
      "/operator/v10",
      "/operator/v1-cases",
      "/operator/v1%2Fcases",
    ]) {
      const env = new Proxy(
        {} as ModerationOperatorWorkerEnv,
        {
          get(_target, property) {
            throw new Error(`runtime binding must not be read outside operator API: ${String(property)}`);
          },
        },
      );
      const response = routeModerationOperatorRequest(
        new Request(`https://operator.invalid${path}`),
        env,
      );
      await expectError(response, 404, "not_found");
    }
  });

  it("keeps every operator operation unavailable when the shell is enabled", async () => {
    for (const path of [
      "/operator/v1",
      "/operator/v1/cases",
      "/operator/v1/evidence/export",
    ]) {
      const response = routeModerationOperatorRequest(
        new Request(`https://operator.invalid${path}`, {
          headers: { "Cf-Access-Jwt-Assertion": "not-yet-consumed" },
        }),
        { OPERATOR_RUNTIME_ENABLED: "YES" },
      );
      await expectError(response, 503, "operator_runtime_not_ready");
    }
  });
});
