#inventory script for omf (not 5.2)
#ver: .5


defGroup('nodes','system:topo:active') { |node|
}

whenAllUp() {
  puts "Execute command /usr/bin/ruby /root/gatherer.rb on all nodes" 
  allGroups.exec("sudo /root/gatherer.rb -d -l /tmp/gather.log")
  wait 90
  Experiment.done
}
