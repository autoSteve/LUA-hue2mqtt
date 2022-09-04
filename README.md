# LUA-hue2mqtt

Gateway between a Philips Hue bridge and MQTT, written in LUA.

Copyright 2022 Steve Saunders

Script: Hue2mqtt, resident zero sleep

An alternative to https://github.com/owagner/hue2mqtt or https://github.com/hobbyquaker/hue2mqtt.js/ running directly on a CBus Automation Controller.

Utilises the latest Philips V2 REST API, and a topic structure aiming to be identical to its alternatives, so should be a drop-in replacement. The alternatives are quite dated, and make use of a deprecated Philips Hue API that is no longer maintained.

Some limitations:
- Only on/off and brightness set/lights/ commands are implemented
- Hue and saturation are not implemented for status topics