#!/usr/bin/ruby1.8 -w
# gatherer.rb version 3.0 - Gathers information about varius system data, and updates the web based inventory via a Rest wrapper.
#
#TODO detect USRP2 via usrp scripts
#TODO Count CPU cores?
#TODO Check hard disk status with Smart Tool
#TODO redo the Network secition to extract the 8 digit id and add it as a seprate field
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

	def del_all_attr()
		#name is a string, the attribute name to be deleted
		begin
			return	@db.del_all_attr(@node)
		rescue DelAttrError => e
			e.message.match(/nothing to delete/).nil? ? raise : @log.warn("Attributtes were already deleted, Ignoring exception")
		end

	end
	
	def add_attr(name,value)
		#name, value are strings. name is the name of the attribute to be added, and value is it's value
		#Check if the attribute exists first, delete it if it does. 
		if value.nil? or value.empty?
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

		@data = stdout.readlines.map{|str| str.match(/\s*(\S{1,4}:\S{1,4})(.*$)/).captures}
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
		@cpu_type = (cpu_vend.nil? ? String.new : cpu_vend) + " " + (cpu_prod.nil? ? String.new : cpu_prod) + " " + (cpu_ver.nil? ? String.new : cpu_ver)

		#Simplified tag for searching purposes	
		case 
		when @cpu_type.match(/i7/)
			@cpu_tag = "i7"
		when @cpu_type.match(/i5/)
			@cpu_tag = "i5"
		when @cpu_type.match(/Q8400/)
			@cpu_tag = "c2q"
		when @cpu_type.match(/c3|C3/)
			@cpu_tag = "C3"
		when @cpu_type.match(/atom|Atom|ATOM/)
			@cpu_tag = "Atom"
		when @cpu_type.match(/AMD|amd/)
			@cpu_tag = "AMD"
		else
			@cpu_tag = "Unknown"
		end

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
		data  = ["memory","cpu_hz","cpu_type","hd_size","hd_sn","mb_sn","cpu_tag"].zip([@memory,@cpu_hz,@cpu_type,@hd_size,@hd_sn,@mb_sn,@cpu_tag])
		return  data.map{|arr| db.add_attr(arr[0],arr[1])}.join(" ")

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
		ifdata = rawdata.map{|x| [x[0], Tools.dig("logical name",x[1]).last, Tools.dig("vendor",x[1]).last, Tools.dig("product",x[1]).last]}

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
		return @interfaces.each_with_index.map{|x,i| 
			db.add_attr("if_mac_#{i}",x[0]) + " " + db.add_attr("if_name_#{i}",x[1]) + db.add_attr("if_type_#{i}",x[2] + x[3]) + " " + db.add_attr("if_id_#{i}",x[4]) 
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
			@devices = Tools.tuples_alt(rawdata)
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

			return @devices.each_with_index.map{|x,i| db.add_attr("usb_id_#{i}",get_id.call(x[0])) + " " + db.add_attr("usb_type_#{i}",str_cln.call(x[1])) }.join(" ")
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
		$options[:dbserver] = "http://internal1.orbit-lab.org:5054/inventory/"
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

		#we want to reset the node state so that it's ready to accept new data
		log.info("Main: Dumping non-infrastructure attributes for #{nd.fqdn}")
		db.del_all_attr()
	
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
