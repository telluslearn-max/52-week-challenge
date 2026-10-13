(function () {
  var meta = document.querySelector("meta[name='csrf-token']");
  var liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
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
