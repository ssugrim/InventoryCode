#!/usr/bin/ruby1.8 -w
# A viewer current state of the rest DB

require 'optparse'
require 'singleton'
require 'log_wrap'
require 'rest_db'

class WebNodeData
	#container class for all the data and meta data extraced from the DB
	def initialize(fqdn)
		@log  = LOG.instance
		
		#all the data fromt he restDB for this given fqdn
		db = Database.new($options[:dbserver])
		@nodes = db.get_all_node(fqdn)

		#all the possible headers expect name
		@headers = @nodes.inject(Array.new){|s,c| s.push(c.map{|x| x.first})}.flatten.uniq.reject{|x| x.match(/name/)}.sort

		#all the names
		@names = @nodes.inject(Array.new){|s,c| s.push(c.select{|x| x.first.match(/name/)}.flatten.last.strip)}
	end

	def get_node_data(name)
		#name is a string, the name of the node whose data we want
		return Tools.tuples(@nodes.select{|x| Tools.contains?(name,x)})
	end

	def get_line(name)
		data = Tools.tuples(@nodes.select{|x| Tools.contains?(name,x)})
		#TODO need a function that pulls from the data and returns either a value or a white space	
		values = @headers.map{|x| tmp = data.select{|y| y.first.match(Regexp.escape(x))}.flatten}
	end

	attr_reader :nodes, :headers, :names
end

class Local_host_name
	include Singleton
	#host name, we only need to check it once, but will pass the object around alot
	def initialize()
		@log  = LOG.instance
		begin
			@fqdn = `#{$options[:lochostname]} -f`.match(/console.(.*)\s*/).captures.first
			@log.debug("Os said the fqdn was #{@fqdn}")
		rescue
			@log.fatal("Couldn't get hostname")
			raise
		end
	end
	
	attr_reader :fqdn
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

		#HOSTNAME location
		$options[:lochostname] = '/bin/hostname'
		opts.on('-H','--hostname FILE','location of hostname executeable (default: /bin/hostname)') do |file|
			$options[:lochostname] = file
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
		lhn = Local_host_name.instance
		data = WebNodeData.new(lhn.fqdn)
		puts data.names.length

	ensure	
		#Must close connection reguardless of results. 
		puts "Main:Script done."
		log.close
	end
end
