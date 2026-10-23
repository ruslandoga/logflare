defmodule LogflareWeb.Plugs.OtlpErrorResponse do
  @moduledoc """
  Encodes OTLP pipeline failures using the request's protobuf or JSON format.
  """

  @behaviour Plug

  import Plug.Conn

  alias Google.Rpc.Status
  alias Plug.Conn.Utils, as: ConnUtils

  @impl true
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl true
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts), do: register_before_send(conn, &encode_error/1)

  @spec status(non_neg_integer(), binary()) :: Status.t()
  def status(http_status, message) do
    %Status{code: status_code(http_status), message: message}
  end

  @spec encode_error(Plug.Conn.t()) :: Plug.Conn.t()
  defp encode_error(%{private: %{otlp_response_encoded: true}} = conn), do: conn

  defp encode_error(%{status: http_status} = conn) when http_status >= 400 do
    response = status(http_status, error_message(conn))

    {content_type, body} =
      case get_req_header(conn, "content-type") do
        [content_type | _] -> encode(response, ConnUtils.media_type(content_type))
        [] -> encode(response, :error)
      end

    conn
    |> put_resp_content_type(content_type)
    |> delete_resp_header("content-length")
    |> delete_resp_header("content-encoding")
    |> Map.put(:resp_body, body)
  end

  defp encode_error(conn), do: conn

  @spec encode(Status.t(), term()) :: {binary(), iodata()}
  defp encode(response, {:ok, "application", "json", _params}),
    do: {"application/json", Protobuf.JSON.encode!(response)}

  defp encode(response, _content_type),
    do: {"application/x-protobuf", Protobuf.encode_to_iodata(response)}

  @spec error_message(Plug.Conn.t()) :: binary()
  defp error_message(conn) do
    case Jason.decode(conn.resp_body || "") do
      {:ok, %{"error" => message}} when is_binary(message) -> message
      {:ok, %{"message" => message}} when is_binary(message) -> message
      _ -> Plug.Conn.Status.reason_phrase(conn.status)
    end
  end

  @spec status_code(non_neg_integer()) :: non_neg_integer()
  defp status_code(400), do: 3
  defp status_code(401), do: 16
  defp status_code(403), do: 7
  defp status_code(404), do: 5
  defp status_code(413), do: 8
  defp status_code(429), do: 8
  defp status_code(500), do: 13
  defp status_code(503), do: 14
  defp status_code(_http_status), do: 2
end
