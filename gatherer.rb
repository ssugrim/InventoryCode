#!/usr/bin/ruby1.8 -w
# gatherer.rb version 2.4 - Gathers information about various sytem files and then  checks them against mysql tables
#
#TODO can't detect usrp2 this way. 
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

end

class System 
	include Singleton
	#TODO perhaps this should merge with  DB helper since most of the information is needed for that
	#host name, we only need to check it once, but will pass the object around alot
	def initialize()
		#TODO we'll need to gets these params from OPT parse at some point
		begin
			@log  = LOG.instance
			@fqdn = `hostname -f`.chomp
			@now = `date +"%F %H:%M"`.chomp
			@log.debug("Os said the fqdn was #{@fqdn}, and the date/time is #{@now}")
			md = @fqdn.match(/node(\d+)-(\d+)./)
			@x,@y = md.captures unless md.nil?
		rescue
			@log.fatal("Something broke while getting system info")
			raise
		end
	end

	def check_in(db)
		#db is a DBhelper object, it's used to checkin to the system 
		return db.add_attr("check_in",sys.now)
	end

	attr_reader :fqdn,:y, :x, :now
end

#TODO build out the other 3 data classes Motherboard, Network, USB

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
		$options[:logfile] = STDOUT
		opts.on('-l','--logfile FILE','Where to store the log file (default: /tmp/gatherer.log)') do |file|
			$options[:logfile] = file
		end

		#LSHW location
		$options[:loclshw] = '/usr/bin/lshw'
		opts.on('-L','--lshw FILE','location of lshw executeable (default: /usr/bin/lshw)') do |file|
			$options[:loclshw] = file
		end

		#LSUSB location
		$options[:loclsusb] = '/sbin/lsusb'
		opts.on('-U','--lsusb FILE','location of lshsb executeable (default: /sbin/lsusb)') do |file|
			$options[:loclsusb] = file
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
	log.set_file($options[:logfile]) if $options[:logfile]
	log.set_debug if $options[:debug]

	begin
		#need to know the node name before you instantiate the DB	
		sys = System.instance
		
		#TODO sys.fqdn should be the second argument
		db = DBhelper.new($options[:dbserver],"node1-1.sb1.orbit-lab.org")

		puts db.add_attr("check_in",sys.now)
		puts db.get_attr("check_in")
	ensure	
		#Must close connection reguardless of results. 
		log.close
	end
end
