#!/usr/bin/ruby1.8 -w
#Version 1.3
#A rest client DB interface. Implements add, del, and get for attributes.
#Adapting to the new "interface" defined at http://www.orbit-lab.org/wiki/Software/bAM/aInventory 

require 'log_wrap'
require 'rest_client'

class DelAttrError < StandardError
end

class AddAttrError < StandardError
end

class GetAttrError < StandardError
	attr_accessor :result

	def initialize(message = nil, result = nil)
		super(message)
		self.result = result
	end
end

class BadAttrName < StandardError
end

class AddResError < StandardError
end

class DelResError < StandardError
	attr_accessor :result

	def initialize(message = nil, result = nil)
		super(message)
		self.result = result
	end
end

class BadPrefix < StandardError
end

class Tools
	#Class of Tools  for manipulating the arrays from the DB
	@@log = LOG.instance

	def self.tuple?(c)
		#the definintion of a tuple, 
	       	return(c.class == Array and c.length == 2 and c.count{|d| d.class == Array} == 0)
	end

	def self.contains?(w,c)
		#does this nestest structure contain the word w
		return !c.join(" ").match(Regexp.escape(w)).nil?
	end

	def self.tuples(current)
		#an Example of a proper recursive call (instead of using a side effect). 
		test_cond = lambda {|n| 
			if Tools.tuple?(n)
			       #return if it was a tuple	
			#	puts "Debug message: Was a tuple #{n.join(" ")}"
				return  [n]
			else
				#if it is not a tuple, check if it is an array
			       if n.class == Array
				       #if it is, call the recursive step, note the flatten(1) at the end. This will collpase one level of nesting which is generated by the call to map 
			#	       puts "Debug Message: Was not a tuple #{n}"
				       val = n.map{|x| test_cond.call(x)}.flatten(1)
				       @@log.debug("Tools.tuples: Result of recursive call #{val}")
				       return val
			       else
				       #other wise return a nil (these will be compacted out)
				       @@log.debug("Tools.tuples: Not either #{n}")
				       return nil
			       end
			end
		}
		#the resursive call onto the given data. Since we need to do at least one map we wrap current into an array. We'll remove that mapping by using a flatten(1).
		return [current].map{|y| test_cond.call(y)}.flatten(1).compact
	end

	def self.dig(word, current)
		#recursivley digs nested arrays for string word and find the containers of word should only dig into things can contain a unquie copy of word
		store = Array.new
		#Store if it is a tuple and contains w, other wise recurse  on all sub arrays
		calc = lambda {|w,s,c| self.tuple?(c) ? (s.push(c) if self.contains?(w,c)) : (c.each{|f| calc.call(w,s,f)} if c.class == Array)}
		calc.call(word,store,current)
		return store
	end

	def self.get_last(array)
		return array.flatten.last
	end
end

class Database
	#Container for the live object rest api
	def initialize(host,loc_timeout = 120 ,retry_limit = 5, stagger = 2)
		@log = LOG.instance

		#the prefix value is what the del_all_attr method uses to filter records. It must be set, and any attributes submitted to the add method will be checked for this prefix.
		@prefix = nil

		#By default this should be "http://internal1.orbit-lab.org:5054/inventory/"
		@host = host
		@timeout = loc_timeout
		@retry_limit = retry_limit
		@stagger = stagger


		begin
			resource  = RestClient::Resource.new host, :timeout => @timeout, :open_timeout => @timeout
			connect = resource.get
			@log.info("Database: Restfull DB connected to #{@host}")
			@log.debug("Database: with code: #{connect.code} \ncookies: #{connect.cookies} \nheaders: #{connect.headers}")
		rescue
			@log.fatal("Database: Cant connect to host")
			raise
		end

	end

	def set_prefix(prefix)
		# set the prefix 
		@log.debug("Database: Prefix set to #{prefix}")
		@prefix = prefix
	end

	def del_attr(resource,name)
		#delete attributes from resources
		#resource is the resource FQDN, and name is the attribute name
		#This will delete an attribute reguardless of prefix (Use with caution)
		
		host  = @host + "attribute_delete"
		begin
			result = call_rest(host, {:name => resource, :attribute => name})
			@log.debug("Database: Resource #{resource} had #{name} deleted  with result  #{result.to_str}")
			raise DelAttrError , result.to_str unless result.to_str.scan(/ERROR/).empty?
		rescue DelAttrError
			@log.debug("Database: Attribute Deleteion failed with error \n #{result.to_str}")
			raise
		rescue 
			@log.fatal("Database: Attribute Deleteion failed}")
			raise
		end
		return result
	end

	def del_all_attr(resource)
		#delete attributes from resources that are prefixed with @prefix
		#resource, name resource FQDN, and attribute name respectively. 
		raise BadPrefix if @prefix == nil
		host  = @host + "attribute_delete"
		begin
			result = call_rest(host, {:name => resource, :attribute => "#{@prefix}*"})
			@log.debug("Database: Resource #{resource} had attributes deleted  with result  #{result.to_str}")
			raise DelAttrError , result.to_str unless result.to_str.scan(/ERROR/).empty?
		rescue DelAttrError
			@log.debug("Database: Attribute Deleteion failed with error \n #{result.to_str}")
			raise
		rescue 
			@log.fatal("Database: Attribute Deleteion failed}")
			raise
		end
		return result
	end

	def modify_attr(resource,name,value)
		#modify an attribute to a resource
		#resource, name and value are strings are the resource FQDN, attribute name, and attrbute value respectively. 
		#Name must be prefixed with @prefix other wise it's going to complain
		raise BadPrefix if @prefix == nil
		host  = @host + "attribute_modify"

		#I won't adjust your name, but I will bark at you if you don't comply
		raise BadAttrName, "Must prefix attribute name with #{@prefix}" if name.match(/^#{@prefix}/).nil?

		begin
			result = call_rest(host, {:name => resource, :attribute => name, :value => value})
			@log.debug("Database: Resource #{resource} had #{name}=#{value} set  with result  #{result.to_str}")
			raise AddAttrError, result.to_str unless result.to_str.scan(/ERROR/).empty?
		rescue AddAttrError
			@log.debug("Database: Attribute modify failed with error \n #{result.to_str}")
			raise
		rescue
			@log.fatal("Database: Attribute modify failed")
			raise
		end
		return result
	end

	def add_attr(resource,name,value)
		#adds an attribute to a resource
		#resource, name and value are strings are the resource FQDN, attribute name, and attrbute value respectively. 
		#Name must be prefixed with @prefix other wise it's going to complain
		raise BadPrefix if @prefix == nil
		host  = @host + "attribute_add"

		#I won't adjust your name, but I will bark at you if you don't comply
		raise BadAttrName, "Must prefix attribute name with #{@prefix}" if name.match(/^#{@prefix}/).nil?

		begin
			result = call_rest(host, {:name => resource, :attribute => name, :value => value})
			@log.debug("Database: Resource #{resource} had #{name}=#{value} set  with result  #{result.to_str}")
			raise AddAttrError, result.to_str unless result.to_str.scan(/ERROR/).empty?
		rescue AddAttrError
			@log.debug("Database: Attribute addition failed with error \n #{result.to_str}")
			raise
		rescue
			@log.fatal("Database: Attribute addition failed")
			raise
		end
		return result
	end

	def add_attr_np(resource,name,value)
		#adds an attribute to a resource
		#resource, name and value are strings are the resource FQDN, attribute name, and attrbute value respectively. 
		host  = @host + "attribute_add"

		begin
			result = call_rest(host, {:name => resource, :attribute => name, :value => value})
			@log.debug("Database: Resource #{resource} had #{name}=#{value} set  with result  #{result.to_str}")
			raise AddAttrError, result.to_str unless result.to_str.scan(/ERROR/).empty?
		rescue AddAttrError
			@log.debug("Database: Attribute addition failed with error \n #{result.to_str}")
			raise
		rescue
			@log.fatal("Database: Attribute addition failed")
			raise
		end
		return result
	end

	def get_attr(resource, attr="*")
		#gets the attribues of a given resource from the data base, resource is a string, the name of the resouce whose attributes
		#we want. will accept wild cards
		#Returns an array of nodes or devices which are 2 tuples, item 1 is the type (node|device) item 2 is the data
		
		host  = @host + "attribute_list"
		begin
			#get the attributes from the rest db
			result = call_rest(host, {:set => resource, :attribute => attr})
			raise GetAttrError.new("Failed to get attribute", result) unless result.scan(/ERROR/).empty?

			#split the attrtivbutes  into arrays of node data or device data (one entitiy per array)
			#parse data string for key=value pairs, the first entry stores wheter it's a node or a device
			return result.scan(/<(node|device)(.*?)>/).map{|x| [x[0], x[1].scan(/(\S*)='(.*?)'/)]}.reject{|x| x[1].empty?}
		rescue GetAttrError => e
			@log.debug("Database: Get attribute failed with error \n #{e.result}")
			raise
		rescue
			@log.fatal("Database: Attribute retrival failed")
			raise
		end
	end

	def get_devs(domain)
		host  = @host + "attribute_list"
		begin
			result = call_rest(host, {:set => "*" + domain + "*", :attribute => "INV_dev*"})
			raise GetAttrError.new("Failed to get attribute", result.to_str) unless result.to_str.scan(/ERROR/).empty?
			#parse string for key=value pairs
			return result.to_str.scan(/\<device(.*?)\/>/).map{|arr| arr.join(" ").scan(/(\S*)='(.*?)'/).reject{|x| x.first.include?("status")}}
		rescue GetAttrError => e
			@log.debug("Database: Get attribute failed with error \n #{e.result}")
			raise
		rescue
			@log.fatal("Database: Attribute retrival failed")
			raise
		end
	end

	def del_resource(resource)
		#resource is a string,  the name (or partial_name) of the resouce being added
		host  = @host + "resource_delete"

		begin
			result = call_rest(host, {:set => resource})
			@log.debug("Database: Resource #{resource} had delete  with result  #{result.to_str}")
			raise DelResError.new( "Resource Deletion failed", result.to_str) unless result.to_str.scan(/ERROR/).empty?
		rescue DelResError => e
			@log.debug("Database: Resource deletion failed with error \n #{e.result}")
			raise
		rescue
			@log.fatal("Database: Resource deleteion failed with non rest error")
			raise
		end
		return result
	end

	def add_resource(resource,type)
		#adds a resource
		#resource is name of the resource (usually  fqdn of node + some moniker) and type (usually device)
		host  = @host + "resource_add"

		begin
			result = call_rest(host, {:name => resource, :type => type})
			@log.debug("Database: Resource #{resource} had type=#{type} set  with result  #{result.to_str}")
			raise AddResError, result.to_str unless result.to_str.scan(/ERROR/).empty?
		rescue AddResError
			@log.debug("Database: Resource addition failed with error \n #{result.to_str}")
			raise
		rescue
			@log.fatal("Database: Resource addition failed")
			raise
		end
		return result
	end

	def add_relation(parent,child)
		#add a relationship between a parent and a child
		host  = @host + "relation_add"

		begin
			result = call_rest( host, {:parent => parent, :child => child})
			@log.debug("Database: #{parent} to #{child} relation added with  #{result.to_str}")
			raise AddResError, result.to_str unless result.to_str.scan(/ERROR/).empty?
		rescue AddResError
			@log.debug("Database: Relation addition failed with error \n #{result.to_str}")
			raise
		rescue
			@log.fatal("Database: Relation addition failed")
			raise
		end
		return result
	end

	def list_resource(type, parent= nil)
		#parent is a string, name of the parent to check wheter children exist. Returns an array of strings which are the resource names of the children.
		host  = @host + "resource_list"

		begin
			parent ? params = {:parent=> parent, :type => type} : params = {:type => type}
			result = call_rest(host, params)
			raise AddResError, result.to_str unless result.to_str.scan(/ERROR/).empty?
			return result.to_str.scan(/(\S*)='(.*?)'/)
		rescue AddResError
			@log.debug("Database: Relation addition failed with error \n #{result.to_str}")
			raise
		rescue
			@log.fatal("Database: Relation addition failed")
			raise
		end
	end

	def list_relation(parent)
		#parent is a string, name of the parent to check wheter children exist. Returns an array of strings which are the resource names of the children.
		host  = @host + "resource_list"

		begin
			result = call_rest(host, {:parent => parent})
			children = result.to_str.scan(/resource name='(.*?)'/).flatten
			@log.debug("Database: #{parent} has #{children.length} relations  #{result.to_str}")
			raise AddResError, result.to_str unless result.to_str.scan(/ERROR/).empty?
		rescue AddResError
			@log.debug("Database: Relation addition failed with error \n #{result.to_str}")
			raise
		rescue
			@log.fatal("Database: Relation addition failed")
			raise
		end
		return children
	end

	def call_rest(host, params = nil)
		#get wrapper to trap centralised errors like time outs
		retries = 0

		unless @stagger == 0
			stag = rand(@stagger) + @stagger
			@log.debug("Database: Staggering rest call by #{stag}")
			sleep(stag)
		end

		begin
			resource  = RestClient::Resource.new host, :timeout => @timeout, :open_timeout => @timeout
			if params.nil?
				result = resource.get
			else
				result = resource.get :params => params
			end
		rescue RestClient::RequestTimeout => e
			if retries > @retry_limit
				@log.fatal("Database: Could not connet to DB server #{host}")
				raise
			else
				@log.warn("Database: Database connection timedout, attempt  #{retries} \n #{e.message}")
				sleep rand(10)
				retries += 1
				retry
			end
		end
		return result
	end
end
