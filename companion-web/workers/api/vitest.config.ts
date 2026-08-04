import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: {
        configPath: "./wrangler.jsonc",
      },
      miniflare: {
        serviceBindings: {
          DAYFLOW_AUTH: () =>
            new Response(JSON.stringify({ account_id: "test-account", subject: "test-subject" }), {
              headers: { "content-type": "application/json" },
            }),
        },
      },
    }),
  ],
});
