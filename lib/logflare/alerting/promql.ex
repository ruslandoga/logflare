defmodule Logflare.Alerting.Promql do
  @moduledoc false

  alias Logflare.Alerting.AlertQuery
  alias Logflare.Backends
  alias Logflare.Backends.Adaptor.QueryResult
  alias Logflare.Backends.Adaptor.VictoriaMetricsAdaptor
  alias Logflare.Backends.Backend
  alias Logflare.Repo
  alias Logflare.TeamUsers.TeamUser
  alias Logflare.User

  @max_results 1000

  @spec fetch_backend(integer() | nil, integer() | nil, keyword()) ::
          {:ok, Backend.t()} | {:error, String.t()}
  def fetch_backend(user_id, backend_id, opts \\ [])

  def fetch_backend(user_id, backend_id, opts)
      when is_integer(user_id) and is_integer(backend_id) do
    with %User{} = user <- Repo.get(User, user_id),
         %Backend{type: :victoria_metrics, config: %{query_url: url}} = backend <-
           Backends.get_backend_by_user_access(user, backend_id),
         true <- is_binary(url) and String.trim(url) != "",
         :ok <- authorize_actor(Keyword.get(opts, :actor), backend_id) do
      {:ok, backend}
    else
      _ -> {:error, "must be an accessible VictoriaMetrics backend with a query URL"}
    end
  end

  def fetch_backend(_user_id, _backend_id, _opts) do
    {:error, "must be an accessible VictoriaMetrics backend with a query URL"}
  end

  defp authorize_actor(nil, _backend_id), do: :ok

  defp authorize_actor(%module{id: id}, backend_id)
       when module in [User, TeamUser] and is_integer(id) do
    with %{} = actor <- Repo.get(module, id),
         %Backend{} <- Backends.get_backend_by_user_access(actor, backend_id) do
      :ok
    else
      _ -> :error
    end
  end

  defp authorize_actor(_actor, _backend_id), do: :error

  @spec execute(AlertQuery.t(), keyword()) :: {:ok, QueryResult.t()} | {:error, map()}
  def execute(%AlertQuery{} = alert, opts) do
    with {:ok, time} <- evaluation_time(alert.evaluation_delay_seconds, opts),
         {:ok, backend} <- fetch_backend(alert.user_id, alert.query_backend_id, opts),
         {:ok, response} <-
           VictoriaMetricsAdaptor.execute_promql(backend, alert.query, %{"time" => time}) do
      decode_response(response)
    else
      {:error, {status, response}} ->
        {:error, response |> Map.take(["errorType", "error"]) |> Map.put("status", status)}

      {:error, message} when is_binary(message) ->
        error(422, "invalid_backend", message)

      {:error, %{} = error} ->
        {:error, error}
    end
  end

  defp evaluation_time(delay, opts) when is_integer(delay) and delay >= 0 and delay <= 86_400 do
    time = Keyword.get_lazy(opts, :evaluation_time, &DateTime.utc_now/0)
    {:ok, time |> DateTime.add(-delay, :second) |> DateTime.to_iso8601()}
  end

  defp evaluation_time(_delay, _opts) do
    error(422, "bad_data", "Evaluation delay must be an integer between 0 and 86400 seconds")
  end

  defp decode_response(%{"data" => %{"resultType" => "vector", "result" => samples}})
       when is_list(samples) and length(samples) > @max_results do
    error(
      422,
      "result_limit",
      "PromQL alerts support at most #{@max_results} results; filter or aggregate the query"
    )
  end

  defp decode_response(%{"data" => %{"resultType" => "vector", "result" => samples}} = response)
       when is_list(samples) do
    samples
    |> Enum.reduce_while({:ok, []}, fn sample, {:ok, rows} ->
      case decode_sample(sample) do
        {:ok, row} -> {:cont, {:ok, [row | rows]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> result(Enum.reverse(rows), response)
      error -> error
    end
  end

  defp decode_response(%{"data" => %{"resultType" => "scalar", "result" => value}} = response) do
    case decode_sample(%{"metric" => %{}, "value" => value}) do
      {:ok, row} -> result([row], response)
      error -> error
    end
  end

  defp decode_response(_response) do
    error(502, "bad_response", "PromQL alerts require an instant vector or scalar result")
  end

  defp decode_sample(%{"histogram" => _histogram}) do
    error(422, "unsupported_result", "PromQL alerts do not support native histogram samples")
  end

  defp decode_sample(%{"metric" => labels, "value" => [timestamp, value]})
       when is_map(labels) and is_number(timestamp) and is_binary(value) do
    if Enum.all?(labels, fn {key, value} -> is_binary(key) and is_binary(value) end) and
         valid_value?(value) do
      {:ok, %{"labels" => labels, "timestamp" => timestamp, "value" => value}}
    else
      error(502, "bad_response", "VictoriaMetrics returned an invalid PromQL sample")
    end
  end

  defp decode_sample(_sample) do
    error(502, "bad_response", "VictoriaMetrics returned an invalid PromQL sample")
  end

  defp valid_value?(value) when value in ["NaN", "+Inf", "-Inf", "Inf"], do: true
  defp valid_value?(value), do: match?({_number, ""}, Float.parse(value))

  defp result(rows, response) do
    warnings = Map.get(response, "warnings", [])

    if is_list(warnings) and Enum.all?(warnings, &is_binary/1) do
      {:ok, QueryResult.new(rows, %{warnings: warnings})}
    else
      error(502, "bad_response", "VictoriaMetrics returned invalid PromQL warnings")
    end
  end

  defp error(status, type, message) do
    {:error, %{"status" => status, "errorType" => type, "error" => message}}
  end
end
