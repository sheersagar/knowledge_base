**LoRaWAN device** is like a talker ------> speaks to ----> **LoRaWAN Gateway**

## 1. LoRaWAN Devices vs Gateways
- _Devices_: They are simple sensors or actuators (`soil moisture sensor`, `smart water meter`, or a `GPS tracker`).
    - Designed to be low-power running on a single battery for 5 to 10 years.
    - They send small bits of data over very long distances (up to 15 kms)

- _Gateway_: It is a specialized router and acts as a relay.
    - It has a powerful radio (concentrator) that listens to thousands of devices at once.
    - It wraps the received data into a `standard internet packet` and sends it off to a server.
    - 