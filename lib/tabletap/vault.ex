defmodule Tabletap.Vault do
  @moduledoc """
  Encrypts per-venue wallet merchant credentials at rest (design-qa.md Q57/Q58).
  Never logged, never serialized into errors or telemetry (code-standards.md).
  """
  use Cloak.Vault, otp_app: :tabletap
end
