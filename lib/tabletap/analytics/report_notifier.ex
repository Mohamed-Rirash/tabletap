defmodule Tabletap.Analytics.ReportNotifier do
  @moduledoc """
  Emails a subscribed Report Center report (build-plan.md Feature 18),
  same `new()/to/from/subject` `Swoosh.Email` pattern as
  `Accounts.UserNotifier`. The report is attached as CSV
  (`Reports.Csv`, in-memory via `Swoosh.Attachment.new({:data, csv},
  ...)`) rather than linked — `Manager.Analytics.ReportsCsvController`
  requires an authenticated session cookie an email recipient won't
  have, and a signed/unauthenticated download link is out of scope for
  this pass.
  """
  import Swoosh.Email

  alias Tabletap.Mailer

  def deliver_scheduled_report(user, report_type, frequency, from_date, to_date, csv) do
    label = Phoenix.Naming.humanize(report_type)
    filename = "#{report_type}-#{from_date}-to-#{to_date}.csv"

    email =
      new()
      |> to(user.email)
      |> from({"Tabletap", "contact@example.com"})
      |> subject("Your #{frequency} #{label} report")
      |> text_body("""

      ==============================

      Hi #{user.email},

      Attached is your #{label} report for #{Date.to_string(from_date)} to #{Date.to_string(to_date)}.

      You're receiving this because you subscribed to it from the Report Center. You can manage or cancel your report subscriptions from the Reports page in Tabletap.

      ==============================
      """)
      |> attachment(
        Swoosh.Attachment.new({:data, csv}, filename: filename, content_type: "text/csv")
      )

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end
end
