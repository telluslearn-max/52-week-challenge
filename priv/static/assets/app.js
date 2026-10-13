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
