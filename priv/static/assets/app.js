(function () {
  var meta = document.querySelector("meta[name='csrf-token']");
  var Hooks = {};

  // Turns Web Push on/off for this device and reports its state to LiveView.
  Hooks.Push = {
    mounted: function () {
      var el = this.el, self = this;

      function toKey(b64) {
        var pad = "=".repeat((4 - (b64.length % 4)) % 4);
        var raw = atob((b64 + pad).replace(/-/g, "+").replace(/_/g, "/"));
        return Uint8Array.from(raw, function (c) { return c.charCodeAt(0); });
      }

      function supported() {
        return "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
      }

      async function report() {
        if (!supported()) return self.pushEvent("push_state", { supported: false, permission: "unsupported", subscribed: false });
        var reg = await navigator.serviceWorker.ready;
        var sub = await reg.pushManager.getSubscription();
        self.pushEvent("push_state", {
          supported: true,
          permission: Notification.permission,
          subscribed: !!sub,
          endpoint: sub ? sub.endpoint : null
        });
      }

      el.addEventListener("click", async function (ev) {
        var btn = ev.target.closest("[data-push]");
        if (!btn) return;
        try {
          var reg = await navigator.serviceWorker.ready;
          if (btn.dataset.push === "enable") {
            var permission = await Notification.requestPermission();
            if (permission === "granted") {
              var sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: toKey(el.dataset.key) });
              var json = sub.toJSON();
              self.pushEvent("subscribe", { endpoint: json.endpoint, p256dh: json.keys.p256dh, auth: json.keys.auth, user_agent: navigator.userAgent });
            }
          } else if (btn.dataset.push === "disable") {
            var current = await reg.pushManager.getSubscription();
            if (current) {
              var endpoint = current.endpoint;
              await current.unsubscribe();
              self.pushEvent("unsubscribe", { endpoint: endpoint });
            }
          }
        } catch (e) { console.error("push", e); }
        report();
      });

      report();
    },
    updated: function () { /* state is re-reported after each click */ }
  };

  var liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
    hooks: Hooks,
    params: { _csrf_token: meta && meta.getAttribute("content") }
  });
  liveSocket.connect();
  window.liveSocket = liveSocket;
})();

if ("serviceWorker" in navigator) {
  window.addEventListener("load", function () {
    navigator.serviceWorker.register("/sw.js").catch(function () {});
  });
}

// Auto-lock (only when a PIN is set): after 5 idle minutes, or after the app
// has been in the background for 2 minutes. The lock screen itself is exempt.
(function () {
  if (document.body.dataset.autolock !== "true" || location.pathname.indexOf("/unlock") === 0) return;
  var IDLE = 5 * 60 * 1000, AWAY = 2 * 60 * 1000, last = Date.now(), hiddenAt = null;
  ["pointerdown", "keydown", "touchstart", "scroll"].forEach(function (e) {
    window.addEventListener(e, function () { last = Date.now(); }, { passive: true });
  });
  setInterval(function () { if (Date.now() - last > IDLE) location.href = "/lock"; }, 15000);
  document.addEventListener("visibilitychange", function () {
    if (document.hidden) { hiddenAt = Date.now(); return; }
    if (hiddenAt && Date.now() - hiddenAt > AWAY) location.href = "/lock";
    hiddenAt = null;
    last = Date.now();
  });
})();
