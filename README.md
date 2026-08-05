# openwrt-scripts
one script enables monitor mode on a desired interface, MAC option is mandatory but you can set it to the default device MAC, the other is similar in nature to airodump-ng with emphasis on unmasking hidden ssids.  

both scripts work on openwrt, neither uses airmon-ng. Currently airmon-ng doesn't work well with openwrt, at least not in my use case.  


Terminal download methods provided for stock install of openwrt  
-  

download this file without git:  
-------------------------------  
(downloads the file to the current directory, names it 'openwrt-scripts.zip', requires install of unzip)  
apk update && apk install unzip  
wget https://github.com/HoaxParagon/openwrt-scripts/archive/refs/heads/main.zip -O ./openwrt-scripts.zip  
unzip ./openwrt-scripts.zip  


download without install of unzip:  
----------------------------------  
```wget https://raw.githubusercontent.com/HoaxParagon/openwrt-scripts/refs/heads/main/openwrt_hidden_ssid_demasker.sh -O ./openwrt_hidden_demasker.sh```  
```wget https://raw.githubusercontent.com/HoaxParagon/openwrt-scripts/refs/heads/main/openwrt_monitor_mode_enabler.sh -O ./openwrt_monitor_mode_enabler.sh```  

make them executable  
--------------------  
```chmod +x ./openwrt_hidden_demasker.sh```  
```chmod +x ./openwrt_monitor_mode_enabler.sh```  

run them  
---------  
```./openwrt_hidden_demasker.sh --help```  
```./openwrt_monitor_mode_enabler.sh --help```  

