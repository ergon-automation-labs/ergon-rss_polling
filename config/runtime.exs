import Config

# Runs when the VM starts. Salt writes the bot's settings (including RSS_FEEDS_JSON) to
# /etc/bot_army/rss_polling.config.exs, not to the environment, so load that file here
# and make its values visible to ConfigLoader.get/2.
if config_env() != :test do
  config_data = BotArmyLibraryRuntime.ConfigLoader.load_config()
  Application.put_env(:bot_army_library_runtime, :config_data, config_data)
end
