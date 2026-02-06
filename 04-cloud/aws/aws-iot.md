# What is AWS IoT
### AWS IoT provides device software that can help you integrate your IoT devices into AWS IoT-based solutions.
- If your devices can connect to AWS IoT, AWS IoT can connect them to the cloud servies that AWS provides.
- AWS IoT supports these protocols
    - MQTT (Message Queuing and Telemetry Transport)
    - MQTT over WSS (Websockets Secure)
    - HTTPS 
    - LoRaWAN (Long Range Wide Are Network)
        - Wireless LoRaWAN devices
        - AWS IoT core uses LNS (LoRaWAN network Server)
    - If AWS IoT features (device communications, rules, or jobs) then use **AWS Messaging**

---

## How your devices and apps access AWS IoT
###    1. AWS IoT Device SDKs - 
- Build applications on your devices that send messages to and receive messages from AWS IoT.

### 2. AWS IoT Core for LoRaWAN - 
- Connect and manage your long range WAN (LoRaWAN) devices and gateways by using `AWS IoT Core for LoRaWAN`

### 3. AWS CLI -
- Run commands for AWS IoT on Windows, macOS, and Linux.
- Commands allow you to create and manage _thing objects, certificate, rules, jobs, and policies._

### 4. AWS IoT API -
- Build your IoT applications using HTTP or HTTPS requests.
- API actions allow you to programmatically create and manage _thing objects, certificates, rules, and policies._

### 5. AWS SDKs-
- Build your IoT applications using language-specific APIs. 
- These SDKs wrap the HTTP/HTTPS API and allow you to program in any of the supported languages.

