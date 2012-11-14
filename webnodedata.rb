#!/usr/bin/ruby1.8 -w
# A viewer current state of the rest DB

require 'log_wrap'
require 'rest_db'

class WebNodeData
	#container class for all the data and meta data extraced from the DB
	def initialize(host, fqdn)
		@log  = LOG.instance
		
		#all the data fromt he restDB for this given fqdn
		db = Database.new(host, "INV_")
		@nodes = db.get_all_node(fqdn)

		#all the possible headers expect name
		@headers = @nodes.inject(Array.new){|s,c| s.push(c.map{|x| x.first})}.flatten.uniq.reject{|x| x == "name"}.sort

		#all the names
		@names = @nodes.flatten.join(" ").scan(/(node\d+-\d+\.#{fqdn})/).flatten
	end

	def get_node_data(name)
		#name is a string, the name of the node whose data we want
		return Tools.tuples(@nodes.select{|x| Tools.contains?(name,x)})
	end

	attr_reader :nodes, :headers, :names
end


if __FILE__ == $0
	puts WebNodeData.new("http://internal1.orbit-lab.org:5054/inventory/","grid.orbit-lab.org").headers
end
