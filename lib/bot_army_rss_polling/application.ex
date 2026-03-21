defmodule BotArmyRssPolling.Application do
  @moduledoc """
  BotArmyRssPolling application supervisor.

  Manages RSS polling bot services:
  - RSS feed poller (GenServer)
  - Feed deduplication filter (ETS)
  - NATS publisher
  """

  use Application

  @env Mix.env()

  @impl true
  def start(_type, _args) do
    children = []
    |> maybe_add_dedup_filter()
    |> maybe_add_poller()

    opts = [strategy: :one_for_one, name: BotArmyRssPolling.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_dedup_filter(children) do
    if @env == :test, do: children, else: [{BotArmyRssPolling.DedupFilter, []} | children]
  end

  defp maybe_add_poller(children) do
    if @env == :test, do: children, else: [{BotArmyRssPolling.Poller, []} | children]
  end
end
