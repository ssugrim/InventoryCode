#!/usr/bin/ruby1.8 -w
# gatherer.rb version 3.5 - Gathers information about varius system data, and updates the web based inventory via a Rest wrapper.
#
#Adding prefix support, the attribute name creation should occur at the point where the attribute is being populated (the most complete information about what the name should be is there), it is at this 
#point that the prefix should be decided upon. Most of the time it will default to $options[:prefix], but it could be diffrent

#TODO detect USRP2 via usrp scripts
#TODO Count CPU cores?
#TODO Check hard disk status with Smart Tool
#TODO perhaps search of products that are not paired with a mac 

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


class DBhelper
	#This helper contains answers to db questions that are not necissarily part of the node information (e.g name of the invetory host). It operates on a generic "resource" which could be a node,
	#or a device. There is no node add/delete option as the node resouce should never be deleted (it contains non-inventory information). There are add/delete device methods since those are 
	#purely inventory information and should be under the control of this program. 
	
	def initialize(host,node,prefix)
		#host and node are strings, they are the hostname of the DB server and the fqdn of the node this code is running on respectively. 
		#prefix is a string, the prefix that will be appeneded to each added attribute. 
		@log = LOG.instance
		@db = Database.new(host,prefix)
		@prefix = prefix
		@node = node

		#web data cache, only created if needed.
		@dev_count = 0
	end

	attr_reader :node,:dev_count

	def get_attr(resource,name=nil)
		#resouce is a string, the name of the resouce that hold the attrbute. name is a string, the name of the attribute you want the value for. 
		#This will return all the instances of the attribute name you were looking for. There may be more than
		#one value, the caller will have to check the values for sanity. This should alway return an array, but it might be empty.
	
		#populate cache if empty	
		webdata =  @db.get_attr(resource)

		#look for the attribute name in the array
		return webdata if name.nil?
		return Tools.dig(name,webdata)
	end

	def del_attr(resource,name)
		#resouce is a string, the name of the resouce that hold the attrbute.
		#name is a string, the attribute name to be deleted
		return	@db.del_attr(resource,name)
	end

	def del_all_attr(resource)
		#resouce is the resource to have it attrbutes dumped
		begin
			return @db.del_all_attr(resource)
		rescue DelAttrError => e
			if e.message.match(/No resource\/attribute match/).nil?
				raise
			else
				@log.debug("Attributes already deleted, proceeding")
			end
		end
	end
	
	def add_attr(resource,name,value)
		#resource, name, and value are strings. Resouce is the name of the resouce to have the attribute added to it. Name is the name of the attribute to be added, and Value is it's value
		#Names will be prefixed with @prefix
		sub_name = @prefix + name
		if value.nil? or value.empty?
			return @db.add_attr(resource,sub_name,"N/A")
		else
			return @db.add_attr(resource,sub_name,value)
		end
	end

	def check_in(now)
		#now is a string, the current time stamp. Adds the check_in feild to the node we are acting on.
		#NOTE: the rest api, and add_attr by extension does not like the white space that comes out of the date program output. It will need to be sanitized
		add_attr(@node,"check_in",now)
		return true
	end

	def add_dev()
		#adds a new device resouce, and a relation to the existing node of the form fqdn_dev_unique#. returns the name added. 
		sub_res = @node + "_dev_#{@dev_count}"
		@db.add_resource(sub_res,"device")
		@db.add_relation(@node,sub_res)
		@dev_count += 1
		return sub_res
	end

	def del_devs()
		#dumps all the devices beloning to a specfic node.
		@db.del_resource(@node + "_dev_*")
		@dev_count = 0
		return true
	end

	def list_devs()
		#Returns a list of devices attached to this node
		return @db.list_relation(@node)
	end
end

class NodeData
	include Singleton
	#Node identification information
	def initialize()
		begin
			@log  = LOG.instance

			stdin, stdout, stderr = Open3.popen3("#{$options[:lochostname]} -f")
			raise(BinaryNotFound, "hostname") unless stderr.readlines.join(" ").scan(/No such file or directory/).empty?
			@fqdn = stdout.readlines.join(" ").chomp

			stdin, stdout, stderr = Open3.popen3("#{$options[:locdate]} +'%T;%D'")
			raise(BinaryNotFound, "Date") unless stderr.readlines.join(" ").scan(/No such file or directory/).empty?
			@now = stdout.readlines.join.split(";").join(" ").chomp

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

		@data = stdout.readlines.map{|str| str.match(/\s*(\S{1,4}:\S{1,4})(.*$)/).captures}
		@log.debug("LsusbData: found #{@data.length} hits")
	end
	attr_reader :data
end

class BenchData
	def initialize()
	#Returns an Array of lines from lsusb output
		@log  = LOG.instance
		begin
			stdin, stdout, stderr = Open3.popen3("#{$options[:locbench]} --test=cpu --cpu-max-prime=2000 run")
			raise(BinaryNotFound, "sysbench") unless stderr.readlines.join(" ").scan(/No such file or directory/).empty?
		rescue BinaryNotFound => e
			@log.fatal("Component.lshw_arr: #{e.class} #{e.message}")
			@log.fatal("Component.lshw_arr: called by #{caller}")
			raise
		end

		@data = stdout.readlines.join.match(/execution time \(avg\/stddev\)\:\s+(\d+.\d+)\//).captures.first
		@log.debug("BenchMark: value #{@data}")
	end
	attr_reader :data
end

class System 
	#container class for System Data: Motherboard, CPU, Memory, Disk
	def initialize()
		@log=LOG.instance

		get_data = lambda {|name, array| return Tools.dig(name,array).flatten.last.strip}

		#extract the Memory Size
		mem = LshwData.new("memory").data.select{|x| Tools.contains?("System Memory",x)}
		@memory = get_data.call("size",mem)

		#extract the CPU clock speed and product string
		#TODO figure out how to count CPU's
		cpu = LshwData.new("cpu").data.select{|x| Tools.contains?("slot",x)}
		@cpu_hz = get_data.call("size",cpu)
		cpu_vend = get_data.call("vendor",cpu)
		cpu_prod = get_data.call("product",cpu)
		cpu_ver = get_data.call("version",cpu)
		@cpu_type = (cpu_vend.nil? ? String.new : cpu_vend) + " " + (cpu_prod.nil? ? String.new : cpu_prod) + " " + (cpu_ver.nil? ? String.new : cpu_ver)

		@cpu_bench =  BenchData.new.data

		#extract the disk data
		disk = LshwData.new("disk")
		@hd_size = get_data.call("size",disk.data)
		@hd_sn = get_data.call("serial",disk.data)

		#extract the motherboard serial number 
		@mb_sn = nil
		mb = LshwData.new("system")
		uuid_str = get_data.call("uuid",mb.data)
		@mb_sn = uuid_str.match(/uuid=(.*$)/).captures.first.strip unless uuid_str == nil
	end

	def update(db)
		#db is a DBhelper object that is used to push updated values of the data to the Rest DB
		data  = ["memory","cpu_hz","cpu_type","hd_size","hd_sn","mb_sn","cpu_bench"].zip([@memory,@cpu_hz,@cpu_type,@hd_size,@hd_sn,@mb_sn,@cpu_bench])
		return  data.map{|arr| db.add_attr(db.node,arr[0],arr[1])}.join(" ")

	end

	attr_reader :memory, :cpu_hz, :cpu_type, :hd_size, :hd_sn, :mb_sn
end

class Network
	#container class for all of the network interface information
	def initialize()
		@log=LOG.instance

		get_data = lambda {|name, array| 
			data =  Tools.dig(name,array).flatten.last
			data.nil? ? nil : data.strip
		}

		net = LshwData.new("network")
		#collect mac address by diging the serial keword then rejecting the actual word serial (since we're flattening the tuples).
		macs =  Tools.dig("serial",net.data).flatten.reject{|x| x.match(/serial/)}.map{|x| x.strip}

		#pair the mac with the array of extracted data it came from
		rawdata = macs.map{|mac| [mac,Tools.tuples(net.data.select{|arr| Tools.contains?(mac,arr)})]}

		#extract out the chipset identifcation information
		ifdata = rawdata.map{|x| 
			prod_data = get_data.call("product",x[1])
			if prod_data.nil?
				@log.debug("Network.initialize: Couldn't get product id for #{x[0]}, dropping it")
				nil
			else
				[x[0], get_data.call("logical name",x[1]), get_data.call("vendor",x[1]), prod_data]
			end
		}.compact

		#lambda to convert nils to empty strings and strip off white spaces
		str_cln = lambda {|x| if x.nil? then  return String.new() else  return x.strip end }

		#lambda to extract vendor/product tags as a 4 digit hex
		#Note, this will throw a nil exception if it finds a mac, but not a product description with numeric identifier
		get_id = lambda {|x| return x.match(/(\S{1,4}):(\S{1,4})/).captures.map{|y| sprintf("%04X",y.hex)}.join(":")}
		
		#apply lambdas to each interface
		@interfaces = ifdata.map{|x| [x[0], str_cln.call(x[1]), str_cln.call(x[2]), str_cln.call(x[3]), get_id.call(x[3])]}
	end

	def update(db)
		#db is a DBhelper object that is used to push updated values of the data to the Rest DBa
		return @interfaces.map{|x| 
			dev_name = db.add_dev()
			s1 = db.add_attr(dev_name,"if_mac",x[0])
		       	s2 = db.add_attr(dev_name,"if_name",x[1])
			s3 = db.add_attr(dev_name,"dev_type",x[2] + x[3])
			s4 = db.add_attr(dev_name,"dev_id",x[4]) 
			["Dev added #{dev_name}",s1,s2,s3,s4].join(" ")
		}.join(" ")
	end

	attr_reader :interfaces
end

class USB
	#container for USB information
	def initialize()
		@log=LOG.instance
		
		@devices = nil
		#extract usb data
		#there should be any multi level nesting, drop any kvm or Internal USB hub records
		rawdata	=  LsusbData.new().data.reject{|x| Tools.contains?("ATEN International",x) or Tools.contains?("Linux Foundation",x) or Tools.contains?("Intel Corp. Integrated Rate Matching Hub",x) }
		#all we care about are the device names, lsusb output should be fairly constant
		unless rawdata.empty?
			@devices = Tools.tuples(rawdata)
			@log.debug("USB: Actual devices found: #{@devices.length}. They are:\n#{@devices.join("\n")}")
		end
	end

	def update(db)
		#db is a DBhelper object that is used to push updated values of the data to the Rest DBa
		if @devices.nil?
			@log.debug("USB: Nothing to update")
			return nil
		else
			#lambda to extract vendor/product tags as a 4 digit hex
			#Note, this will throw a nil exception if it finds a mac, but not a product description with numeric identifier
			get_id = lambda {|x| return x.match(/(\S{1,4}):(\S{1,4})/).captures.map{|y| sprintf("%04X",y.hex)}.join(":")}

			#lambda to convert nils to empty strings and strip off white spaces
			str_cln = lambda {|x| if x.nil? then  return String.new() else  return x.strip end }

			return @devices.map{|x| 
				dev_name = db.add_dev()
				s1 = db.add_attr(dev_name,"dev_type",str_cln.call(x[1]))
				s2 = db.add_attr(dev_name,"dev_id",get_id.call(x[0]))
				["Dev added #{dev_name}",s1,s2].join(" ")
			}
		end
	end
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
		$options[:loclsusb] = '/usr/bin/lsusb'
		opts.on('-U','--lsusb FILE','location of lsusb executeable (default: /usr/sbin/lsusb)') do |file|
			$options[:loclsusb] = file
		end

		#Sysbench location
		$options[:locbench] = '/usr/bin/sysbench'
		opts.on('-b','--bench FILE','location of sysbench executeable (default: /usr/bin/sysbench)') do |file|
			$options[:locbench] = file
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
		$options[:dbserver] = "http://internal1.orbit-lab.org:5054/inventory/"
		opts.on('-R','--restdb server','name of the Restfull Database server') do |server|
			$options[:dbserver] = server
		end

		#prefix
		$options[:prefix] = "INV_"
		opts.on('-p','--prefix TXT','Attribute PREFIX (Default = INV_)') do |prefix|
			$options[:prefix] = prefix
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
		db = DBhelper.new($options[:dbserver],nd.fqdn,$options[:prefix])
		
		#we want to reset the node state so that it's ready to accept new data
		log.info("Main: Dumping #{$options[:prefix]} attributes for #{nd.fqdn}")
		db.del_devs()
		db.del_all_attr(db.node)
	
		#update system data	
		sys = System.new()
		sys.update(db)
		log.info("Main: System data update complete")

		#update network data	
		net = Network.new()
		net.update(db)
		log.info("Main: Network data update complete")

		#update usb data	
		usb = USB.new()
		usb.update(db)
		log.info("Main: USB data update complete")

		#then use that db helper to checkin
		log.info("Main: Checking in")
		db.check_in(nd.now)

	ensure	
		#Must close connection reguardless of results. 
		puts "Main:Script done."
		log.close
	end
end
