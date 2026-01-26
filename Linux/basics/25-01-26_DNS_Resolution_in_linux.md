### How DNS Resolution works in Local setup
![DNS Resolution](../../Images/dns_resolution2.png)
***
- ping google.com = ping calls system resolver library (getaddrinfo() = Resolver now)
- Resolver now looks for /etc/nsswitch.conf file, it looks for the file refertences in this file that will help in resolving DNS.

![DNS Resolution Diagram](../../Images/image.png)
- 
- Now resolver looks for hosts: which has two entries _files_ and _dns_.
- _files_ = /etc/osts and _dns_ = dns server
### Flow of Resolver service
***
- Resolver checks = /etc/hosts
- Resolver then checks  = /etc/resolv.conf [127.0.0.53 nameserver] or Local DNS Server (Usually router).
- systemd-resolved (Linux sevice) listens on 127.0.0.53:53
    
    - It stores Cache DNS entries in RAM
    ![Cache entries](../../Images/image1.png)
    
       - #### How does entries goes in Local Cache
       >resolvectl query google.com

       - This tells if dns resolution coming from local or network cache

         - ![Cache dns in memory](../../Images/Kubernetes.png)
       > ping <domain.com>

       - This will add entries into the memory

## Flow of systemd-resolved
- systemd-networkd = Reads /etc/netplan/*.yaml
- systemd-networkd = Tells systemd-resolved about DNS entries via D-Bus (inter process communication).
- systemd-resolved stores it in it's in-memory table it also writes record in different files like /run/systemd/resolve/stub-resolv.conf (resolvectl status = tells the DNS entries)
- When systemd-resolved cannot find in in-memory cache, then it looks for /run/systemd/resolve/netif file.
- netif = It houses the upstream DNS server IP.
- Now systemd-resolved sends dns request packet to that upstream DNS ip.