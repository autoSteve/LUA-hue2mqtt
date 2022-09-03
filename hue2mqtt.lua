bridge = '192.168.10.15' -- Obviously change all of these to suit environment
mqttBroker = '192.168.10.21' 
mqttUsername = 'mqtt'
mqttPassword = 'password'

--[[
Hue2mqtt, resident sleep zero

Gateway between a Philips Hue bridge and MQTT
Copyright 2022 Steve Saunders

An alternative to https://github.com/owagner/hue2mqtt or https://github.com/hobbyquaker/hue2mqtt.js/

Utilises the Philips V2 REST API, and a topic structure aiming to be identical to its alternatives.
--]]


hueTopic = 'hue/'
hueSetTopic = hueTopic..'set/lights/'
eventstream = '/eventstream/clip/v2'
resource = '/clip/v2/resource'
mqttClientId = 'achue2mqtt' -- Unique client ID to use for the broker
mqttQoS = 2                 -- Quality of service for MQTT messages: 0 = only once, 1 = at least once, 2 = exactly once
socketTimeout = 0.01        -- Lower = higher CPU
logging = false             -- Enable detailed logging
logms = false               -- Include timestamp in milliseconds for logs

port = 443
protocol = 'tlsv12'

devices = {}                -- Hue device status
connected = false           -- Receiving event stream?
mqttDevices = {}            -- Lookup Hue object from metadata name
mqttMessages = {}           -- Incoming message queue
mqttStatus = 2              -- Initially disconnected 1=connected, 2=disconnected
mqttConnected = 0           -- Timestamp of MQTT connection, initially zero which will cause an immediate connection

mqttTimeout = 0             -- In milliseconds, go with zero unless you know what you're doing
RETAIN = true               -- Boolean aliases for MQTT retain and no-retain settings
NORETAIN = false

appkey = nil


started = socket.gettime(); function logger(msg) if logms then ts = string.format('%.3f ', socket.gettime()-started) else ts = '' end log(ts..msg) end -- Log helper
function CTfromCCT(cct) if cct > 6500.0 then return math.floor(2000 / 13 + 0.5) elseif cct < 2000.0 then return 500 end return math.floor(1000000 / cct + 0.5) end
function CCTfromXY(x, y) local n = (x - 0.3320) / (0.1858 - y); return 437*n^3 + 3601*n^2 + 6861*n + 5517 end
function CTfromXY(x, y) return CTfromCCT(CCTfromXY(x, y)) end

  
--[[
Set up the Hue connection
--]]

require('ssl')
sock = require('socket').tcp()
http = require'socket.http'
local ltn12 = require('ltn12')

function rest(method, cmd, body)
  if not body then body = '' end
  local respbody = {}
  local headers = {
    ["content-length"] = tostring(#body)
  }
  if appkey ~= nil then headers['hue-application-key'] = appkey end
  local result, respcode, respheaders, respstatus = http.request {
      method = method,
      url = 'https://'..bridge..cmd,
      source = ltn12.source.string(body),
      headers = {
          ['hue-application-key'] = appkey,
          ["content-length"] = tostring(#body)
      },
      sink = ltn12.sink.table(respbody)
  }
  if respcode ~= 200 then log('Error: Received response '..respcode..' requesting '..cmd) end
  return table.concat(respbody)
end

function send(t, accept, cmd, payload)
  local toSend
  if not payload then
    toSend = t..' '..cmd..' HTTP/1.1\nHost: '..bridge..'\nAccept: '..accept..'\nhue-application-key: '..appkey..'\n\n'
  else
    toSend = t..' '..cmd..' HTTP/1.1\nHost: '..bridge..'\nAccept: '..accept..'\nhue-application-key: '..appkey..'\n\n'..payload..'\n'
  end
  sock:send(toSend)
end


appkey = storage.get(mqttClientId)
if appkey == nil then
  logger('Press the Hue bridge link button')
  repeat
    response = json.decode(rest('POST', '/api', '{"devicetype":"cbus#ac", "generateclientkey": true}'))[1]
    if response.error and response.error.description:find('not pressed') then
      logger('Waiting for link button...')
      socket.sleep(5)
    end
  until response.success
  appkey = response.success.username
  storage.set(mqttClientId, appkey)
end


function getResources()
  l = rest('GET', resource)
  for _, d in ipairs(json.decode(l).data) do
    if d.id_v1 and d.id_v1 ~= '' and not d.mac_address then
      -- if d.id_v1 == '/lights/15' then log(d) end
      if d.type and d.type == 'bridge_home' then
      elseif d.id_v1:find('group') then
      elseif d.product_data then
      elseif d.on then
        devices[d.id_v1] = {id = d.id, name = d.metadata.name, on = d.on.on, reachable = true}
        if d.dimming then devices[d.id_v1].brightness = d.dimming.brightness; devices[d.id_v1].level = CBusPctToLevel(d.dimming.brightness) end
        if d.color and d.color.xy then devices[d.id_v1].xy = {d.color.xy.x, d.color.xy.y} end
        if d.color_temperature then
          if d.color_temperature.mirek_valid then
            devices[d.id_v1].ct = d.color_temperature.mirek
            devices[d.id_v1].colormode = 'ct'
          else
            devices[d.id_v1].colormode = 'xy'
            devices[d.id_v1].ct = CTfromXY(d.color.xy.x, d.color.xy.y)
          end
        end
        if d.effects then if d.effects.status == 'no_effect' then devices[d.id_v1].effect = 'none' else devices[d.id_v1].effect = d.effects.status end end
        -- hue & sat to do
        -- alert?? 
        mqttDevices[d.metadata.name] = d.id
      end
    end
  end
  if logging then
    local ds = ''
    for _, d in pairs(devices) do
      ds = ds..'\n'..d.name..' '..d.id
    end
    logger('Discovered devices:'..ds)
  end
end


res, err = sock:connect(bridge, port)
if res then
  sock = ssl.wrap(sock, protocol)
  res, err = sock:dohandshake()
  if res then
    logger('Connected to Philips Hue bridge')
    sock:settimeout(socketTimeout)
    getResources()
    send('GET', 'text/event-stream', eventstream)
  else
    logger('Handshake failed: ' .. tostring(err))
    sock:close()
    do return end
  end
else
  logger('Connect failed: ' .. tostring(err))
  sock:close()
  do return end
end


--[[
Publish status/lights/ topics 
--]]

function publish(device, d)
  local payload
  if d.brightness then
    local level = d.level; if level == 255 then level = 254 end
    payload = {
      val = d.on and d.level or 0,
      hue_state = {
        on = d.on,
        bri = level,
        effect = d.effect,
        xy = d.xy,
        ct = d.ct,
        hue = nil, -- To do
        sat = nil, -- To do
        colormode = d.colormode,
        alert = 'select',
        reachable = d.reachable,
      }
    }
  else
    payload = {
      val = d.on,
      hue_state = {
        on = d.on,
        alert = 'select',
        reachable = d.reachable,
      }
    }
  end
  local j = json.encode(payload)
  client:publish(hueTopic..'status/lights/'..d.name, j, mqttQoS, RETAIN)
end

--[[
Mosquitto client and call-backs 
--]]

mqtt = require('mosquitto')
client = mqtt.new(mqttClientId)
client:will_set(hueTopic..'status', 'offline', mqttQoS, RETAIN)
if mqttUsername then client:login_set(mqttUsername, mqttPassword) end

client.ON_CONNECT = function(success)
  if success then
    logger('Connected to MQTT broker')
    client:publish(hueTopic..'status', 'online', mqttQoS, RETAIN)
    mqttStatus = 1
    -- Subscribe to set topic
    client:subscribe(hueSetTopic..'#', mqttQoS)
 
    -- Full publish status topics
    for device, d in pairs(devices) do publish(device, d) end
  end
end

client.ON_DISCONNECT = function(client, userdata, rc)
  logger('Disconnected from MQTT broker ('..rc..')')
  mqttStatus = 2
end

client.ON_MESSAGE = function(mid, topic, payload)
  mqttMessages[#mqttMessages + 1] = { topic=topic, payload=payload } -- Queue the MQTT message
end


--[[
Publish queued messages - TODO ... Only handles on and brightness
--]]
function outstandingMqttMessage()
  -- Send set messages to Hue API
  local m
  for _, m in ipairs(mqttMessages) do
    local topic = m.topic
    local msg = json.decode(m.payload)
    local payload = {}
    local k, v
    for k, v in pairs(msg) do
      if k == 'on' then payload.on = {}; payload.on.on = v
      elseif k == 'bri' then payload.dimming = {}; payload.dimming.brightness = CBusLevelToPct(v)
      end
    end
    local parts = string.split(topic, '/')
    local toPut = json.encode(payload)
    if parts[3] == 'lights' then
      local resource = resource..'/light/'..mqttDevices[parts[4]]
      if logging then logger(resource..' PUT '..toPut) end
      rest('PUT', resource, toPut)
    else
      logger('Unexpected set topic: '..topic)
    end
  end
  mqttMessages = {}
end


--[[
Main loop
--]]

while true do
  repeat -- Process the entire read buffer
    local line, err = sock:receive()
    sock:settimeout(0)

    if not err then
      if line then
        if line:find('data:') and not line:find('geofence_client') then
          payload = line:split(': ')[2]
          local stat, err = pcall(function ()
            j = json.decode(payload)
          end)
          if stat then
            --log(j)
            for _, msg in ipairs(j) do
              if msg.type == 'update' then
                for _, d in ipairs(msg.data) do
                  local update = false
                  local on = nil; if d.on then on = d.on.on; update = true end
                  local bri = nil; local lvl = nil; if d.dimming then bri = d.dimming.brightness; lvl = CBusPctToLevel(bri); update = true end
                  local mirek = nil; if d.color_temperature and d.color_temperature.mirek_valid then mirek = d.color_temperature.mirek; update = true end
                  local xy = nil; if d.color and d.color.xy then xy = {d.color.xy.x, d.color.xy.y}; update = true end
                  local rtype = nil; if d.owner then rtype = d.owner.rtype end
                  local status = nil; if d.status then status = d.status; update = true end
                  local id = d.id_v1
                  if devices[id] then
                    if logging then logger('Hue event '..id..', stat='..tostring(status)..', on='..tostring(on)..', bri='..tostring(bri)..', lvl='..tostring(lvl)) end
                    if status ~= nil  then if status == 'connected' then devices[id].reachable = true else devices[id].reachable = false end end
                    if on ~= nil then devices[id].on = on end
                    if bri ~= nil then devices[id].brightness = bri; devices[id].level = lvl end
                    if mirek ~= nil then devices[id].ct = mirek; devices[id].colormode = 'ct' end
                    if xy ~= nil then devices[id].xy = xy
                      if not mirek then
                        devices[id].colormode = 'xy'
                        devices[d.id_v1].ct = CTfromXY(d.color.xy.x, d.color.xy.y)
                      end
                    end
                    -- Publish update
                    if update then
                      publish(id, devices[id])
                    end
                  end
                end
              end
            end
          end
        elseif line:find(': hi') then
          logger('Receiving event stream')
          connected = true
        end
      end
    else
      if err ~= 'wantread' then
        logger('Hue receive failed: ' .. tostring(err))
        sock:close()
        do return end
      end
    end
  until err == 'wantread'
  sock:settimeout(socketTimeout)

  -- Process MQTT message buffers synchronously - sends and receives
  client:loop(mqttTimeout)

  if mqttStatus == 1 then
    -- When connected to the broker
    if #mqttMessages > 0 then outstandingMqttMessage() end -- Send outstanding messages
    
  elseif mqttStatus == 2 and os.time() - mqttConnected >= 5 then
    -- MQTT is disconnected, so attempt a connection every five seconds
    mqttConnected = os.time()
    client:connect(mqttBroker, 1883, 25) -- Requested keep-alive 25 seconds, broker at port 1883

    local time = socket.gettime() while socket.gettime() - time < 2 do client:loop(0) end -- Allow some settling time for subscriptions with retain flag
  end
end