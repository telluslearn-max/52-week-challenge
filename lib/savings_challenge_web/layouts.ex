defmodule SavingsChallengeWeb.Layouts do
  use SavingsChallengeWeb, :html

  # A fingerprint of each static file, so a phone never mixes new HTML with old CSS/JS.
  @asset_dir Path.expand("../../priv/static/assets", __DIR__)
  for f <- ~w(app.css app.js), do: @external_resource(Path.join(@asset_dir, f))

  @asset_v Map.new(~w(app.css app.js), fn f ->
             hash = @asset_dir |> Path.join(f) |> File.read!() |> then(&:crypto.hash(:md5, &1)) |> Base.encode16(case: :lower) |> binary_part(0, 10)
             {f, hash}
           end)

  defp asset(file), do: "/assets/#{file}?v=#{Map.fetch!(@asset_v, file)}"

  # Light is the default; the sun/moon button switches and remembers it on this device.
  @theme_js ~S[(function(){var t="light";try{t=localStorage.getItem("w52-theme")||"light"}catch(e){}document.documentElement.setAttribute("data-theme",t)})();]

  def root(assigns) do
    assigns = assign(assigns, :theme_js, @theme_js)

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
        <meta name="theme-color" content="#0f766e" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <script><%= Phoenix.HTML.raw(@theme_js) %></script>
        <.live_title default="52-Week Challenge">{assigns[:page_title]}</.live_title>
        <meta name="mobile-web-app-capable" content="yes" />
        <meta name="apple-mobile-web-app-capable" content="yes" />
        <meta name="apple-mobile-web-app-title" content="52 Weeks" />
        <meta name="apple-mobile-web-app-status-bar-style" content="default" />
        <link rel="manifest" href="/manifest.webmanifest" />
        <link rel="icon" href="/favicon.svg" type="image/svg+xml" />
        <link rel="apple-touch-icon" href="/apple-touch-icon.png" />
        <link rel="stylesheet" href={asset("app.css")} />
        <script defer src="/vendor/phoenix/phoenix.min.js"></script>
        <script defer src="/vendor/live_view/phoenix_live_view.min.js"></script>
        <script defer src={asset("app.js")}></script>
      </head>
      <body data-autolock={to_string(assigns[:autolock] || false)}>
        {@inner_content}
      </body>
    </html>
    """
  end

  attr :active, :atom, required: true
  attr :lock_href, :string, default: "/lock"

  @doc "Bottom tab bar shared by the home and reminders screens."
  def bottom_nav(assigns) do
    ~H"""
    <nav class="tabbar" aria-label="Main">
      <.link navigate="/" class={["tab", @active == :home && "on"]} aria-label="Home">
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 11l9-7 9 7v9a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z" /></svg>
      </.link>
      <.link navigate="/goals/new" class={["tab", @active == :new && "on"]} aria-label="New goal">
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5v14M5 12h14" /></svg>
      </.link>
      <.link navigate="/reminders" class={["tab", @active == :reminders && "on"]} aria-label="Reminders">
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 17V11a6 6 0 0 1 12 0v6l2 2H4zM10 21h4" /></svg>
      </.link>
      <a href={@lock_href} class="tab" aria-label="Lock">
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 11V8a5 5 0 0 1 10 0v3M5 11h14v10H5z" /></svg>
      </a>
    </nav>
    """
  end
end
