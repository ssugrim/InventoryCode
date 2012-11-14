#!/bin/bash
echo "Sleeping 30" > /tmp/inventory.log
sleep 30
let amt=$RANDOM%10 
echo "Sleep $amt" >> /tmp/inventory.log
sleep $amt 
echo "NTP info" >> /tmp/inventory.log
ntpq --numeric --peers >> /tmp/inventory.log
echo "Starting gatherer" >> /tmp/inventory.log
ruby -I /root/ /root/gatherer.rb -d  -l /tmp/gatherer.log >> /tmp/inventory.log
echo "Done" >> /tmp/inventory.log

