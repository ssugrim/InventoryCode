#!/usr/bin/ruby1.8 -w
#A rest client DB interface. Implements add, del, and get for attributes. Has a rudimentary del_all, but it's sloppy. 

require 'log_wrap'
require 'rest_client'

class DelAttrError < StandardError
end

class AddAttrError < StandardError
end

class GetAttrError < StandardError
end

class Tools
	#Class of Tools  for manipulating the arrays from the DB
	def self.tuple?(c)
		#the definintion of a tuple, 
	       	return(c.class == Array and c.length == 2 and c.count{|d| d.class == Array} == 0)
	end

	def self.contains?(w,c)
		#does this nestest structure contain the word w
		return !c.join(" ").match(Regexp.escape(w)).nil?
	end

	def self.tuples(current)
		#pulls out nested tuples 
		#TODO the ternary operation should be tuple? ?  return tuple : return insides
		store = Array.new
		calc = lambda {|s,c| self.tuple?(c) ? s.push(c) : (c.each{|f| calc.call(s,f)} if c.class == Array)}
		calc.call(store,current)
		return store
	end

	def self.tuples_alt(current)
		#doing it with lambads
		#This does not work yet. But it's something similar to this
		test_cond = lambda {|n| Tools.tuple?(n) ? n : n.map{|x| test_cond.call(x)}}
		foo.inject(Array.new()){|s,c| Tools.tuple?(c) ? s.push(c) : test_cond.call(c)}
	end

	def self.dig(word, current)
		#recursivley digs nested arrays and find the containers of word should only dig into things can contain a unquie copy of word
		store = Array.new
		calc = lambda {|w,s,c| self.tuple?(c) ? (s.push(c) if self.contains?(w,c)) : (c.each{|f| calc.call(w,s,f)} if c.class == Array)}
		calc.call(word,store,current)
		return store.flatten
	end
end

class Database
	#Container for the live object rest api
	def initialize(host)
		@log = LOG.instance
		#By default this should be "http://internal1:5054/inventory/"
		@host = host
		begin
			connect = RestClient.get @host
			@log.info("Restfull DB connected to #{@host}")
			@log.debug("with code: #{connect.code} \ncookies: #{connect.cookies} \nheaders: #{connect.headers}")
		rescue
			@log.fatal("Cant connect to host")
			raise
		end
	end

	def del_attr(node,name)
		#delete attributes from nodes
		#node, name node FQDN, and attribute name respectively. 
		host  = @host + "attribute/delete"
		begin
			result = RestClient.get host, {:params => {:name => node, :attribute => name}}
			@log.debug("Node #{node} had #{name} deleted  with result  #{result.to_str}")
			raise DelAttrError , result.to_str unless result.to_str.scan(/ERROR/).empty?
		rescue DelAttrError
			@log.debug("Attribute Deleteion failed with error \n #{result.to_str}")
			raise
		rescue 
			@log.fatal("Attribute Deleteion failed ")
			raise
		end
		return result
	end

	def del_all_attr(node)
		#delete all non-infrastructure attributes from nodes. Infrastructure attributes are defined in the config yaml file. They include:
		#- cm_type
		#- cm_ip
		#- cm_port
		#- control_switch_port_id
		#- type
		#- name
		#- control_ip
		#- x_coor
		#- y_coor
		#- default_disk
		#- pxe_image
		#- data_switch_port_id
		#node, name node FQDN, and attribute name respectively. 
		
		host  = @host + "attribute/delete/all"
		begin
			result = RestClient.get host, {:params => {:name => node}}
			@log.debug("Node #{node} had all attributes deleted  with result  #{result.to_str}")
			raise DelAttrError, result.to_str  unless result.to_str.scan(/ERROR/).empty?
		rescue DelAttrError
			@log.debug("Attribute Deleteion failed with error \n #{result.to_str}")
			raise
		rescue 
			@log.fatal("Attribute Deleteion failed ")
			raise
		end
		return result
	end

	def del_all_node(fqdn, name)
		#removes an attribute from nodes 1..20 x 1..20
		#name is the name of the attribute to delete
		#TODO perhaps this should expect/accept an argument instead of globbing acroess all
		sucess = 0
		for x in 1..20
			for y in 1..20
				begin
					del_attr("node#{x}-#{y}."  + fqdn,name)
					sucess += 1
				rescue DelAttrError
					#there will be a bunch of these but in this useage case we don't care, they're already reported
				end
			end
		end
		return sucess
	end

	def add_attr(node,name,value)
		#adds an attribute to a node
		#node, name and value are strings, node FQDN, attribute name, and value respectively. 
		host  = @host + "attribute/add"
		begin
			result = RestClient.get host, {:params => {:name => node, :attribute => name, :value => value}}
			@log.debug("Node #{node} had #{name}=#{value} set  with result  #{result.to_str}")
			raise AddAttrError, result.to_str unless result.to_str.scan(/ERROR/).empty?
		rescue AddAttrError
			@log.warn("Attribute addition failed with error \n #{result.to_str}")
			raise
		rescue
			@log.fatal("Attribute addition failed")
			raise
		end
		return result
	end

	def get_attr(node)
		#gets the attribues of a given node from the data base
		#node is a string, the FQDN of the node we want data for
		host  = @host + "resource/show"
		begin
			result = RestClient.get host, {:params => {:hrn => node}}
			raise GetAttrError, result.to_str unless result.to_str.scan(/ERROR/).empty?
		rescue GetAttrError
			@log.warn("Get attribute failed with error \n #{result.to_str}")
			raise
		rescue
			@log.fatal("Attribute retrival failed")
			raise
		end
		return result.to_str.scan(/(\S*)='(.*?)'/)
	end

	def get_all_node(fqdn)
		#Gets the all the attributes for a given fqdn e.g. "grid.orbit-lab.org"
		host  = @host + "resource/list" 
		begin
			result = RestClient.get host, {:params => {:hrn => fqdn}}
			raise GetAttrError, result.to_str unless result.to_str.scan(/ERROR/).empty?
			nodes = result.scan(/<NODE(.*?)\/>/)
			return nodes.map{|arr| arr.first.scan(/(\S*)='(.*?)'/)}
		rescue GetAttrError
			@log.warn("Get attribute failed with error \n #{result.to_str}")
			raise
		rescue
			@log.fatal("Attribute retrival failed")
			raise
		end
	end

end
