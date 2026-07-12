defmodule TabletapWeb.LocalUploadController do
  @moduledoc """
  The write side of `Tabletap.Storage.Local` — accepts a raw file body
  and writes it under `priv/static/uploads`, standing in for a real
  presigned S3 PUT when no Supabase project is configured. Outside the
  `:browser` pipeline deliberately: a real presigned S3 URL has no
  session or CSRF token either, so this mirrors that shape instead of
  faking one.
  """
  use TabletapWeb, :controller

  # Matches the LiveView upload's own max_file_size (menu_live.ex).
  @max_bytes 6_000_000

  def put(conn, %{"path" => path_segments}) do
    with {:ok, safe_path} <- safe_path(path_segments),
         {:ok, body, conn} <- Plug.Conn.read_body(conn, length: @max_bytes) do
      full_path = Path.join(uploads_dir(), safe_path)
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, body)
      send_resp(conn, 200, "")
    else
      _ -> send_resp(conn, 400, "")
    end
  end

  defp safe_path(segments) do
    if Enum.any?(segments, &(&1 in [".", ".."])) do
      {:error, :unsafe_path}
    else
      {:ok, Path.join(segments)}
    end
  end

  defp uploads_dir, do: Path.join(:code.priv_dir(:tabletap), "static/uploads")
end
