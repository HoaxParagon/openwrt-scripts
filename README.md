# openwrt-scripts
one script enables monitor mode on a desired interface, MAC option is mandatory but you can set it to the default device MAC, the other is similar in nature to airodump-ng with emphasis on unmasking hidden ssids.  

both scripts work on openwrt, neither uses airmon-ng. Currently airmon-ng doesn't work well with openwrt, at least not in my use case.  



download this file without git:  
-------------------------------  
(downloads the file to the current directory, names it 'openwrt-scripts.zip', requires install of unzip)  
apk update && apk install unzip  
wget https://github.com/HoaxParagon/openwrt-scripts/archive/refs/heads/main.zip -O ./openwrt-scripts.zip  
unzip ./openwrt-scripts.zip  

download without install of unzip:  
----------------------------------  
