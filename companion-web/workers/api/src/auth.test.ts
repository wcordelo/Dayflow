import { describe, expect, it } from "vitest";
import { authenticateRequest } from "./auth";

describe("canonical Dayflow auth binding", () => {
  it("uses /v1/me, derives the account from the user, and never forwards the sync body", async () => {
    const requests: Request[] = [];
    const authService = {
      fetch: async (request: Request) => {
        requests.push(request);
        return new Response(JSON.stringify({ user: { id: "account-from-me" } }), {
          headers: { "content-type": "application/json" },
        });
      },
    } as unknown as Fetcher;

    const principal = await authenticateRequest(
      new Request("https://relay.example/v1/sync/events?cursor=secret", {
        method: "POST",
        headers: {
          Authorization: "Bearer test-token",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ envelopes: [{ ciphertext: "opaque" }] }),
      }),
      authService,
    );

    expect(principal).toEqual({ account_id: "account-from-me", subject: "account-from-me" });
    expect(requests).toHaveLength(1);
    expect(requests[0]?.url).toBe("https://relay.example/v1/me");
    expect(requests[0]?.method).toBe("GET");
    expect(await requests[0]?.text()).toBe("");
    expect(requests[0]?.headers.get("Authorization")).toBe("Bearer test-token");
    expect(requests[0]?.headers.get("X-Dayflow-Auth-Purpose")).toBe("sync-relay");
  });

  it("accepts the existing relay identity adapter response", async () => {
    const authService = {
      fetch: async () => new Response(
        JSON.stringify({ account_id: "adapter-account", subject: "session-subject" }),
        { headers: { "content-type": "application/json" } },
      ),
    } as unknown as Fetcher;

    await expect(authenticateRequest(
      new Request("https://relay.example/v1/sync/devices", {
        headers: { Authorization: "Bearer test-token" },
      }),
      authService,
    )).resolves.toEqual({ account_id: "adapter-account", subject: "session-subject" });
  });
});
