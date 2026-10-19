defmodule LogflareWeb.MonacoEditorComponent do
  @moduledoc """
  Provides a Monaco Editor component for creating SQL and PromQL queries.

  Expects following attributes:
    - `field`: a `Phoenix.HTML.FormField` for the query.
    - `endpoints`: A list of endpoints, used for validating LQL queries and completions.
    - `alerts`: A list of alerts, used for validating LQL queries and completions.
    - `sources`: A list of sources, used for completions.
    - `id`: A unique identifier for the editor.
    - `language`: Query language, defaults to `:bq_sql`. PromQL uses plain-text editing.
    - `on_query_change`: Optional function to be called when the query changes.

  ## Example

        <.live_component module={LogflareWeb.MonacoEditorComponent}
          id="endpoint_query"
          field={f[:query]}
          endpoints={@endpoints}
          alerts={@alerts}
          sources={@sources}
          on_query_change={fn query_string -> send(self(), {:query_string_updated, query_string}) end}
          />
  """

  use LogflareWeb, :live_component

  alias Logflare.Sql

  def mount(socket) do
    {:ok,
     assign(socket,
       parse_error_message: nil,
       on_query_change: nil,
       query: nil,
       language: :bq_sql
     )}
  end

  def update(assigns, socket) do
    language = Map.get(assigns, :language, :bq_sql)

    socket =
      if language != socket.assigns.language do
        socket
        |> assign(:parse_error_message, nil)
        |> LiveMonacoEditor.change_language(editor_language(language), to: "query_string")
      else
        socket
      end

    # only use field if not first mount
    assigns_query = socket.assigns.query

    query =
      case assigns do
        %{field: %{value: query}} when assigns_query == nil -> query
        _ -> assigns_query || ""
      end

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:query, query)
     |> assign_completions()}
  end

  def render(assigns) do
    assigns = assign(assigns, editor_opts: editor_opts(assigns.language))

    ~H"""
    <div id={@id}>
      <.support_scripts completions={@completions} id={@field.id <> "_completions"} />
      <LiveMonacoEditor.code_editor value={@field.value} target={@myself} change="parse-query" path="query_string" phx-format={JS.hide()} id={"#{@id}_lme"} opts={@editor_opts} />
      <div :if={@language != :promql} class="tw-flex tw-justify-end">
        <button type="button" class="btn btn-secondary tw-mr-0 tw-mt-2" phx-click={JS.dispatch("editor:format", to: "#" <> @id)}>
          Format
        </button>
      </div>

      {hidden_input(@field.form, :query, value: @query)}
      {error_tag(@field.form, :query)}
      <.alert :if={@language != :promql and @parse_error_message} variant="warning">
        <strong>SQL Parse error!</strong>
        <br />
        <span>{@parse_error_message}</span>
      </.alert>
    </div>
    """
  end

  attr :completions, :list, required: true, examples: [["source_name", "logs"]]
  attr :id, :string, required: true

  def support_scripts(assigns) do
    ~H"""
    <script phx-update="ignore" id={@id}>
      window.addEventListener("lme:editor_mounted", (event) => {
        const hook = event.detail.hook;
        const editor = event.detail.editor.standalone_code_editor;

        window.addEventListener("editor:format", ev => {
          const value = editor.getValue();
          hook.pushEventTo(ev.target, "format-query", { value: value });
        })

        const completions = <%= Jason.encode!(@completions, escape: :html_safe) |> raw() %>

        if (completions.length == 0) { return; }

        function createDependencyProposals(range) {
          return completions.map(function (name) {
            return {
              label: name,
              kind: monaco.languages.CompletionItemKind.Module,
              insertText: name,
              range: range,
            };
          });
        }

        monaco.languages.registerCompletionItemProvider("sql", {
          provideCompletionItems: function (model, position) {
            var word = model.getWordUntilPosition(position);
            var range = {
              startLineNumber: position.lineNumber,
              endLineNumber: position.lineNumber,
              startColumn: word.startColumn,
              endColumn: word.endColumn,
            };

            return {
              suggestions: createDependencyProposals(range),
            };
          },
        });
      });
    </script>
    """
  end

  def handle_event("format-query", _params, %{assigns: %{language: :promql}} = socket) do
    {:noreply, socket}
  end

  def handle_event("format-query", %{"value" => value}, socket) do
    {:ok, formatted} = Sql.format(value)
    {:noreply, socket |> LiveMonacoEditor.set_value(formatted, to: "query_string")}
  end

  def handle_event("parse-query", %{"value" => query}, socket) do
    %{endpoints: endpoints, alerts: alerts, language: language} = socket.assigns

    if is_function(socket.assigns.on_query_change) do
      socket.assigns.on_query_change.(query)
    end

    field = socket.assigns.field |> Map.put(:value, query)

    parse_result = if language == :promql, do: :ok, else: parse_query(query, endpoints, alerts)

    socket =
      case parse_result do
        :ok ->
          assign(socket, parse_error_message: nil)

        {:error, message} ->
          assign(socket, parse_error_message: message)
      end
      |> assign(:query, query)
      |> assign(:field, field)

    {:noreply, socket}
  end

  def handle_event("parse-query", %{"_target" => ["live_monaco_editor", _]}, socket) do
    # ignore change events from the editor field
    {:noreply, socket}
  end

  @spec parse_query(String.t(), [%Logflare.Endpoints.EndpointQuery{}], [
          %Logflare.Alerting.AlertQuery{}
        ]) ::
          :ok | {:error, String.t()}
  def parse_query("", _endpoints, _alerts), do: :ok

  def parse_query(query_string, endpoints, alerts) do
    case Logflare.Endpoints.parse_query_string(
           :bq_sql,
           query_string,
           endpoints,
           Enum.reject(alerts, &(Map.get(&1, :language) == :promql))
         ) do
      {:ok, _} ->
        :ok

      {:error, "sql parser error: " <> message} ->
        {:error, message}

      {:error, err} ->
        message = if(is_binary(err), do: err, else: inspect(err))
        {:error, message}
    end
  end

  defp assign_completions(socket) do
    %{endpoints: endpoints, alerts: alerts, sources: sources} = socket.assigns

    completions =
      [sources, endpoints, Enum.reject(alerts, &(Map.get(&1, :language) == :promql))]
      |> List.flatten()
      |> Enum.map(fn item -> item.name end)

    assign(socket, completions: completions)
  end

  @spec editor_language(atom()) :: String.t()
  defp editor_language(:promql), do: "plaintext"
  defp editor_language(_language), do: "sql"

  defp editor_opts(language) do
    Map.merge(
      LiveMonacoEditor.default_opts(),
      %{
        "wordWrap" => "on",
        "language" => editor_language(language),
        "fontSize" => 12,
        "padding" => %{
          "top" => 14,
          "bottom" => 14
        },
        "contextmenu" => false,
        "hideCursorInOverviewRuler" => true,
        "smoothScrolling" => true,
        "scrollbar" => %{
          "vertical" => "auto",
          "horizontal" => "hidden",
          "verticalScrollbarSize" => 6,
          "alwaysConsumeMouseWheel" => false
        },
        "lineNumbers" => "off",
        "glyphMargin" => false,
        "lineNumbersMinChars" => 0,
        "folding" => false,
        "roundedSelection" => true,
        "minimap" => %{
          "enabled" => false
        }
      }
    )
  end
end
