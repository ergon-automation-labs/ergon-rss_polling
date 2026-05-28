import Config

config :bot_army_rss_polling, :deployment_status, "experimental"

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :logger_json, :backend, metadata: [:request_id]
