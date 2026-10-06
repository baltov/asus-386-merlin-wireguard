import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: ".",
  testMatch: "page.spec.mjs",
  workers: 1,
  fullyParallel: false,
  timeout: 30000,
  reporter: "list",
  use: { baseURL: "http://127.0.0.1:8099", ignoreHTTPSErrors: true, browserName: "chromium" },
  webServer: {
    command: "node serve.mjs",
    url: "http://127.0.0.1:8099/user1.asp",
    reuseExistingServer: false,
    timeout: 20000,
  },
});
