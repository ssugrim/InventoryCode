#!/usr/bin/ruby1.8 -w
# gatherer.rb version 3.9 - Gathers information about varius system data, and updates the web based inventory via a Rest wrapper.
#
#Smart support, upadted restdb interface with time out support

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
	attr_accessor :cmd
	def initialize(message = nil, cmd = nil)
		super(message)
		self.cmd = cmd
	end
end

class ExecError < StandardError
	attr_accessor :error,:cmd
	def initialize(message = nil, cmd = nil, error = nil)
		super(message)
		self.error = error
		self.cmd = cmd
	end
end

class InterfaceDoesNotExist < StandardError
	attr_accessor :name
	def initialize(message = nil, name = nil)
		super(message)
		self.name = name
	end
end

class Tools
	#a tool class of common functions, net necissarly beloning to any other class
	@@log=LOG.instance
	def self.run_cmd(cmd)
		begin
			#run command with popen3
			stdin, stdout, stderr = Open3.popen3(cmd)
			#collect any stderr
			error = stderr.readlines.join(" ")

			#raise an exception if the binary is not found 
			raise BinaryNotFound.new("#{cmd} failed",cmd) unless error.scan("No such file or directory").empty?

			#raise exception if there is any error output
			raise ExecError.new("Exec Error",cmd, error) unless error.empty?
		rescue BinaryNotFound => e
			@@log.fatal("Tools.run_cmd: #{e.class} #{e.message} \n #{e.cmd}")
			@@log.fatal("Tools.run_cmd: called by #{e.caller}")
			raise
		rescue ExecError => e
			@@log.fatal("Tools.run_cmd: Execution error\n#{e.error} \n in command \n #{e.cmd}") 
			raise
		end
		return stdout
	end
end


class DBhelper
	#This helper contains answers to db questions that are not necissarily part of the node information (e.g name of the invetory host). It operates on a generic "resource" which could be a node,
	#or a device. There is no node add/delete option as the node resouce should never be deleted (it contains non-inventory information). There are add/delete device methods since those are 
	#purely inventory information and should be under the control of this program. 
	
	def initialize(host,node,prefix,timeout)
		#host and node are strings, they are the hostname of the DB server and the fqdn of the node this code is running on respectively. 
		#prefix is a string, the prefix that will be appeneded to each added attribute. 
		@log = LOG.instance
		@prefix = prefix
		@node = node
		@timeout = timeout

		#web data cache, only created if needed.
		@dev_count = 0
		
		#make a database object and set he prefix
		retries = 0
		begin	
			@db = Database.new(host,@timeout)
			@db.set_prefix(prefix)
		rescue => e
				@log.fatal("Could not connet to DB server #{host}")
		end
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
			#collect  System data
			@log  = LOG.instance
			@fqdn = Tools.run_cmd("#{$options[:lochostname]} -f").readlines.join(" ").chomp
			@now = Tools.run_cmd( "#{$options[:locdate]} +'%T;%D'").readlines.join.split(";").join(" ").chomp
			@log.debug("Os said the fqdn was #{@fqdn}, and the date/time is #{@now}")
			md = @fqdn.match(/node(\d+)-(\d+)./)
			@x,@y = md.captures unless md.nil?
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


		@data = Tools.run_cmd("#{$options[:loclshw]} -numeric -c #{@flag}").readlines.join(" ").split(/\*-/).map{|str| str.scan(/(\S.*?):(.*$)/)}.select{|arr| !arr.empty?}
		@log.debug("LshwData: found #{@data.length} hits for flag #{@flag}")
	end

	attr_reader :data, :flag 
end

class LsusbData
	def initialize()
	#Returns an Array of lines from lsusb output
		@log  = LOG.instance
		@data = Tools.run_cmd("#{$options[:loclsusb]}").readlines.map{|str| str.match(/\s*(\S{1,4}:\S{1,4})(.*$)/).captures}
		@log.debug("LsusbData: found #{@data.length} hits")
	end
	attr_reader :data
end

class Interface
	def initialize(name)
		#name, ip and netmask are string, the name of the intefrace refers to the expected enmeration name (usually "eth" something). The ip and netmask 
		#should be in dot quad notation, but as a string. Up is a bool, true if the interface is determined to be up
		@log  = LOG.instance
		@name = name
		@up = false
		@ip = nil
		@netmask = nil

		#check if the interface exists
		raise InterfaceDoesNotExist.new("Interface does not exits",name) if Tools.run_cmd("#{$options[:locifconfig]} -a").readlines.join.scan(name).empty?
		check_up()
	end

	attr_reader :name,:up,:ip,:netmask

	def check_up()
		#check if interface is up, or and if it has an address
		@up = false
		@ip = nil
		@netmask = nil

		ifcondata = Tools.run_cmd("#{$options[:locifconfig]}").readlines.join
		@up = true unless ifcondata.scan(@name).empty?
		@ip,@netmask = ifcondata.match(/#{Regexp.escape(@name)}.*?inet addr:(\d+.\d+.\d+.\d+).*?Mask:(\d+.\d+.\d+.\d+)/m).captures if @up
		return @up
	end

	def set_ip(ip,netmask)
		#set the ip address and netmask, should bring the interface up if it is down.
		Tools.run_cmd("#{$options[:locifconfig]} #{@name} #{ip} netmask #{netmask}")
		check_up()
	end
end

class PingData
	#Returns the average ping time from the interface, This should be wrapped in a begin block that discards any errors, as it may be very prone to mistakes.
	def initialize()
		@log  = LOG.instance
		#get the current eth1 ip
		if1 = Interface.new("eth1")	
		eth1_ip = if1.ip.match(/(\d+).(\d+).(\d+).(\d+)/).captures
		@log.debug("PingData: eth1 address #{eth1_ip.join(".")}")

		#set the eth0 ip, eth0's ip should be eth1's ip with the second quad incremented by 10 unless it's over 40, then increment by 1
		eth0_ip = Array.new(4){|i|
			if i == 1 
				if eth1_ip[i].to_i >= 40
					eth1_ip[i].to_i + 1
				else
					eth1_ip[i].to_i + 10
				end
			else
				eth1_ip[i].to_i
			end
		}
		if0 = Interface.new("eth0")
		if0.set_ip(eth0_ip.join("."),"255.255.0.0")


		@log.debug("PingData: eth0 address #{eth0_ip.join(".")}")
		
		#compute the firewalls address from mine. It should match in the first 2 quads and be 0.1 in the last two
		server = Array.new(4){|i| 
			case i
			when 2
				0
			when 3
				1
			else
				eth0_ip[i].to_i
			end
		}
		@log.debug("PingData: server address #{server.join(".")}")
	
		#the actual ping. regex out the average, that's our data
		sleep(20)
		@data = Tools.run_cmd("#{$options[:locping]} -c 10 #{server.join(".")}").readlines.join.match(/min\/avg\/max\/mdev\s=\s\d+.\d+\/(\d+.\d+)\/\d+.\d+\/\d+.\d+/).captures.join
		@log.debug("PingData: Average ping time was #{data}")
	end
	attr_reader :data
end

class USRPData
	#Data about attached USRP's collected from the UHD
	def initialize()
		@log = LOG.instance
		@type =  nil
		@serial = nil
		@uhd_version = nil
		@daughters = nil
		@id = nil
		if2 = nil

		begin
			#set the communciation interface ip through which we talk to the usrp
			if2 = Interface.new("eth2")
			if2.set_ip("192.168.10.1","255.255.255.0")
		rescue InterfaceDoesNotExist => e
			#there may be no eth2 in the case of USRP1, so this is not a critical error
			@log.warn("Was not able to find interface #{e.name}")
		end

		data = nil
		retries = 0
		begin
			#locate the usrp using the uhd_usrp_probe, this may require a couple of tries
			data = Tools.run_cmd("#{$options[:locuhd]}").readlines.join("\n")
		rescue ExecError => e
			#if no uhd was found, output will goto stderr and will trigger an ExecError. 
			if e.error.scan("No devices found")
				if retries > 3
					@log.debug("No USRP found")
				else
					@log.debug("Failed to find usrp on try #{retries}")
					sleep(10)
					retries += 1
					retry
				end
			else
				raise
			end
		end

		unless data.nil?
			@uhd_version = data.scan(/(UHD_.*$)/)
			@type = data.scan(/Device:\s+(.*)$/)
			@serial = data.scan(/serial:\s+(.*)$/)
			@daughters = data.scan(/ID:\s+(.*)$/)
			if @type.join.include?("USRP1")
				@id = "FFFE:0002"
			elsif @type.join.include?("USRP2")
				@id = "FFFE:0003"
			else
				@id = "FFFE:0000"
			end
		end
	end
	attr_reader :type,:serial,:daughters,:uhd_version,:id
end

class BenchData
	#benchmark data
	def initialize()
		#Times the computation for the first 2000 primes. A Benchmark to compare CPU's
		@log  = LOG.instance

		@data = Tools.run_cmd("#{$options[:locbench]} --test=cpu --cpu-max-prime=2000 run").readlines.join.match(/execution time \(avg\/stddev\)\:\s+(\d+.\d+)\//).captures.first
		@log.debug("BenchMark: value #{@data}")
	end
	attr_reader :data
end

class DiskData
	def initialize()
		@log  = LOG.instance

		#dig out the size and sn from lshw
		get_data = lambda {|name, array| dat = Tools.dig(name,array).flatten.last; return dat.nil? ? nil : dat.strip}
		disk = LshwData.new("disk")
		@hd_size = get_data.call("size",disk.data)
		@hd_sn = get_data.call("serial",disk.data)

		#get the model from smartctl
		@hd_model = Tools.run_cmd("#{$options[:loclsmart]} -a #{$options[:locdiskdev]}").readlines.join.scan(/[Mm]odel.*?:\s*(.*)$/).first
		@log.debug("Disk model was #{@hd_model}")
	end
	attr_reader :hd_size, :hd_sn, :hd_model
end

class System 
	#container class for System Data: Motherboard, CPU, Memory, Disk
	def initialize()
		@log=LOG.instance

		get_data = lambda {|name, array| dat = Tools.dig(name,array).flatten.last; return dat.nil? ? nil : dat.strip}

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
		disk = DiskData.new()
		@hd_size = disk.hd_size
		@hd_sn = disk.hd_sn
		@hd_model = disk.hd_model

		#extract the motherboard serial number 
		mb = LshwData.new("system")
		uuid_str = get_data.call("uuid",mb.data)
		@mb_sn = uuid_str.nil? ? nil : uuid_str.match(/uuid=(.*$)/).captures.first.strip 

		#try to ping the fire wall, but don't worry about if it fails
		begin
			@fw_ping = PingData.new.data
		rescue
			@log.debug("System.new: PingData encountered an error")
			@fw_ping = "Unable to get data"
		end
	end

	def update(db)
		#db is a DBhelper object that is used to push updated values of the data to the Rest DB
		data  = ["memory","cpu_hz","cpu_type","hd_size","hd_sn","mb_sn","cpu_bench","fw_ping","hd_model"].zip([@memory,@cpu_hz,@cpu_type,@hd_size,@hd_sn,@mb_sn,@cpu_bench,@fw_ping,@hd_model])
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
		rawdata	=  LsusbData.new().data.reject{|x| Tools.contains?("ATEN International",x) or Tools.contains?("Linux Foundation",x) or Tools.contains?("Intel Corp. Integrated Rate Matching Hub",x)  or Tools.contains?("FFFE:0002",x) or Tools.contains?("fffe:0002",x)}
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
			#TODO make str_cln part of the Tools class
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

class USRP
	#container class since there may be more than one datum, but they should all be updated via a single cmd
	def initialize()
		@log=LOG.instance
		@usrp_data = USRPData.new()
	end

	def update(db)
		if @usrp_data.type.nil?
			@log.warn("No USRP found")
			return nil 
		end
		dev_name = db.add_dev()
		s0 = db.add_attr(dev_name,"dev_id",@usrp_data.id)
		s1 = db.add_attr(dev_name,"dev_type",@usrp_data.type)
		s2 = db.add_attr(dev_name,"serial",@usrp_data.serial)
		s3 = db.add_attr(dev_name,"uhd_version",@usrp_data.uhd_version)
		count = 0
		s4 = @usrp_data.daughters.map{|str| 
			count += 1
			db.add_attr(dev_name,"daughter_board_#{count}",str)
		}
		return ["Dev added #{dev_name}",s0,s1,s2,s3,s4].flatten.join(" ")
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

		#Database timeout
		$options[:timeout] = 90
		opts.on('-T','--timeout TIMEOUT','Database time out (default: 90)') do |tm|
			$options[:timeout] = tm
		end

		#Primary disk name 
		$options[:locdiskdev] = '/dev/sda'
		opts.on('-D','--diskdev FILE','location of Disk Device (default: /dev/sda)') do |file|
			$options[:locdiskdev] = file
		end

		#Smartmontool location
		$options[:loclsmart] = '/usr/sbin/smartctl'
		opts.on('-S','--smrt FILE','location of smartctl executeable (default: /usr/sbin/smartctl)') do |file|
			$options[:loclsmart] = file
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

		#ifconfig location
		$options[:locifconfig] = '/sbin/ifconfig'
		opts.on('-I','--ifcon FILE','location of ifconfig (default: /sbin/ifconfig)') do |file|
			$options[:locifconfig] = file
		end

		#ping location
		$options[:locping] = '/bin/ping'
		opts.on('-P','--ping FILE','location of ping (default: /bin/ping)') do |file|
			$options[:locping] = file
		end

		#uhd location
		$options[:locuhd] = '/usr/local/bin/uhd_usrp_probe'
		opts.on('-P','--uhd FILE','location of uhd usrp probe binary (default: /usr/local/bin/uhd_usrp_probe)') do |file|
			$options[:locuhd] = file
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
		db = DBhelper.new($options[:dbserver],nd.fqdn,$options[:prefix],$options[:timeout])
		
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

		#update usrp
		usrp = USRP.new()
		usrp.update(db)
		log.info("Main: USRP data update complete")

		#then use that db helper to checkin
		log.info("Main: Checking in")
		db.check_in(nd.now)

	ensure	
		#Must close connection reguardless of results. 
		puts "Main:Script done."
		log.close
	end
end
