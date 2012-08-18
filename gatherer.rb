#!/usr/bin/ruby1.8 -w
# gatherer.rb version 2.4 - Gathers information about various sytem files and then  checks them against mysql tables
#
#ETODO can't detect usrp2 this way. 
#error string that gets checked in.

require 'optparse'
require 'open3'
require 'find'
require 'singleton'
require 'log_wrap'
require 'rest_db'

#Some Custom Errors

class  NoMbidError < StandardError
end

class  NoHdError < StandardError
end

class  NoLocidError < StandardError
end

class BinaryNotFound < StandardError
end

class Tools
	#Class of Tools common to every one
	def self.tuple?(c)
		#the definintion of a tuple, 
	       	return(c.class == Array and c.length == 2 and c.count{|d| d.class == Array} == 0)
	end

	def self.contains?(w,c)
		#does this nestest structure contain the word w
		return !c.join(" ").match(Regexp.escape(w)).nil?
	end

	def self.tuples(s,c)
		#pulls out nested tuples 
		if self.tuple?(c)
			#if it is a tuple save it
			s.push(c)
		else
			#other wise try each sub element if I have any
			c.each{|f| tuples(s,f)} if c.class == Array
		end
	end

	def self.dig(w,s,c)
		#recursivley digs nested arrays and find the containers of word
		if self.tuple?(c)
			#does it contain word, save it.
			s.push(c) if self.contains?(w,c)
		else
			#otherwise try every sub element
			c.each{|f| dig(w,s,f)} if c.class == Array
		end
	end
end

class DBhelper
	#some inventory specfic Rest DB functions, the model here is there is a prepared database object and the update functions of each of the classes uses a helper object to write to the API
	def initialize(host,node)
		#host and node are strings, they are the hostname of the DB server and the fqdn of the node this code is running on respectively. 
		@log = LOG.instance
		@db = Database.new(host)
		@node = node
	end

	def get_attr(name)
		#name is a string, the name of the attribute you want the value for. This will return the value of the given named attribute
		data = @db.get_attr(@node)

		#look for the attribute name in the array
		found = data.select{|arr| arr[0].include?(name)}

		if found.nil?
			return nil
		else
			return found.flatten[1]
		end
	end

	def del_attr(name)
		#name is a string, the attribute name to be deleted
		return	@db.del_attr(@node,name)
	end
	
	def add_attr(name,value)
		#name, value are strings. name is the name of the attribute to be added, and value is it's value
		if get_attr(name).nil?
			return @db.add_attr(@node,name,value)
		else
			del_attr(name)
			return @db.add_attr(@node,name,value)
		end
	end

	def check_in(now)
		#now is a string, a time stamp
		return add_attr("check_in",now)
	end
end

class NodeData
	include Singleton
	#Node identification information
	def initialize()
		#TODO we'll need to get exectuables as params from OPT parse at some point
		begin
			@log  = LOG.instance

			stdin, stdout, stderr = Open3.popen3("#{$options[:lochostname]} -f")
			raise(BinaryNotFound, "hostname") unless stderr.readlines.join(" ").scan(/No such file or directory/).empty?
			@fqdn = stdout.readlines.join(" ").chomp

			stdin, stdout, stderr = Open3.popen3("#{$options[:locdate]}")
			raise(BinaryNotFound, "Date") unless stderr.readlines.join(" ").scan(/No such file or directory/).empty?
			@now = stdout.readlines.join(" ").chomp

			@log.debug("Os said the fqdn was #{@fqdn}, and the date/time is #{@now}")
			md = @fqdn.match(/node(\d+)-(\d+)./)
			@x,@y = md.captures unless md.nil?
		rescue BinaryNotFound => e
			@log.fatal("Component.lshw_arr: #{e.class} #{e.message}")
			@log.fatal("Component.lshw_arr: called by #{caller}")
			raise
		rescue
			@log.fatal("Something broke while getting system info")
			raise
		end
	end

	attr_reader :fqdn,:y, :x, :now
end

class LshwData
	def initialize(flag)
		#Arugments: 
		#Flag - what device class to pass to lshw (see lshw webpage)  - Mandatory
		#Returns an Array of lines from lshw output, if a marker is specfied the array is folded at the markers (markers discarded)

		@flag = flag
		@log  = LOG.instance
	
		#A recursive lambda function the returns flat level of 2 tuples for any level of nesting
		#It checks if an element is lenght 2 and does not contain arrays. Passing this check will cause the element to be stored, failing will cause a recursive call.
		tuples = lambda {|store,current| current.length == 2 and current.select{|dummy| dummy.class == Array}.empty? ? store.push(current) : current.each{|future| tuples.call(store,future)}}

		begin
			stdin, stdout, stderr = Open3.popen3("#{$options[:loclshw]} -numeric -c #{@flag}")
			raise(BinaryNotFound, "lshw") unless stderr.readlines.join(" ").scan(/No such file or directory/).empty?
		rescue BinaryNotFound => e
			@log.fatal("Component.lshw_arr: #{e.class} #{e.message}")
			@log.fatal("Component.lshw_arr: called by #{caller}")
			raise
		end

		@data = stdout.readlines.join(" ").split(/\*-/).map{|str| str.scan(/(\S.*?):(.*$)/)}.select{|arr| !arr.empty?}
		@log.debug("LshwData: found #{@data.length} hits for flag #{@flag}")
	end

	attr_reader :data, :flag 
end

class LsusbData
	def initialize()
	#Returns an Array of lines from lsusb output
		@log  = LOG.instance
		begin
			stdin, stdout, stderr = Open3.popen3("#{$options[:loclsusb]}")
			raise(BinaryNotFound, "lsusb") unless stderr.readlines.join(" ").scan(/No such file or directory/).empty?
		rescue BinaryNotFound => e
			@log.fatal("Component.lshw_arr: #{e.class} #{e.message}")
			@log.fatal("Component.lshw_arr: called by #{caller}")
			raise
		end

		@data = stdout.readlines.map{|str| str.match(/Bus\s(\d*)\sDevice\s(\d*):\sID\s(\w*:\w*)(.*$)/).captures}
		@log.debug("LsusbData: found #{@data.length} hits")
	end
	attr_reader :data
end

class System 
	#container class for System Data: Motherboard, CPU, Memory, Disk
	def initialize()
		@log=LOG.instance

		#extract the Memory Size
		mem = LshwData.new("memory").data.select{|x| Tools.contains?("System Memory",x)}
		mem_hold = Array.new
		Tools.dig("size",mem_hold,mem)
		@memory = mem_hold.flatten.map{|d| d.strip}.last

		#extract the CPU clock speed and product string
		cpu = LshwData.new("cpu").data.select{|x| Tools.contains?("slot",x)}
		cpu_hz_hold = Array.new
		Tools.dig("size",cpu_hz_hold,cpu)
		@cpu_hz = cpu_hz_hold.flatten.map{|d| d.strip}.last

		cpu_vend = Array.new
		Tools.dig("vendor",cpu_vend,cpu)
		cpu_vend.flatten!.map!{|d| d.strip}

		cpu_prod = Array.new
		Tools.dig("product",cpu_prod,cpu)
		cpu_prod.flatten!.map!{|d| d.strip}
		
		cpu_ver = Array.new
		Tools.dig("version",cpu_ver,cpu)
		cpu_ver.flatten!.map!{|d| d.strip}

		@cpu_type = cpu_vend.last + " " + cpu_prod.last + " " + cpu_ver.last
	end

	attr_reader :memory, :cpu_hz, :cpu_type
end

if __FILE__ == $0
	$options = Hash.new()
	$optparse = OptionParser.new do |opts|
		#Banner
		opts.banner = "Collects infromation about the systems and updates The SQL database: Gathrer.rb [options]"

		#debug check
		$options[:debug] = false
		opts.on('-d','--debug','Enable Debug messages (default: false)') do
			$options[:debug] = true
		end

		#Log File Location
		$options[:logfile] = nil
		opts.on('-l','--logfile FILE','Where to store the log file (default: STDOUT)') do |file|
			$options[:logfile] = file
		end

		#LSHW location
		$options[:loclshw] = '/usr/bin/lshw'
		opts.on('-L','--lshw FILE','location of lshw executeable (default: /usr/bin/lshw)') do |file|
			$options[:loclshw] = file
		end

		#LSUSB location
		$options[:loclsusb] = '/usr/sbin/lsusb'
		opts.on('-U','--lsusb FILE','location of lsusb executeable (default: /usr/sbin/lsusb)') do |file|
			$options[:loclsusb] = file
		end

		#HOSTNAME location
		$options[:lochostname] = '/bin/hostname'
		opts.on('-H','--hostname FILE','location of hostname executeable (default: /bin/hostname)') do |file|
			$options[:lochostname] = file
		end

		#HOSTNAME location
		$options[:locdate] = '/bin/date'
		opts.on('-D','--date FILE','location of date executeable (default: /bin/date)') do |file|
			$options[:locdate] = file
		end

		#DB host
		$options[:dbserver] = "http://internal1.orbit-lab.org:5053/inventory/"
		opts.on('-R','--restdb server','name of the Restfull Database server') do |server|
			$options[:dbserver] = server
		end

		# This displays the help screen, all programs are
		# assumed to have this option.
		opts.on( '-h', '--help', 'Display this screen' ) do
			puts opts
			exit
		end
	end
	$optparse.parse!

	#Log Initalise
	log = LOG.instance
	log.info("Main: Begin Gatherer.rb - For more information check www.orbit-lab.org")
	if $options[:logfile]
		log.info("Main: Diverting output to #{$options[:logfile]}")
		log.set_file($options[:logfile]) 
	end
	if $options[:debug]
		log.set_debug 
		log.debug("Options specfied are \n#{$options.to_a.join("\n")}")
	end

	begin
		#need to know the node name before you instantiate the DB	
		nd = NodeData.instance
	
		#now that we know the fqdn, we can make a DBhleper	
		db = DBhelper.new($options[:dbserver],nd.fqdn)

		#then use that db helper to checkin
		db.check_in(nd.now)

		sys = System.new()
		puts sys.memory
		puts sys.cpu_hz
		puts sys.cpu_type

	ensure	
		#Must close connection reguardless of results. 
		puts "Script done."
		log.close
	end
end
