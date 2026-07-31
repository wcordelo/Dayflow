/// <reference lib="webworker" />
import { clientsClaim } from "workbox-core";
import { precacheAndRoute } from "workbox-precaching";

declare let self: ServiceWorkerGlobalScope;

clientsClaim();
precacheAndRoute(self.__WB_MANIFEST);

self.addEventListener("push", (event) => {
  let title = "Companion";
  let body = "Time for a gentle check-in.";
  let kind = "chime";
  try {
    const raw = event.data?.text() ?? "";
    const parsed = JSON.parse(raw) as { title?: string; body?: string; kind?: string };
    if (parsed.title) title = parsed.title;
    if (parsed.body) body = parsed.body;
    if (parsed.kind) kind = parsed.kind;
  } catch {
    /* use defaults */
  }
  event.waitUntil(
    self.registration.showNotification(title, {
      body,
      data: { kind },
      tag: `companion-${kind}`,
    }),
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = "/";
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clientList) => {
      for (const client of clientList) {
        if ("focus" in client) return client.focus();
      }
      if (self.clients.openWindow) return self.clients.openWindow(url);
    }),
  );
});
