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
		#Check if the attribute exists first, delete it if it does. 
		del_attr(name) unless get_attr(name).nil?
		if value.nil?
			return @db.add_attr(@node,name,"N/A")
		else
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
		@memory = Tools.dig("size",mem).last.strip

		#extract the CPU clock speed and product string
		#TODO figure out how to count CPU's
		cpu = LshwData.new("cpu").data.select{|x| Tools.contains?("slot",x)}
		@cpu_hz = Tools.dig("size",cpu).last.strip
		cpu_vend = Tools.dig("vendor",cpu).last.strip
		cpu_prod = Tools.dig("product",cpu).last.strip
		cpu_ver = Tools.dig("version",cpu).last.strip
		@cpu_type = cpu_vend + " " + cpu_prod + " " + cpu_ver

		#extract the disk data
		disk = LshwData.new("disk")
		@hd_size = Tools.dig("size",disk.data).last.strip
		@hd_sn = Tools.dig("serial",disk.data).last.strip

		#extract the motherboard serial number 
		@mb_sn = nil
		mb = LshwData.new("system")
		uuid_str = Tools.dig("uuid",mb.data).last
		@mb_sn = uuid_str.match(/uuid=(.*$)/).captures.first.strip unless uuid_str == nil
	end

	def update(db)
		#db is a DBhelper object that is used to push updated values of the data to the Rest DBa
		data  = ["memory","cpu_hz","cpu_type","hd_size","hd_sn"].zip([@memory,@cpu_hz,@cpu_type,@hd_size,@hd_sn])
		if @mb_sn.nil?
			return  data.map{|arr| db.add_attr(arr[0],arr[1])}.join(" ") + db.add_attr("mb_sn","unknown")
		else
			return  data.map{|arr| db.add_attr(arr[0],arr[1])}.join(" ") + db.add_attr("mb_sn",@mb_sn)
		end

	end

	attr_reader :memory, :cpu_hz, :cpu_type, :hd_size, :hd_sn, :mb_sn
end

class Network
	#container class for all of the network interface information
	def initialize()
		@log=LOG.instance

		net = LshwData.new("network")
		#collect mac address by diging the serial keword then rejecting the actual word serial (since we're flattening the tuples).
		macs =  Tools.dig("serial",net.data).reject{|x| x.match(/serial/)}.map{|x| x.strip}

		#pair the mac with the array of extracted data it came from
		rawdata = macs.map{|mac| [mac,Tools.tuples(net.data.select{|arr| Tools.contains?(mac,arr)})]}

		#extract out the chipset identifcation information
		@interfaces = rawdata.map{|x| [x[0],Tools.dig("product",x[1]).last.strip + " " + Tools.dig("vendor",x[1]).last.strip,Tools.dig("logical name",x[1]).last.strip]}
	end

	def update(db)
		#db is a DBhelper object that is used to push updated values of the data to the Rest DBa
		return @interfaces.each_with_index.map{|x,i| db.add_attr("if#{i}_mac",x[0]) + " " + db.add_attr("if#{i}_type",x[1]) + " " + db.add_attr("if#{i}_name",x[2])}.join(" ")
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
		rawdata	=  LsusbData.new().data.reject{|x| Tools.contains?("ATEN International",x) or Tools.contains?("Linux Foundation",x)}

		#all we care about are the device names, lsusb output should be fairly constant
		unless rawdata.empty?
			@devices = rawdata.map{|x| x[3].strip} 
			@log.debug("USB: Actual devices found: #{@devices.length}. They are:\n#{@devices.join("\n")}")
		end
	end

	def update(db)
		if @devices.nil?
			return nil
		else
			return @devices.each_with_index.map{|x,i| db.add_attr("usb#{i}_type",x)}.join(" ")
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
		log.debug(sys.update(db))
		log.info("Main: System data update complete")

		net = Network.new()
		log.debug(net.update(db))
		log.info("Main: Network data update complete")

		usb = USB.new()
		log.debug(usb.update(db))
		log.info("Main: USB data update complete")

	ensure	
		#Must close connection reguardless of results. 
		puts "Main:Script done."
		log.close
	end
end
