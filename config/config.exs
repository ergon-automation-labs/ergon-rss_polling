import Config

config :bot_army_rss_polling, :deployment_status, "experimental"

config :logger,
  level: :info,
  backends: [:console]

config :logger, :console,
  format: {BotArmyRuntime.LoggerFormatter, []},
  metadata: [:correlation_id]
config :logger,
  level: :info,
  backends: [:console]

config :logger, :console,
  format: {BotArmyRuntime.LoggerFormatter, []},
  metadata: [:correlation_id]