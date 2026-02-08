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
### Flow and architecture of IoT and AWS 

- **IoT devices** operate in the data plane layer and communicate using protocols
    - MQTT, MQTT over WSS, HTTPS, and LoRaWAN.
    - These devices converge at `AWS IoT Core` which acts as a secure ingress, message broker, and routing hub.
- **IoT Core** separates data plane operations from the controlplane where _web, mobile, backend, and automation application interact with devices using:-_
    - AWS SKDs, AWS IoT APIs, and AWS CLI.
    - Controlplane manages device identities, configuration, jobs, and state (via `device shadows`)

> AWS IoT Core routes device data to other AWS services for storage, analytics, and event processing using rules, while security (certificates, policies, monitoring) is enforced across all interactions.

> Edge runtimes such as AWS `IoT Greengrass` allow local processing alongside cloud connectivity

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


---

## 1. AWS IoT Services overview
![](../../Images/AWS_iot_svc.png) 

AWS IoT provides services that support IoT devices that interact with the world and the data that passes between them and AWS IoT.
- Humans/Apps/K8s (Infra on Cloud) <------> AWS IoT <-------> device shadow <-----> IoT Devices.

### 1.1 Device Software
- __AWS IoT Device SDKs__
    - They include open-source libraries, developer guides with samples, and porting guides.
    - Help in building innovative IoT producsts or solutions on your  choice of hardware platform.
- __AWS IoT Device Tester__
    - It is for `FreeRTOS` and AWS IoT `Greengrass`
    - It tests your device to determine if it will run `FreeRTOS` or `Greengrass`
- __AWS IoT ExpressLink__
    - They are a range of hardware modules developed and offered by **AWS Partners**
    - These modules include _AWS-validated software_ and making it faster and easier for you to securely connect devices to cloud.
- __AWS IoT Greengrass__
    - It extends AWS IoT to edge devices so they can act locally on the data they generate, run predictions, etc.
    - It enables your device to collect and analyze data closer to where data is generated, `react autonomously` to local events, `communicate securely` with other devices on LAN.
    - It can be used to build `edge applications` using pre-build software modules called **`Components`**
        - **`Components`** can connect your edge devices to AWS services or third-party services.
- __FreeRTOS__
    - An open source, real-time `OS` for _microcontrollers_, it lets you include small, low-power edge devices in your IoT solution.
    - It includes a `kernel` and a growing set of software libraries.
    - `FreeRTOS` systems securely connect your small, low-power devices to AWS IoT and support more powerful edge devices running `Greengrass.`

### 1.2 Control Service
- __AWS IoT Core__ 
    > Most Important and the central point of convergence for devices and AWS other services.
    - It is a `managed servcie` which enables connected devices to securely interact with cloud (application, services, etc) and other device.
    - Applications (web and mobile) can also interact with all your devices using this even if devices are offline (use `Device Shadows`).
- __AWS IoT Core Device Advisor__
    - Fully `Managed` test capability for validating IoT devices during _software developmewnt._
    - It provides pre-build tests that are used to validate IoT devices for `reliable` and `secure` connectivity with **AWS IoT Core** before deploying to production.
- __AWS IoT Device Defender__
    - It helps you `secure your fleet of Iot devices.`
    - It continuously audits your IoT configurations to prevent deviating from security best practices.
    - It sends an alert when detects any gaps in IoT config that might create a security risk.
        - Identity certificates shared across multiple devices.
        - Device with a revoked identity certificate trying to connect to AWS IoT Core.
- __AWS IoT Device Management__
    - It `track, monitor, and manage` the plethora of connected devices.
    - It ensures that IoT devices work properly and securely after they have been deployed.
    - Also provide `secure tunneling` to access your devices. 
        - Monitor health.
        - Detect and remotely troubleshoot problems.
        - Mange device software and firmware updates.
### 1.3 Data Services
- __Kinesis Video Streams__
    - Allows to stream live video from devices to AWS Cloud.
        > Durably stored, encrypted, and indexed. Data accessed using API
    - Used to capture massive amounts of live video data from millions of sources (`smartphones, security cameras, webcams, cameras in cars, drones, etc.`)
    - Enables you to playback video for live and on-demand viewing.
        - Can be integrated with Amazon Rekognition video, and libraries for ML frameworks.
- __AWS IoT Events__
     - It detects and responds to events from IoT sensors and applications.
     - It continuously monitors data from multiple IoT sensors and applications, and integrates with IoT Core, IoT SiteWise, DynamoDB, others to enable early detection.
- __AWS IoT FleetWise__
    - `Managed Service` that collect and transfer vehicle data to the cloud in near-real time.
    - It helps transform `low-level messages (emitted from vehicles)` into human-readable values and standardize the data format in cloud analyses.
        - We can define data collection schemes (control what data to collect in vehicles and when to transfer it to cloud).
- __AWS IoT SiteWise__
    - It collects, stores, organizes, and monitors data passed from **`industrial equipment`** by MQTT messages or APIs at scale by providing software that runs on a gateway in your facilities.
    - `Gateway` securely connects to your on-premises data servers and automates data collection and organization then sending it to AWS Cloud.
- __AWS IoT TwinMaker__
    - It builds operational digital twins of physical and digital systems.
    - It creates `digital visualizations` using measurements and analysis from a variety of _real-world sensors, cameras, and enterprise applications._
        - It helpstrack physical factory, building or industrial plant.

.

.

---
# AWS IoT Core Services
It provides the services that connect your `IoT devices` to AWS Cloud so that other cloud services and applications can interact with your _interenet-connected devices._ 
![](../../Images/aws_iot_core.PNG)

## 1. __AWS IoT Core messaging services__
IoT Core connectivity services provide secure communication with the IoT devices and manage the messages that pass between them and AWS IoT.

- 1.1 __Device Gateway__
    - Enables devices to securely and efficiently communicate with AWS IoT.
    - Device communication is secured by secure protocols that uses **X.509 certificates.**
- 1.2 __Message broker__
    - Provides a secure mechanism for `devices` and `AWS IoT applications` to publish and receive messages from each other.
    - We can use `MQTT protocol` or `MQTT over WSS` to publish and subscribe.
        - Protocols that AWS supports for **Device communication**
        - AWS IoT Core uses `TLS v1.2` and `TLS v1.3` to encrypt all communications.

        ---
        |Protocol| Operations supported|Authentication|Port|ALPN Protocol name|
        |--------|--------------------|--------------|----|------------|
        |MQTT over WebSocket|Publish, Subscribe|Signature Version 4|443|N/A|
        |MQTT over WebSocket|Publish, Subscribe|Custom authentication|443|N/A|
        |MQTT|Publish, Subscribe| X.509 client certificate|443|X-amzn-mqtt-ca|
        |MQTT|Publish, Subscribe|Custom authentication|443|mqtt|
        |HTTPS|Publish only|Signature Version 4|443|N/A|
        |HTTPS|Publish only|X.509 client certificate|443|x-amzn-http-ca|
        HTTPS|Publish only|X.509 client certificate|8443|N/A|
        HTTPS|Publish only|Custom authentication|443|x-amzn-http-ca|
    
    - Devices and clients can also use the HTTP REST interface to publish data to the `Message Broker`.
    - It distributes device data to devices that have subscribed to it and other **AWS IoT Core Services** (_Device Shadow, Rules engine._)

- 1.3 __AWS IoT Core for LoRaWAN__ 
    - It makes it possible to set up a private `LoRaWAN` network by connecting your `LoRaWAN` devices and `gateways` to AWS without the need to develop and Operate a _`LoRaWAN Network Server (LNS)`_
    - Messages received from LoRaWAN devices are sent to the `rules engine` where they can be formatted and sent to other AWS IoT services.
> [What are LoRaWAN devices and Gateway?](../../01-concept/networking/IoT/LoRaWAN.md)

- 1.4 __Rules engine__
    - It connects data from the message broker to other AWS IoT services for `storage` and `additional processing`.
        - Insert, Update, or Query a DynamoDB table or invoke a Lambda function.
        - You can use SQL-based language to select data from message payloads, then process and send the data to other services (S3, DynamoDB, Lambda)
    - Can Create rules that republish messages to the message broker and on to other subscribers.

## 2. __AWS IoT Core control services__
It provide device security, management, and registration features.

- 2.1 __Custom Authentication service__
    - We can define custom authorizers that allows to manage own authentication and authorization strategy using a `custom authentication service` and a `Lambda function`.
    - `Custom authorizers` can implement various authentication strategies;
        - JSON Web Token verification or OAuth provider callout.
        - They must return policy documents that are used by the device gateway to authorize `MQTT operations`
        > [Custom Authorization Documentation](https://docs.aws.amazon.com/iot/latest/developerguide/custom-authentication.html)

- 2.2 __Device Provisioning service__
    - It allows you to provision devices using template that describes the `resources` required for your device:
        -  _thing object_
            - It is an entry in the registry contains attributes that descirbe a device.
        - _certificate_
            - Devices use certificates to authenticate with AWS IoT.
        - _one or more policies_
            - Policies determine which operations a device can perform in AWS IoT.
    - The templates contain variables that are replaced by values in a dictionary (map).
    - Use same template to provision multiple devices just pass different values. [Device Provisioning](https://docs.aws.amazon.com/iot/latest/developerguide/iot-provision.html)
- 2.3 __Group registry__
    - It allow you to manage several devices at once by categorizing them into groups.
    - You can build a hierarchy of groups.
        - Any action perform on a parent group will apply to its child groups.
- 2.4 __Jobs service__
    - Allows you to define a set of remote operations that are sent to and run on one or more devices connected to AWS IoT.
        > Example: A job instructs a set of devices to download and install application or `firmware updates`, `reboot`, `rotate certificates` or `perform remote troubleshooting operation.`
    - To create a job :- You specify a description of the remote operations to be performed and a list of targets that should perform them.
    - Targets can be individual devices, groups or both.
- 2.5 __Registry__
    - It organizes the resources associated with each device in the AWS Cloud.
    - You register your devices and associate up to three custom attributes.
- 2.6 __Security and Identity service__
    - Provides shared responsibility for security in AWS Cloud.
    - Your devices must keep their credentials safe to securely send data to the `Message Broker.`
    - `Message broker` and `Rule engine` use AWS security features to send data securely to devices or other AWS services.

## 3. __AWS IoT Core data services__
It help your IoT solutions provide a reliable application experience with devices not connected.
- 3.1 __Device Shadow__
    - A JSON document used to store and retrieve current state information for a device.
- 3.2 __Device Shadow service__
    - It maintains a device's state so that applications can communicate with device whether the device is online or not.
    - When device is offline it manages its data for connected applications.
    - When the device reconnects, it synchronizes its state with that of its `shadow`.
    - Devices can also publish their current state to a shadow for use by applications or other devices that might not be connected all the time.