defmodule SavingsChallengeWeb.Layouts do
  use SavingsChallengeWeb, :html

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
        <meta name="theme-color" content="#0f766e" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <.live_title default="52-Week Challenge">{assigns[:page_title]}</.live_title>
        <link rel="icon" href="/favicon.svg" type="image/svg+xml" />
        <link rel="stylesheet" href="/assets/app.css" />
        <script defer src="/vendor/phoenix/phoenix.min.js"></script>
        <script defer src="/vendor/live_view/phoenix_live_view.min.js"></script>
        <script defer src="/assets/app.js"></script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end
