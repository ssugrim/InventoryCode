#inventory script for omf-5.2
#Version .5


defApplication('inventory','gather') {|app|
	app.shortDescription = "Inventory Gathering Process"
	app.path = "sudo /root/gatherer.rb -d -l /tmp/gather.log"
}

defGroup('nodes','system:topo:active') { |node|
	node.addApplication('inventory')
}

whenAllInstalled() {|node|
  info "Execute command gatherer.rb on all nodes" 
  allGroups.startApplications
  wait 90
  Experiment.done
}
