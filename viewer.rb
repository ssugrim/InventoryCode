#!/usr/bin/ruby1.8 -w
# A viewer current state of the rest DB

require 'optparse'
require 'singleton'
require 'log_wrap'
require 'webnodedata'

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
		$options[:logfile] =  STDERR
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
	if $options[:logfile]
		log.set_file($options[:logfile]) 
		log.info("Main: Diverting output to #{$options[:logfile]}")
	end
	if $options[:debug]
		log.set_debug 
		log.debug("Options specfied are \n#{$options.to_a.join("\n")}")
	end

	begin
		lhn = Local_host_name.instance
		data = WebNodeData.new($options[:dbserver], lhn.fqdn)
		print "<HTML><BODY><TABLE BORDER = 1><TR><TD>Name</TD><TD>",data.headers.join("</TD><TD>"),"</TD></TR>\n"
		data.names.each{|x| 
			print "<TR><TD>#{x}</TD><TD>";
			dummy = data.get_node_data(x);
			datstr = data.headers.map{|y| dummy.select{|z| z[0] == y}.flatten.last}.join("</TD><TD>");
			log.debug(datstr);
			print datstr;
			print "</TD></TR>\n"
		}
		print "</TABLE></BODY></HTML>\n"
	ensure	
		#Must close connection reguardless of results. 
		log.info("done")
		log.close
	end
end
