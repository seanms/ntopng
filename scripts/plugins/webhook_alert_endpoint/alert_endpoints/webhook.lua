--
-- (C) 2018 - ntop.org
--

require "lua_utils"
local json = require "dkjson"

local webhook = {
   conf_params = {
      { param_name = "webhook_url" },
      { param_name = "webhook_sharedsecret", optional = true },
      { param_name = "webhook_username", optional = true },
      { param_name = "webhook_password", optional = true },
      -- TODO: configure severity (Errors, Errors and Warnings, All)
   },
   conf_template = {
      plugin_key = "webhook_alert_endpoint",
      template_name = "webhook_endpoint.template"
   },
   recipient_params = {
   },
   recipient_template = {
      plugin_key = "webhook_alert_endpoint",
      template_name = "webhook_recipient.template" -- TODO: add template
   },
}

webhook.EXPORT_FREQUENCY = 60
webhook.API_VERSION = "0.2"
webhook.REQUEST_TIMEOUT = 1
webhook.ITERATION_TIMEOUT = 3
webhook.prio = 400
local MAX_ALERTS_PER_REQUEST = 10

-- ##############################################

local function recipient2sendMessageSettings(recipient)
  local settings = {
    url = recipient.endpoint_conf.endpoint_conf.webhook_url,
    sharedsecret = recipient.endpoint_conf.endpoint_conf.webhook_sharedsecret,
    username = recipient.endpoint_conf.endpoint_conf.webhook_username,
    password = recipient.endpoint_conf.endpoint_conf.webhook_password,
  }

  return settings
end

-- ##############################################

function webhook.sendMessage(alerts, settings)
  if isEmptyString(settings.url) then
    return false
  end

  local message = {
    version = webhook.API_VERSION,
    sharedsecret = settings.sharedsecret,
    alerts = alerts,
  }

  local json_message = json.encode(message)

  local rc = false
  local retry_attempts = 3
  while retry_attempts > 0 do
    if ntop.postHTTPJsonData(settings.username, settings.password, settings.url, json_message, webhook.REQUEST_TIMEOUT) then 
      rc = true
      break 
    end
    retry_attempts = retry_attempts - 1
  end

  return rc
end

-- ##############################################

function webhook.dequeueRecipientAlerts(recipient, budget)
  local start_time = os.time()
  local sent = 0
  local more_available = true

  local settings = recipient2sendMessageSettings(recipient)

  -- Dequeue alerts up to budget x MAX_ALERTS_PER_EMAIL
  -- Note: in this case budget is the number of email to send
  while sent < budget and more_available do

    local diff = os.time() - start_time
    if diff >= webhook.ITERATION_TIMEOUT then
      break
    end

    -- Dequeue MAX_ALERTS_PER_EMAIL notifications
    local notifications = ntop.lrangeCache(recipient.export_queue, 0, MAX_ALERTS_PER_REQUEST-1)

    if not notifications or #notifications == 0 then
      more_available = false
      break
    end

    local alerts = {}

    for _, json_message in ipairs(notifications) do
      local alert = json.decode(json_message)
      table.insert(alerts, alert)
    end

    if not webhook.sendMessage(alerts, settings) then
      ntop.delCache(recipient.export_queue)
      return {success=false, error_message="Unable to send alerts to the webhook"}
    end

    -- Remove the processed messages from the queue
    ntop.ltrimCache(recipient.export_queue, #notifications, -1)

    sent = sent + 1
  end

  return {success=true}
end

-- ##############################################

function webhook.runTest(recipient)
  local message_info

  local settings = recipient2sendMessageSettings(recipient)

  local success = webhook.sendMessage({}, settings)

  if success then
    message_info = i18n("prefs.webhook_sent_successfully")
  else
    message_info = i18n("prefs.webhook_send_error")
  end

  return success, message_info
end

-- ##############################################

return webhook

