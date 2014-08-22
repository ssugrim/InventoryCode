#!/usr/bin/ruby 
# gatherer.rb version 4.3 - Gathers information about varius system data, and updates the web based inventory via a Rest wrapper.
#
#Made the network container a factory and the USRP a Strtegy. Included x310 support 

require 'optparse'
require 'open3'
require 'find'
require 'singleton'
require 'net/smtp'


require_relative 'log_wrap'
require_relative 'rest_db'

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
			error = stderr.readlines.map{|x| x.strip}.join(" ")

			#raise an exception if the binary is not found 
			raise BinaryNotFound.new("#{cmd} failed",cmd) if error.include?("No such file or directory")

			#raise exception if there is any error output
			raise ExecError.new("Exec Error",cmd, error) unless error.empty?
		rescue BinaryNotFound => e
			@@log.warn("Tools.run_cmd: #{e.class} #{e.message} \n #{e.cmd}")
			@@log.warn("Tools.run_cmd: called by #{e.caller}")
			raise
		rescue ExecError => e
			@@log.warn("Tools.run_cmd: Execution error\n#{e.error} \n in command \n #{e.cmd}") 
			raise
		end
		return stdout
	end

	def self.run_cmd_combined(cmd)
		begin
			#run command with but glue stderr and stdout into one string
			stdin, stdout, stderr = Open3.popen3(cmd)
			#convert the outputs to strings
			error = stderr.readlines.map{|x| x.strip}.join(" ")
            output = stdout.readlines.map{|x| x.strip}.join(" ")
			#raise an exception if the binary is not found 
			raise BinaryNotFound.new("#{cmd} failed",cmd) if error.include?("No such file or directory")
		rescue BinaryNotFound => e
			@@log.warn("Tools.run_cmd: #{e.class} #{e.message} \n #{e.cmd}")
			@@log.warn("Tools.run_cmd: called by #{e.caller}")
			raise
		end
		return output + error
	end

end


class DBhelper
	#This helper contains answers to db questions that are not necissarily part of the node information (e.g name of the invetory host). It operates on a generic "resource" which could be a node,
	#or a device. There is no node add/delete option as the node resouce should never be deleted (it contains non-inventory information). There are add/delete device methods since those are 
	#purely inventory information and should be under the control of this program. 
	
	def initialize(host,node,prefix,timeout,retry_limit,stagger)
		#host and node are strings, they are the hostname of the DB server and the fqdn of the node this code is running on respectively. 
		#prefix is a string, the prefix that will be appeneded to each added attribute. 
		@log = LOG.instance
		@prefix = prefix
		@node = node
		@timeout = timeout
		@retry_limit = retry_limit
		@stagger = stagger

		#web data cache, only created if needed.
		@dev_count = 0
		
		#make a database object and set he prefix
		retries = 0
		begin	
			@db = Database.new(host,@timeout,@retry_limit,@stagger)
			@db.set_prefix(prefix)
		rescue => e
				@log.fatal("Could not connet to DB server #{host}")
				raise
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
			#TODO this error is sometimes generated erroenously
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
			@fqdn = Tools.run_cmd("#{$options[:lochostname]} --all-fqdns").readlines.join(" ").scan(/(.*?\.orbit-lab.org)/).flatten.last.strip
			@now = Tools.run_cmd( "#{$options[:locdate]} +'%T;%D'").readlines.join.split(";").join(" ").chomp.strip
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

		@data = Tools.run_cmd("#{$options[:loclshw]} -numeric -c #{@flag}").readlines.join(" ").split(/\*-/).map{|str| str.scan(/(\S.*?):(.*$)/)}.select{|arr| !arr.empty?}
		@log.debug("LshwData: found #{@data.length} hits for flag #{@flag}")
	end

	attr_reader :data, :flag 
end

class LshwDataRaw
	def initialize(flag)
		#Arugments: 
		#Flag - what device class to pass to lshw (see lshw webpage)  - Mandatory
		#Returns out put of lshw -c flag as a single string with no newlines
		#Instead of generic key value pairs, this class will be used to file the lshw string with specif regex and search for specifc key words

		@flag = flag
		@log  = LOG.instance

		@data = Tools.run_cmd("#{$options[:loclshw]} -numeric -c #{@flag}").readlines.map{|x| x.strip}.join(" ")
		@log.debug("LshwDataRaw: found #{@data.length} for flag #{@flag}")
	end

	attr_reader :data, :flag 
end

class LspciData
	def initialize()
	#Returns an Array of lines from lspci output, numeric id's of all attached pci devices
		@log  = LOG.instance
		@data = Tools.run_cmd("#{$options[:loclspci]} -n").readlines.join(" ").scan(/\s?(\w{4}):(\w{4})\s?/)
		@log.debug("Lspcidata: found #{@data.length} hits")
	end
	attr_reader :data
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

class LsusbDataRaw
	def initialize()
	#Returns an Array of lines from lsusb output
		@log  = LOG.instance
		@data = Tools.run_cmd("#{$options[:loclsusb]}").readlines
		@log.debug("LsusbDataRaw.new: found #{@data.length} lines")
	end
	attr_reader :data
end

class IfaceContainer
	#A containter class for getting new interface objects. Enforces the One name per object rule
	#TODO make this a porper factory
	@@log = LOG.instance
	@@ifaces = Array.new()

	def self.get_iface(name)
		iface =  @@ifaces.detect{|x| x.name.include?(name)}
		if iface.nil?
			iface = Interface.new(name)
			@@ifaces.push(iface)
			@@log.debug("IfaceContainer.get_iface: Made an new iface #{name}, currently we have #{@@ifaces.map{|x| x.name}.join(" ")}")
			return iface
		else
			@@log.debug("IfaceContainer.get_iface: Already had an #{name}")
			return iface
		end
	end
end

class Interface
	#TODO should not be able to instantiate this directly make this a factory pattern
	def initialize(name)
		#name, ip and netmask are string, the name of the intefrace refers to the expected enmeration name (usually "eth" something). The ip and netmask 
		#should be in dot quad notation, but as a string. Up is a bool, true if the interface is determined to be up
		@log  = LOG.instance
		@name = name
		@up = false
		@ip = nil
		@netmask = nil
		@module = nil
		@mtu = nil

		#check if the interface exists
		check_up()
	end

	attr_reader :name,:up,:ip,:netmask,:module,:mtu

	def check_up()
		#check if interface is up, or and if it has an address
		@up = false
		@ip = nil
		@netmask = nil

		ifcondata = Tools.run_cmd("#{$options[:locifconfig]}").readlines.join
		@up = true if ifcondata.include?(@name)
		@ip,@netmask = ifcondata.match(/#{Regexp.escape(@name)}.*?inet addr:(\d+.\d+.\d+.\d+).*?Mask:(\d+.\d+.\d+.\d+)/m).captures if @up
		return @up
	end

	def set_ip(ip="192.168.10.1",netmask="255.255.255.0")
		#set the ip address and netmask, should bring the interface up if it is down.
		raise InterfaceDoesNotExist.new("Interface does not exits",name) unless Tools.run_cmd("#{$options[:locifconfig]} -a").readlines.join.include?(name)
		Tools.run_cmd("#{$options[:locifconfig]} #{@name} #{ip} netmask #{netmask}")
		@log.debug("Interface.set_ip: Set IP to #{ip} and netmask to #{netmask}")
		check_up()
	end

	def set_mtu(mtu="1500")
		@mtu = mtu
		#set the mtu of an inteface 
		raise InterfaceDoesNotExist.new("Interface does not exits",name) unless Tools.run_cmd("#{$options[:locifconfig]} -a").readlines.join.include?(name)
		Tools.run_cmd("#{$options[:locifconfig]} #{@name} mtu #{@mtu}")
		@log.debug("Interface.set_mtu: Mtu set to #{@mtu}")
		check_up()
	end

	def load_module(mod = "mlx4_en")
		#Loads the module via modprobe, and recrods the name for future refrence
		@module = mod
		Tools.run_cmd("#{$options[:locmodprobe]} #{@module}")
		@log.debug("Interface.load_modle: Loaded Module #{@module}")
	end

	def set_kflag()
		#Loads the module via modprobe, and recrods the name for future refrence
		Tools.run_cmd("#{$options[:locsysctl]} -w net.core.rmem_max=50000000")
		Tools.run_cmd("#{$options[:locsysctl]} -w net.core.wmem_max=1048576")
		@log.debug("Interface.set_kflag: Flags set")
	end
end

class PingData
	#Returns the average ping time from the interface, This should be wrapped in a begin block that discards any errors, as it may be very prone to mistakes.
	def initialize()
		@log  = LOG.instance
		#get the current eth1 ip
		iface1 = IfaceContainer.get_iface("eth1")	
		eth1_ip = iface1.ip.match(/(\d+).(\d+).(\d+).(\d+)/).captures
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
		iface0 = IfaceContainer.get_iface("eth0")
		iface0.set_ip(eth0_ip.join("."),"255.255.0.0")


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
	#this is a stratgey template
	def initialize()
		@log = LOG.instance
		@iface = IfaceContainer.get_iface("eth2")
		@raw_data = nil
		@data = nil
	end

	attr_reader :data, :raw_data

	def pop_data()
		#this should remain common to all classes so that we get the same address out and the process is common to all of them
		unless @raw_data.nil?
			@data = Hash.new
			@data[:uhd_version] = @raw_data.scan(/(UHD_.*$)/).flatten.first.strip
			@data[:type] = @raw_data.scan(/Device:\s+(.*)$/).flatten.first.strip
			@data[:serial] = @raw_data.scan(/serial:\s+(.*)$/).flatten.first.strip 
			@data[:mboard] = @raw_data.scan(/Mboard:\s+(.*)$/).flatten.first.strip

			case
			when @data[:mboard].include?("USRP1")
				@data[:id] = "FFFE:0002"
			when @data[:mboard].include?("USRP2")
				@data[:id] = "FFFE:0003"
			when @data[:mboard].include?("N210")
				@data[:id] = "FFFE:0004"
			when @data[:mboard].include?("X310")
				@data[:id] = "FFFE:0005"
			else
				@data[:id] = "FFFE:0000"
			end

			daughters = @raw_data.scan(/ID:\s+(.*?)\s+\(/).uniq.map{|arr|
			str = arr.flatten.first
			if str.include?("XCVR2450")
				[str, "FFFD:0001"]
			elsif str.include?("WBX")
				[str, "FFFD:0002"]
				#this is a hack to prevent mislabeling of sbx-120
			elsif str.include?("SBX-120")
				[str, "FFFD:0007"]
			elsif str.include?("SBX")
				[str, "FFFD:0003"]
			elsif str.include?("WBX, WBX + Simple GDB")
				[str, "FFFD:0004"]
			elsif str.include?("WBX v3, WBX v3 + Simple GDB")
				[str, "FFFD:0005"]
			elsif str.include?("WBX v3")
				[str, "FFFD:0006"]
			elsif str.include?("CBX-120")
				[str, "FFFD:0008"]
			else 
				[str, "FFFD:0001"]
			end
			}

			@data[:daughters] = daughters
		end
	end
end

class USRPData1G <  USRPData
	#check for USRP's connect to 1G ethernet. It's expected that they take on a 10.2 address 
	def initialize()
		super
		begin
			@iface.set_ip("192.168.10.1","255.255.255.0")
			@iface.set_kflag
			retries = 0
			begin
				#locate the usrp using the uhd_usrp_probe, this may require a couple of tries
				@raw_data = Tools.run_cmd("#{$options[:locuhd]} --args addr=192.168.10.2").readlines.join("\n")
				return true
			rescue ExecError => e
				#if no uhd was found, output will goto stderr and will trigger an ExecError. 
				#if we see these keys words we should try again
				if e.error.include?("No devices found") or e.error.include?("UHD Error")
					if retries > 3
						@log.debug("USRPData1G.new: No 1G USRP found")
					else
						@log.debug("USRPData1G.new: Failed to find usrp on try #{retries}")
						sleep(10)
						retries += 1
						retry
					end
				else
					raise
				end
			end
		rescue InterfaceDoesNotExist => e
			@log.warn("USRPData1G.new: Was not able to find interface #{e.name}")
		end
		return false
	end
end

class USRPData10G <  USRPData
	#check for USRP's connect to 10G ethernet. It's expected that they take on a 40.2 address 
	def initialize()
		super
		begin
			retries = 0
	#		@iface.load_module("mlx4_en")
			@iface.set_ip("192.168.40.1","255.255.255.0")
			@iface.set_mtu("9000")
			begin
				#locate the usrp using the uhd_usrp_probe, this may require a couple of tries
				@raw_data = Tools.run_cmd("#{$options[:locuhd]} --args addr=192.168.40.2").readlines.join("\n")
				return true
			rescue ExecError => e
				#if no uhd was found, output will goto stderr and will trigger an ExecError. 
				if e.error.include?("No devices found")
					if retries > 3
						@log.debug("USRPData10G.new: No 10G USRP found")
					else
						@log.debug("USRPData10G.new: Failed to find usrp on try #{retries}")
						sleep(10)
						retries += 1
						retry
					end
				else
					raise
				end
			end
		rescue InterfaceDoesNotExist => e
			@log.warn("USRPData10g.new: Was not able to find interface #{e.name}")
		end
		return false
	end
end

class USRPDataUSB <  USRPData
	#check for USRP's connect via USB.
	def initialize()
		@log = LOG.instance
		@raw_data = nil
		@data = nil
		retries = 0
		begin
			#locate the usrp using the uhd_usrp_probe, this may require a couple of tries
			@raw_data = Tools.run_cmd("#{$options[:locuhd]}").readlines.join("\n")
			return true
		rescue ExecError => e
			#if no uhd was found, output will goto stderr and will trigger an ExecError. 
			if e.error.include?("No devices found")
				if retries > 3
					@log.debug("USRPDataUSB.new: No USB USRP found")
				else
					@log.debug("USRPDataUSB.new: Failed to find usrp on try #{retries}")
					sleep(10)
					retries += 1
					retry
				end
			else
				raise
			end
		end
		return false
	end
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
	def initialize(disk_dev="/dev/sda",block_size="100MB",block_count="25")
		@log  = LOG.instance

		#dig out the size and sn from lshw
		get_data = lambda {|name, array| dat = Tools.dig(name,array).flatten.last; return dat.nil? ? nil : dat.strip}
		disk = LshwData.new("disk")
		@hd_size = get_data.call("size",disk.data)
		@hd_sn = get_data.call("serial",disk.data)

		#get the model from smartctl
		@hd_model = Tools.run_cmd("#{$options[:loclsmart]} -a #{$options[:locdiskdev]}").readlines.join.scan(/[Mm]odel.*?:\s*(.*)$/).flatten.first
		@log.debug("DiskData.new: Disk model was #{@hd_model}")
        @dd_bench = nil
        begin
            @log.debug("DiskData.new:Starting the dd test on #{disk_dev}, copying #{block_count} blocks of size #{block_size}")
            @dd_bench = Tools.run_cmd_combined("#{$options[:locdd]} if=/dev/zero of=#{disk_dev} bs=#{block_size} count=#{block_count}").scan(/s,\s*(.*?\s*MB\/s)/).flatten.first
            @log.debug("DiskData.new:DD bench mark was #{@dd_bench}")
        rescue Exception => e
            @log.warn("DiskData.new: Failed to dd to disk  \n exception was #{e} \n #{e.backtrace}")
        end
	end
	attr_reader :hd_size, :hd_sn, :hd_model, :dd_bench
end

class System 
	#container class for System Data: Motherboard, CPU, Memory, Disk
	def initialize()
		@log=LOG.instance

		get_data = lambda {|name, array| dat = Tools.dig(name,array).flatten.last; return dat.nil? ? nil : dat.strip}

		#extract the Memory Size
		mem = LshwData.new("memory").data.select{|x| Tools.contains?("System Memory",x)}
		@memory = get_data.call("size",mem)
		if @memory.nil?
			@memory = Tools.run_cmd("#{$options[:locfree]} -g").readlines.join.scan(/Mem:\s*(\d*)/).flatten.first + " GB"
			@log.debug("System.new: Lshw mem check failed, free things memory is #{@memory}")
		end

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
		@dd_bench = disk.dd_bench

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
		data  = ["memory","cpu_hz","cpu_type","hd_size","hd_sn","mb_sn","cpu_bench","fw_ping","hd_model","dd_benchmark"].zip([@memory,@cpu_hz,@cpu_type,@hd_size,@hd_sn,@mb_sn,@cpu_bench,@fw_ping,@hd_model,@dd_bench])
		return  data.map{|arr| db.add_attr(db.node,arr[0],arr[1])}.join(" ")

	end

	attr_reader :memory, :cpu_hz, :cpu_type, :hd_size, :hd_sn, :mb_sn
end

class Network
	#container class for all of the network interface information
	def initialize()
		@log=LOG.instance

		@interfaces = Hash.new
		
		#Split the single combined lshw line along the network boundaries
		net = LshwDataRaw.new("network").data.split(/\*\-network/)
		
		#Each string in the array should map to single network device. Extract the relevant info with very specific regex
		net.each{|x|
			#the product keyword is our primary identifier, with out it, we have no idea what kind of device it is
			k = x.scan(/product:\s(.*?)\svendor/).flatten.first
			#this should keep on tacking on duplicates if the device has several mac's
			k = "Duplicate " + k if @interfaces.has_key?(k) 

			#the mac is optional and may be nil (espically if no module was loaded)	
			mac = x.scan(/serial:\s(\w\w:\w\w:\w\w:\w\w:\w\w:\w\w)/).flatten.first

			#same for the ifname
			if_name = x.scan(/logical\sname:\s(\w*?)\s/).flatten.first
			
			unless k.nil?
				#the dev_id comes from the product string (when lshw is invoked with the numeric flag). but may need a hex conversion
				dev_id = k.scan(/(\S{1,4}):(\S{1,4})/).flatten.map{|y| sprintf("%04X",y.hex)}.join(":")
				interfaces.store(k, {:dev_id => dev_id, :if_mac => mac, :if_name => if_name})
			end
		}

	end

	def update(db)
		#db is a DBhelper object that is used to push updated values of the data to the Rest DBa
		s = String.new
		@interfaces.each{|k,v| 
			#add a new device for each interface we found
			dev_name = db.add_dev()
			
			#these have return values but we're discarding them because they are reported in the DB tools anyway.
			db.add_attr(dev_name,"if_mac",v[:if_mac])
		    db.add_attr(dev_name,"if_name",v[:if_name])
			db.add_attr(dev_name,"dev_type",k)
			db.add_attr(dev_name,"dev_id",v[:dev_id]) 
			
			s += "Dev added #{dev_name} "
		}
		#for debug output message
		return s
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

		filter_str =[
			"ATEN International",
			"Linux Foundation",
			"Intel Corp. Integrated Rate Matching Hub",
			"FFFE:0002",
			"fffe:0002",
			"Intel Corp."
		#	"IMC Networks"
		]
				
		rawdata	=  LsusbDataRaw.new().data.reject{|x| filter_str.map{|y| x.include?(y)}.include?(true)}.map{|x| x.strip}


		#all we care about are the device names, lsusb output should be fairly constant
		unless rawdata.empty?
			@devices = Hash.new
			rawdata.each{|x|
				#this regexp will extract the dev id, and a meaninful name 
				v,k = x.scan(/ID\s(\S{1,4}:\S{1,4})(.*?)$/).first
				@log.debug("Found #{k} with #{v}")
				@devices.store(k,v) unless k.nil? or v.nil?
			}
			@log.debug("USB.new: Actual devices found: #{@devices.length}. They are:\n#{@devices.keys.join("\n")}")
		else
			@log.debug("USB.new: No USB dev's found")
		end
	end

	def update(db)
		#db is a DBhelper object that is used to push updated values of the data to the Rest DBa
		if @devices.nil?
			@log.debug("USB: Nothing to update")
			return nil
		else
			#debug output string
			s = String.new
			@devices.each{|k,v| 
				dev_name = db.add_dev()
				s += "Dev added #{dev_name} "
				#remove any trailing white space and convert the address to hex (if needed)
				dev_id = v.scan(/(\S{1,4}):(\S{1,4})/).flatten.map{|y| sprintf("%04X",y.hex)}.join(":")

				s += db.add_attr(dev_name,"dev_type",k)
				s += db.add_attr(dev_name,"dev_id",dev_id)
			}
			return s
		end
	end
end

class USRP
	#Stratgey Contrainer, 1G are the most common, so we'll try them first, then move to 10g, and finally USB
	def initialize()
		@log=LOG.instance
		@usrp_date = nil	
		#Test the Heirarchy, throw away the old object if there is no data
		begin
			tmp_usrp = USRPData1G.new()
			tmp_usrp.pop_data
			@usrp_data = tmp_usrp.data 
		rescue Exception => e
			@log.warn("USRP.new: Failed to enumerate 1G \n exception was #{e} \n #{e.backtrace}")
		end

		begin
			if @usrp_data.nil?
				tmp_usrp = USRPData10G.new()
				tmp_usrp.pop_data
				@usrp_data = tmp_usrp.data 
			end
		rescue Exception => e
			@log.warn("USRP.new: Failed to enumerate 10G \n exception was #{e} \n #{e.backtrace}")
		end

		begin
			if @usrp_data.nil?
				tmp_usrp = USRPDataUSB.new()
				tmp_usrp.pop_data
				@usrp_data = tmp_usrp.data 
			end
		rescue Exception => e
			@log.warn("USRP.new: Failed to enumerate USB \n exception was #{e} \n #{e.backtrace}")
		end
	end

	def update(db)
		if @usrp_data.nil?
			@log.warn("No USRP found")
			return nil 
		end

		s = String.new

		dev_name = db.add_dev()
		s += "Dev added #{dev_name}"
		s += db.add_attr(dev_name,"dev_id",@usrp_data[:id])
		s += db.add_attr(dev_name,"dev_type",@usrp_data[:type])
		s += db.add_attr(dev_name,"serial",@usrp_data[:serial])
		s += db.add_attr(dev_name,"uhd_version",@usrp_data[:uhd_version])
		s += db.add_attr(dev_name,"mother_board_type",@usrp_data[:mboard])
		@usrp_data[:daughters].each{|arr| 
			dev_name = db.add_dev()
			s += db.add_attr(dev_name,"dev_type",arr[0])
			s += db.add_attr(dev_name,"dev_id",arr[1])
		}
		return s
	end
end

class NetFPGA
	#container class since there may be more than one datum, but they should all be updated via a single cmd
	def initialize()
		@log=LOG.instance
		@lspci_data = LspciData.new()
	end

	def update(db)
		if @lspci_data.data.select{|x| x.first.include?("feed")}.empty?
			@log.warn("No Netfpga found")
			return nil 
		end
		dev_name = db.add_dev()
		s0 = db.add_attr(dev_name,"dev_id",@lspci_data.data.select{|x| x.first.include?("feed")}.join(":"))
		s1 = db.add_attr(dev_name,"dev_type","NetFpga 1G")
		return ["Dev added #{dev_name}",s0,s1].flatten.join(" ")
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
		$options[:timeout] = 120
		opts.on('-t','--timeout TIMEOUT','Database time out (default: 120)') do |tm|
			$options[:timeout] = tm
		end

		#Database timeout
		$options[:stagger] = 0
		opts.on('-s','--stagger STAGGERTIME','Wait Time between Database calls (default: 0)') do |st|
			$options[:stagger] = st
		end

		#Database timeout
		$options[:retry_limit] = 5
		opts.on('-R','--retry_limit RETRYLIMIT','Number of retries before we give up completely (default: 5)') do |rl|
			$options[:retry_limit] = rl
		end

		#DB host
		$options[:dbserver] = "http://internal1.orbit-lab.org:5054/inventory/"
		opts.on('-r','--restdb server','name of the Restfull Database server') do |server|
			$options[:dbserver] = server
		end

		#prefix
		$options[:prefix] = "INV_"
		opts.on('-p','--prefix TXT','Attribute PREFIX (Default = INV_)') do |prefix|
			$options[:prefix] = prefix
		end

		#Primary disk name 
		$options[:locdiskdev] = '/dev/sda'
		opts.on('--diskdev FILE','location of Disk Device (default: /dev/sda)') do |file|
			$options[:locdiskdev] = file
		end

		#Smartmontool location
		$options[:loclsmart] = '/usr/sbin/smartctl'
		opts.on('--smrt FILE','location of smartctl executeable (default: /usr/sbin/smartctl)') do |file|
			$options[:loclsmart] = file
		end

		#LSPCI location
		$options[:loclspci] = '/usr/bin/lspci'
		opts.on('--lspci FILE','location of lspci executeable (default: /usr/bin/lspci)') do |file|
			$options[:loclspci] = file
		end

		#LSHW location
		$options[:loclshw] = '/usr/bin/lshw'
		opts.on('--lshw FILE','location of lshw executeable (default: /usr/bin/lshw)') do |file|
			$options[:loclshw] = file
		end

		#LSUSB location
		$options[:loclsusb] = '/usr/bin/lsusb'
		opts.on('--lsusb FILE','location of lsusb executeable (default: /usr/sbin/lsusb)') do |file|
			$options[:loclsusb] = file
		end

		#Sysbench location
		$options[:locbench] = '/usr/bin/sysbench'
		opts.on('--bench FILE','location of sysbench executeable (default: /usr/bin/sysbench)') do |file|
			$options[:locbench] = file
		end

		#ifconfig location
		$options[:locifconfig] = '/sbin/ifconfig'
		opts.on('--ifcon FILE','location of ifconfig (default: /sbin/ifconfig)') do |file|
			$options[:locifconfig] = file
		end

		#modprobe location
		$options[:locmodprobe] = '/sbin/modprobe'
		opts.on('--ifcon FILE','location of modprobe (default: /sbin/modprobe)') do |file|
			$options[:locmodprobe] = file
		end

		#ping location
		$options[:locping] = '/bin/ping'
		opts.on('--ping FILE','location of ping (default: /bin/ping)') do |file|
			$options[:locping] = file
		end

		#uhd location
		$options[:locuhd] = '/usr/local/bin/uhd_usrp_probe'
		opts.on('--uhd FILE','location of uhd usrp probe binary (default: /usr/bin/uhd_usrp_probe)') do |file|
			$options[:locuhd] = file
		end

		#free location
		$options[:locfree] = '/usr/bin/free'
		opts.on('--free FILE','location of free binary (default: /usr/bin/free)') do |file|
			$options[:locfree] = file
		end

		#sysctl location
		$options[:locsysctl] = '/sbin/sysctl'
		opts.on('--sysctl FILE','location of sysctl binary (default: /sbin/sysctl)') do |file|
			$options[:locsysctl] = file
		end

		#HOSTNAME location
		$options[:lochostname] = '/bin/hostname'
		opts.on('--hostname FILE','location of hostname executeable (default: /bin/hostname)') do |file|
			$options[:lochostname] = file
		end

		#HOSTNAME location
		$options[:locdate] = '/bin/date'
		opts.on('--date FILE','location of date executeable (default: /bin/date)') do |file|
			$options[:locdate] = file
		end

		#dd location
		$options[:locdd] = '/bin/dd'
		opts.on('--dd FILE','location of dd executeable (default: /bin/dd)') do |file|
			$options[:locdd] = file
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
	log.info("Main: Gatherer Version 4.3, Now with more regexp and hash!")

	begin
		#need to know the node name before you instantiate the DB	
		nd = NodeData.instance
	
		#now that we know the fqdn, we can make a DBhleper	
		db = DBhelper.new($options[:dbserver],nd.fqdn,$options[:prefix],$options[:timeout],$options[:retry_limit],$options[:stagger])
		
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

		#update netfpga
#		netfpga = NetFPGA.new()
#		netfpga.update(db)
#		log.info("Main: NetFPGA data update complete")

		#then use that db helper to checkin
		log.info("Main: Checking in")
		db.check_in(nd.now)

	rescue Exception => e
		log.fatal(e)
		log.fatal(e.backtrace)
		log.fatal("Main: Critical failure. Dieing")
		puts e
		puts e.backtrace
#		log.fatal("Can't Continue, sending email")
#		msgstr = "
#From: 'root@#{nd.fqdn}'
#To: root@orbit-lab.org
#Subject: Fatal Inventory 
#Error Hi, #{nd.fqdn} encountered a fatal error. Message was \n #{e.class} \n #{e.message}
#"
#		Net::SMTP.start('email.orbit-lab.org', 25) { |smtp| smtp.send_message msgstr, "root@#{nd.fqdn}", "root@orbit-lab.org"}

	ensure	
		#Must close connection reguardless of results. 
		puts "Main:Script done."
		log.close
	end
end
