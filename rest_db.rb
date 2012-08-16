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

class Database
	#Container for the live object rest api
	def initialize(host)
		@log = LOG.instance
		#By default this should be "http://internal1:5053/inventory/"
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
			raise DelAttrError unless result.to_str.scan(/ERROR/).empty?
		rescue DelAttrError
			@log.debug("Attribute Deleteion failed with error \n #{result.to_str}")
			raise
		rescue 
			@log.fatal("Attribute Deleteion failed ")
			raise
		end
		return result
	end

	def del_all(fqdn, name)
		#removes attribes from nodes 1..20 x 1..20
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
			raise AddAttrError unless result.to_str.scan(/ERROR/).empty?
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
			return result.to_str.scan(/(\S*)='(.*?)'/)
			raise GetAttrError unless result.to_str.scan(/ERROR/).empty?
		rescue GetAttrError
			@log.warn("Get attribute failed with error \n #{result.to_str}")
			raise
		rescue
			@log.fatal("Attribute retrival failed")
			raise
		end
	end
end
