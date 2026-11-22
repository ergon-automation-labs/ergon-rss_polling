defmodule BotArmyRssPolling.Triggers.DateNight.Para do
  @moduledoc false

  @timeout 10_000

  def read(path) do
    "para.fs.read"
    |> BotArmyLibraryRuntime.NATS.Publisher.request(
      %{"schema_version" => "1.0", "relative_path" => path},
      timeout: @timeout
    )
    |> read_reply()
  end

  def write(path, content) do
    "para.fs.write"
    |> BotArmyLibraryRuntime.NATS.Publisher.request(
      %{
        "schema_version" => "1.0",
        "relative_path" => path,
        "content" => content,
        "mode" => "write"
      },
      timeout: @timeout
    )
    |> write_reply()
  end

  # The door answers a missing file as a validation_error saying "path is not a file" (captured
  # 2026-11-22). That one refusal is :not_found; every other failure is an error, so a read that
  # failed for another reason can never be taken for an empty note and overwrite it.
  @doc false
  def read_reply({:ok, %{"ok" => true, "data" => %{"content" => content}}})
      when is_binary(content),
      do: {:ok, content}

  def read_reply(
        {:ok, %{"ok" => false, "code" => "validation_error", "error" => "path is not a file"}}
      ),
      do: {:error, :not_found}

  def read_reply({:ok, %{"ok" => false, "error" => reason}}), do: {:error, reason}
  def read_reply({:ok, other}), do: {:error, {:unexpected_reply, other}}
  def read_reply({:error, reason}), do: {:error, reason}

  @doc false
  def write_reply({:ok, %{"ok" => true}}), do: :ok
  def write_reply({:ok, %{"ok" => false, "error" => reason}}), do: {:error, reason}
  def write_reply({:ok, other}), do: {:error, {:unexpected_reply, other}}
  def write_reply({:error, reason}), do: {:error, reason}
end
