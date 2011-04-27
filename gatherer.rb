#!/usr/bin/ruby1.8 -w
# gatherer.rb version 2.30 - Gathers information about various sytem files and then  checks them against mysql tables
#
#TODO can't detect usrp2 this way. 
#TODO my update checks currently trash information if, I can't retreieve it. Should this do something more subtle?

require 'optparse'
require 'logger'
require 'open3'
require 'mysql'
require 'find'
require 'singleton'

#Start up Argument parsing
#Option parser 
#
#TODO wrap this in a singleton
$options = Hash.new()
$optparse = OptionParser.new do |opts|
	#Banner
	opts.banner = "Collects infromation about the systems and updates The SQL database: Gathrer.rb [options]"

	#debug check
	$options[:debug] = false
	opts.on('-d','--debug','Enable Debug messages (default: false)') do
		$options[:debug] = true
	end

	#XML check
	$options[:xml] = false
	opts.on('-x','--xml','Generate XML output, instead of flat text (FUTURE)') do
		$options[:xml] = true
	end

	#TODO Make this a mandatory argument. 
	#File Name check
	$options[:outfile] = '/tmp/data'
	opts.on('-o','--output FILE','Where to place the output file (FUTURE)') do |file|
		$options[:outfile] = file
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
	
	#Mysql Server location
	$options[:server] = 'internal1.orbit-lab.org'
	opts.on('-s','--server SERVER','Name of the SQL server (default: internal1.orbit-lab.org)') do |server|
		$options[:server] = server
	end

	#Mysql Server username 
	$options[:user] = 'orbit'
	opts.on('-u','--user USER','Sql Server Username (default: orbit)') do |user|
		$options[:user] = user
	end

	#Mysql Server password
	$options[:pass] = 'orbit'
	opts.on('-p','--pass PASSWORD','Sql Server Password (default: orbit)') do |pass|
		$options[:pass] = pass
	end
	
	#Mysql database name
	$options[:db] = 'inventory2'
	opts.on('-D','--database DATABASE','Sql Server database (default: inventory2)') do |db|
		$options[:db] = db
	end

	#Mysql database name
	$options[:lochost] = '/bin/hostname'
	opts.on('-H','--hostname HOSTNAME','location of hostname executeable (default: /bin/hostname)') do |lochost|
		$options[:lochost] = lochost
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
LOG = Logger.new($options[:logfile], 'weekly')
if $options[:debug] then LOG.level = Logger::DEBUG else LOG.level = Logger::INFO end

#Component parent class
#Not ment to be instantiated
class Component
	@@lshw=$options[:loclshw]
	@@lsusb=$options[:loclsusb]
	@@server=$options[:server]
	@@user=$options[:user]
	@@pass=$options[:pass]
	@@db=$options[:db]
	@@ms=nil

	def initialize(lshw=nil,lsusb=nil,server=nil,user=nil,pass=nil,db=nil)
	#populates class vars incase they're changed (unlikely, they're set one as a cmd line param, and shouldn't be changed after that).
		@@lshw = lshw if lshw
		@@lsusb = lsusb if lsusb
		@@server = server if server
		@@user = user if user
		@@pass = pass if pass
		@@db = db if db
		return nil
	end

	def lshw_arr(flag, marker=nil)
	#Arugments: 
	#Flag - what device class to pass to lshw (see lshw webpage)  - Mandatory
	#marker - what character sequence to fold on - (optional)
	#Returns an Array of lines from lshw output, if a marker is specfied the array is folded at the markers (markers discarded)
		begin
			LOG.debug("Component.lshw_arr: Calling lshw with flag #{flag}#{" and marker " if marker}#{marker}")
			stdin, stdout, stderr = Open3.popen3("#{@@lshw} -numeric -c #{flag}")
			errarr = stderr.readlines
			LOG.debug("Component.lshw_arr: Error output of call to lshw:: #{errarr}") unless errarr.empty?
			errarr.each do |line|
				raise "lshw not found" if /No such file or directory/.match(line)
			end
		rescue Exception => e
			LOG.fatal("Component.lshw_arr: #{e.class} #{e.message}")
			LOG.fatal("Component.lshw_arr: called by #{caller}")
			raise
		end
		lines = stdout.readlines
		lines.map!{|line| line.strip}

		#if no marker is specfied return the sanitized array
		return lines unless marker

		#fold the array
		#Start from the back incase there are multiple matches, it is expected the data confroms to the 
		#standard: marker Data marker data marker data ...
		headers = lines.select{|line| line =~ /#{Regexp.escape(marker)}/}.reverse
		big_arr = headers.map{|mark| lines.slice!(lines.rindex(mark)..lines.rindex(lines.last))}.compact
		LOG.debug("Component.lshw_arr: Folded @ #{big_arr.length} marks")
		return big_arr.reverse
	end
	
	def lsusb_arr()
	#Returns an Array of lines from lsusb output
		begin
			LOG.debug("Component.lsusb_arr: Calling lsusb")
			stdin, stdout, stderr = Open3.popen3("#{@@lsusb}")
			errarr = stderr.readlines
			LOG.debug("Component.lsusb_arr: Error output of call to lsusb:: #{errarr}") unless errarr.empty?
			errarr.each do |line|
				raise "lsusb not found" if /No such file or directory/.match(line)
			end
		rescue Exception => e
			LOG.fatal("Component.lsusb_arr: #{e.class} #{e.message}")
			LOG.fatal("Component.lsusb_arr: called by #{caller}")
			raise
		end
		lines = stdout.readlines
		lines.map!{|line| line.strip}
		LOG.debug("Component.lsusb_arr: Returning #{lines.length} lines")
		return lines 
	end

	def sql_query(table, col, where=nil)
		#form a que string by combining the cols, table and where (if not nil) varibles.
		#table should be a simple string
		#col should be an array
		#where should be a hash
	
		#A simple join works for col since it is an array.
		qs = "SELECT " + col.join(",") + " FROM #{table}"
		if where:
		       	keys = where.keys
			# since where is a hash, I manipulate the .keys array to make the que string. This time I use the .first(length-1) trick to get around
			# having to slice off the end. I also use the hash.fetch method instead of the usual [""] construction to aviod type conversions.
			tmp = keys.first(keys.length-1).map{|key| %&#{key}='#{where.fetch(key)}' AND &}.to_s +  %&#{keys.last}='#{where.fetch(keys.last)}'&
			qs << " WHERE " + tmp
		end
		LOG.debug("Component.sql_query: Querying with query String: #{qs}")
		#do the query and trap any mysql errors
		begin
			res = @@ms.query(qs) 
		
			#return an arrary 
			res_arr = Array.new()
			while row = res.fetch_row do
				LOG.debug("Component.sql_query: Query result was #{row}, a #{row.class}")
				res_arr.push(row)
			end
			LOG.debug("Component.sql_query: Query results captured #{res_arr.length}")
				
		rescue Mysql::Error => e
			LOG.error("Component.sql_query: Mysql code: #{e.errno},\n Mysql Error message: #{e.error}")
			LOG.fatal("Component.sql_query: query died, called by #{caller}")
			raise
		end

		#will always return an arry, but this array might be empty, flatten it because the results of the row loop always produces arrays of arrays
		#I use first to disambiguate multi mapped results, we should always query unique things, but In case we don't the return type should always be
		#be consistent and arry of values (possibly empty), never an array of arrays
		LOG.debug("Component.sql_query: Query returned zero results, returning empty array") if res_arr.length < 1
		return Array.new() if res_arr.length < 1

		LOG.debug("Component.sql_query: Query returned too many results, returning only the first. The sql table probably has errenous entries.") if res_arr.length > 1
		return res_arr.first.flatten
	end

	def sql_now()
		# get the value of NOW() from sql server
		begin
			res = @@ms.query("SELECT NOW()") 
		
			res_arr = Array.new()
			while row = res.fetch_row do
				LOG.debug("Component.sql_now: Query result was #{row}, a #{row.class}")
				res_arr.push(row)
			end
			LOG.debug("Component.sql_now: Query results captured #{res_arr.length}")
		rescue Mysql::Error => e
			LOG.error("Component.sql_now: Mysql code: #{e.errno},\n Mysql Error message: #{e.error}")
			LOG.fatal("Component.sql_now: query died, called by #{caller}")
			raise
		end
		
		#return the sole value
		return res_arr.flatten.first
	end


	def sql_insert(table,vals)
		#Inserts a line into table with params from hsh
		#table is a string that names the mysql table
		#vals is a hash, keys are col names, values are insert values, must be a string
		rows = nil
		
		#form a querry string by adding appropriate back tics and glue the arrays togehter with a delimiter
		#I chose to use fetch beacause keys should be expected to produce the same array twice in the same order
		#but the order of values is not determined
		qs = "INSERT INTO #{table} (" + vals.keys.map{|str| "\`" + str + "\`"}.join(",") + ") VALUES (" + vals.keys.map{|str| "\'" + vals.fetch(str) + "\'"}.join(",") +")"

		LOG.debug("Component.sql_insert: Insert Query String:#{qs}")
		begin
			@@ms.query(qs)
		rescue Mysql::Error => e
			LOG.error("sql_insert: Mysql code: #{e.errno},\n Mysql Error message: #{e.error}")
			LOG.fatal("sql_insert: Mquery died, called by #{caller}")
			raise
		end
		rows = @@ms.affected_rows
		LOG.debug("Component.sql_insert: rows changed #{rows}")
		rows = 0 unless rows
		return rows
	end

	def sql_update(table,vals,where)
		#Inserts a line into table with params from hsh
		#table is a string that names the mysql table
		#vals is a a hash of updates
		#where is a hash that identifies what row to change
		rows = nil
		
		#form a update query string
		qs = "UPDATE #{table} SET "
		#use the keys from the vals hash to make a SET string
		qs << vals.keys.first(vals.keys.length-1).map{|key| %&#{key}='#{vals.fetch(key)}',&}.to_s +  %&#{vals.keys.last}='#{vals.fetch(vals.keys.last)}'&
		qs << " WHERE "
		#use the keys from the where hash to make the where clause
		qs << where.keys.first(where.keys.length-1).map{|key| %&#{key}='#{where.fetch(key)}' AND &}.to_s +  %&#{where.keys.last}='#{where.fetch(where.keys.last)}'&

		LOG.debug("Component.sql_update: Update Query String:#{qs}")
		begin
			@@ms.query(qs)
		rescue Mysql::Error => e
			LOG.error("sql_update: Mysql code: #{e.errno},\n Mysql Error message: #{e.error}")
			LOG.fatal("sql_update: Mquery died, called by #{caller}")
			raise
		end
		rows = @@ms.affected_rows
		LOG.debug("Component.sql_update: rows changed #{rows}")
		rows = 0 unless rows
		return rows
	end

	def Component.connect()
		#it should be the job of the main class to connect. The child class will have class methods to query
		#theose methods should complain if not connected.
		#attempt to connect: if already connected return the connected object
		#if connection fails, try again 2 times then give up permantly.
		#Control of the mysql object should not go outside component, thus this component only returns sucess or terminates
		try = 0
		begin
			try += 1
			if @@ms:
				#returns true if already connected
				return true
			else
				#return true if sucessfull connection
				@@ms = Mysql.real_connect(@@server, @@user, @@pass, @@db)
				LOG.debug("component.connect: Sucessful Connection to MySql #{@@server}")
				return true
			end
		rescue Mysql::Error => e
			LOG.error("component.connect: Mysql code: #{e.errno}, Mysql Error message: #{e.error}")

			#take a little nap before trying again
			sleep(rand(20))
			retry if try < 3

			#I got here because it failed too many times
			LOG.fatal("component.connect: Giving up for good this time : #{e.errno} : #{e.error}")
			LOG.fatal("component.connect: called by #{caller}")
			raise
		end
	end

	def Component.disconnect(ms=@@ms)
		if ms
			#try to close the connection
			LOG.debug("component.disconnect: Closing the mysql connection #{ms}")
			ms.close
			return true
		else 
			#complain if I it didn't exist
			LOG.fatal("component.disconnect: Mysql object is nil, can't disconnect")
			LOG.fatal("component.disconnect: called by #{caller}")
		end
	end

	def update()
		#abstract method, every one should override this. 
		LOG.fatal("component.update: #{caller} did not implement check")
		raise NotImplementedError
	end
	
	def uconvert(num)
		#assumes a string of the form XY where X is a number and Y is a Unit, returns a float class or nil

		#check for a nil argument, I should return nil immedately if I get nil
		return nil unless num

		LOG.debug("Component.uconvert: converting #{num} to float")
		value = /(\d+)(\w).*/.match(num).to_a
		return (Float(value[1]) * 1000000) if value[2].upcase == "M"
		return (Float(value[1]) * 1000000000) if value[2].upcase == "G"
		return nil
	end

	private :lshw_arr,:lsusb_arr,:sql_query, :sql_insert, :sql_update, :sql_now 
end

class Device < Component
	#implment the get_device_kind, all devices should have one. But not all components are devices
	def initalise()
		#nothing additional to do here
		super()
	end

	def get_device_kind(vendor, device,desc,bus,inv_id)
		#check for device_kind, insert one if needed
		kind = sql_query("device_kinds",["id"],Hash["vendor"=>vendor,"device"=>device])
		if kind.empty?
			LOG.debug{"Device.get_device_kind: Kind not found, inserting"}
			sql_insert("device_kinds",Hash["vendor"=>vendor.to_s,"device"=>device.to_s,"bus"=>bus.to_s,"inventory_id"=>inv_id.to_s,"description"=>desc.to_s])
			kind = sql_query("device_kinds",["id"],Hash["vendor"=>vendor,"device"=>device])
		end
		return kind.first
	end
end

class System < Component
	include Singleton
	#contains system infromation stored in single instance variables: node id, location id, inventory id, and the check_in method
	def initialize()
		super()
		@@hostname=$options[:lochost]
		@loc_id = nil
		@inventory_id = nil
		@node_id = nil
	end

	def get_loc_id()
		# I'll need to determine my domain by checking my hostanme, I expect that the fqdn is of the from nodename.node_domain.orbit-lab.org
		unless @loc_id
			#should only need to check once
			begin
				#all external calls should be wrapped in a begin block
				#get the host name and parse it for node id
				fqdn = `#{@@hostname} --fqdn`.split(".").map{|x| x.strip}
			rescue Exception => e
				LOG.fatal("System.get_loc_id: #{e.class} #{e.message}")
				raise
			end
			
			#get the cooridnates from the nodename
			if /console/.match(fqdn[0])
				cords = ["0","10"]
			else
				cords = /node(\d*)-(\d*)/.match(fqdn[0])[1,2]
			end
				
			#drop the node name, create a recursive array with the concanated strings in it, then drop initial empty string
			domtry = fqdn.drop(1).inject(Array.new()){|l,s| if l.empty? then l.push(s) else l.push(l.last + "." + s) end}
			LOG.debug("System.get_loc_id:Possible Domains #{domtry.map{|x| x +","}}")

			#try the possible domains until I get one that works
			testbed_id = domtry.map{|fqdn| sql_query("testbeds",["id"],Hash["node_domain"=>fqdn])}.flatten.compact.first
			
				
			#if there were no cooridnates to be found I'll return 
			return nil unless cords


			@loc_id = sql_query("locations",["id"],Hash["x"=>cords[0],"y"=>cords[1],"testbed_id"=>testbed_id]).flatten.first
			unless @loc_id
				LOG.fatal("System.get_loc_id: Query for location Id failed, I can't continue")
				raise NoLocationIdError
			end
		end

		#location and testbed tables are refrences, they do not contain mutable infromation so I'll never need to check/update them
		return @loc_id
	end

	def check_in(loc_id)
		#simple update call
		#TODO query for id first, update if there, insert if missing
		#should only be called once

		return sql_insert("check_in",Hash["time"=>sql_now(),"id"=>loc_id]) if sql_query("check_in",["time"],Hash["id"=>loc_id]).empty?
		return sql_update("check_in",Hash["time"=>sql_now()],Hash["id"=>loc_id]) 
	end

	def get_inv_id()
		#populates the @inventory ID variable, or returns it if already populated, that way I don't have to querty for it multiple times
		#this is a class method since many elements may need it (including the main routine for reporting purposes) it may get passed as a
		#parameter to the update method
		#inventory ID is unmutable, I should never update it.
		begin
			unless @inventory_id then
				#this que string is special due to the max argument so I can use the sql_query method, however it only needs to be done 
				#once so there is no point in making a special query by string method, none of the children should need that feature
				res = @@ms.query("SELECT max(id) FROM `inventories`")
				tmp = Array.new()
				while row = res.fetch_row do
					tmp.push(row)
				end
				LOG.debug("System.get_inv_id: #{tmp.length} rows collected")
				@inventory_id = tmp.flatten.compact.first
			end
			return @inventory_id
		rescue Exception => e
			LOG.fatal("System.get_inv_id: #{e.class} #{e.message}")
			raise
		end
	end

	def get_node_id(loc_id,mb_id)
		#get the node id from the sql table if it exists. Inserts if it deosn't
		unless @node_id
			@node_id,sql_mb_id = sql_query("nodes",["id","motherboard_id"],Hash["location_id"=>loc_id])
			if @node_id == nil
				LOG.debug("System.get_node_id: Node id missing, inserting")
				sql_insert("nodes",Hash["location_id"=>loc_id,"motherboard_id"=>mb_id])
				@node_id = sql_query("nodes",["id"],Hash["location_id"=>loc_id])
				return @node_id
			end
			if sql_mb_id == mb_id
				LOG.debug("System.get_node_id: Node id correct")
				return @node_id
			else
				#location and nodes should have a 1-1 mapping, the only diffrence is if the mb_id is correct
				LOG.debug("System.get_node_id: motherboard info wrong, updating")
				sql_update("nodes",Hash["motherboard_id"=>mb_id],Hash["location_id"=>loc_id])
				return @node_id
			end
		end
		return @node_id
	end

end



class Motherboard < Component
	include Singleton
	#system Data, stored in single varibles since each should have only a single instance
	def initialize()
		super()

		#here we expect an unfolded array
		arr = lshw_arr('system')

		#the system name is simple the first line of the lshw -c system output
		@name = arr.first.strip

		#use a two line clode block to grab the captures
		#TODO rewrite this with a flatten.select{}.match, should be less operations
		@uuid = arr.map{|line| md = /uuid=(.*)/.match(line); if md then md.captures.first else nil end}.flatten.compact.first

		#getting a folded array
		big_arr = lshw_arr('memory',"*-")

		#since it's folded, I'll have to select twice to find the string I'm intrested in
	
		#bark about missing bios info, but continue
		bios_arr = big_arr.select{|arr| arr[0] =~ /\*-firmware/}.flatten.compact
		LOG.warn("Motherboard.initalize: Couldn't find bios information, continuing any way") if bios_arr.empty?
		@bios=nil
		@bios = bios_arr.select{|line| line =~ /vendor:/}.to_s.split(":",2)[1].strip unless bios_arr.empty?

		@memory = uconvert(big_arr.select{|arr| arr[0] =~ /\*-memory/}.flatten.select{|line| line =~ /size:/}.to_s.split(":",2)[1].strip)

		big_arr = lshw_arr('cpu',"*-")
		#pick array elements that have a size, the size less are just logical, the index call will be nil unless size: is in the array, thus the select will only pick
		#arrays with the size: in one of the elements
		
		#lshw multiply enumerates cpus serveral times, selecting only entries with bus info should give us an "accurate" core count
		cpu = big_arr.select{|arr| arr.index{|x| /bus info:/.match(x)}}
		@cpu_num = cpu.length.to_s

		#Now, pick out the size string, lshw does not consistly assign size to processor number, so I sort the size array, and take the largest (last)
		cpu_freq_arr = cpu.flatten.select{|line| line =~ /size:/}.sort
		LOG.warn("No cpu frequency information, continuing any way") if cpu_freq_arr.empty?

		#do a unit conversion on this to make it a float (string), the first array should have all the required fields
		@cpu_freq=nil
		@cpu_freq = uconvert(cpu_freq_arr.last.to_s.split(":",2)[1].strip) unless cpu_freq_arr.empty?
		
		#product and vendor names should always exist
		@cpu_prod = cpu.first.select{|line| line =~ /product:/}.to_s.split(":",2)[1].strip
		@cpu_vend = cpu.first.select{|line| line =~ /vendor:/}.to_s.split(":",2)[1].strip

	        big_arr = lshw_arr('disk',"*-")

		#map each element to a hash of relevant keys
		@disk = big_arr.map do |arr|
			#populate a new hash for a single disk with entires pulled from the folded array
			tmp_hsh=Hash.new()
			tmp_hsh['vendor'] = arr.map{|line| line.split(":",2)[1].strip if /vendor:/.match(line)}.flatten.compact.first
			tmp_hsh['product'] = arr.map{|line| line.split(":",2)[1].strip if /product:/.match(line)}.flatten.compact.first
			tmp_hsh['name'] = arr.map{|line| line.split(":",2)[1].strip if /logical name:/.match(line)}.flatten.compact.first
			tmp_hsh['serial'] = arr.map{|line| line.split(":",2)[1].strip if /serial:/.match(line)}.flatten.compact.first
			#do a unit conversion on this to make it a float (string)
			tmp_hsh['size'] = uconvert(arr.map{|line| line.split(":",2)[1].strip if /size:/.match(line)}.flatten.compact.first)
			tmp_hsh
		end

		#keep only elements with a size value
		@disk = @disk.select{|hsh| hsh['size']}
		LOG.debug("Motherboard.initalize: number of disks found #{@disk.length}")
		
		#delcaring mb_id/loc_id for good measure
		@mb_id = nil
	end


	def to_s()
		return "#{@name}|#{@cpu_vend} #{@cpu_prod} #{@cpu_freq} X #{@cpu_num}|#{@memory}|#{@disk.map{|hsh|hsh['size']}.join(",")}"
	end

	def get_mb_id()
		#I should be able to match against UUID, but assimeing that is empty, I'll try to match against disk serial number
		#It is the job of the mother board class to get the uuid.
		#Since this value is probably used multiple times, I should store it, and only query once
		if @uuid
			@mb_id = sql_query("motherboards",["id"],Hash["mfr_sn" => @uuid]).first unless @mb_id
			unless @mb_id
				LOG.debug("Motherboard.get_mb_id: Sql query was empty, updating")
				update(System.instance.get_inv_id())
				@mb_id = sql_query("motherboards",["id"],Hash["mfr_sn" => @uuid]).first
			end
		else
			@mb_id = sql_query("motherboards",["id"],Hash["hd_sn" => @disk.first['serial']]).first unless @mb_id
			LOG.warn("Motherboard.get_mb_id: No UUID was found, matching agasint first Disk serial")
			unless @mb_id
				LOG.debug("Motherboard.get_mb_id: sql_query was empty, updateing")
				update(System.instance.get_inv_id())
				@mb_id = sql_query("motherboards",["id"],Hash["hd_sn" => @disk.first['serial']]).first
			end
		end

		return @mb_id
	end

	def update(inv_id)
		#updates the motherboard record and the node record

		#the data
		headers = ["id","inventory_id","mfr_sn","cpu_type","cpu_n","cpu_hz","hd_sn","hd_size","memory"]
		if @uuid
			#check against serial 
			sql_data = sql_query("motherboards",headers,Hash["mfr_sn"=>@uuid])
			#gat should have 1 less element than sql since I don't know if an id exists ahead of time.
			gat_data = [inv_id,@uuid,@cpu_vend + @cpu_prod,@cpu_num,@cpu_freq,@disk.first["serial"],@disk.first["size"],@memory]
		else
			#check against disk
			LOG.warn("Motherboard.update: No UUID was found, matching agasint first Disk serial")
			sql_data = sql_query("motherboards",headers,Hash["hd_sn" => @disk.first['serial']])
			sql_data[2]=nil
			#gat should have 1 less element than sql since I don't know if an id exists ahead of time.
			gat_data = [inv_id,"BOGUS MB #{@disk.first["serial"]}",@cpu_vend + @cpu_prod,@cpu_num,@cpu_freq,@disk.first["serial"],@disk.first["size"],@memory]
		end

		# convert the numeric strings to floats
		unless sql_data.empty?
			#cpu_hz, may be empty
			if sql_data[5] 
				sql_data[5] = Float(sql_data[5])
				sql_data[5] = nil if sql_data[5] == 0.0
			else 
				sql_data[5] = nil
			end
			#hd_size
			sql_data[7] = Float(sql_data[7]) if sql_data[7]
			#memory
			sql_data[8] = Float(sql_data[8]) if sql_data[8]
		end

		# if the query was empty (after throwing away some nils that were inserted), insert immedately, other wise check	
		if sql_data.compact.empty?
			#do the insert, have to convert floats to_s before passing them to sql
			return sql_insert("motherboards",Hash[headers.last(headers.length-1).zip(gat_data.map{|x| x.to_s})])
		else
			# data contains floats so checking, uses string or float comparison, the == will changed based on context
			check = sql_data.last(sql_data.length-2).zip(gat_data.last(gat_data.length-1)).map{|arr| arr[0] == arr[1]}.inject{|agg,n| agg and n}
			
			# update based on uuid or disk serial if uuid not avaialabe
			unless check
				if @uuid
					vals = Hash[headers.last(headers.length-1).zip(gat_data.map{|x| x.to_s})].reject{|k,v| k == "mfr_sn"}
			        	where =	Hash["mfr_sn"=>gat_data[1]]
				else
					vals = Hash[headers.last(headers.length-1).zip(gat_data.map{|x| x.to_s})].reject{|k,v| k == "hd_sn"}
					where = Hash["hd_sn"=>gat_data[5]]
				end
				LOG.debug("Motherboard.update: Motherboard Checks failed")
				return sql_update("motherboards",vals,where)
			end
		end
		LOG.debug("Motherboard.update: Motherboard Checks passed, no Motherboard updates required")
		
		#if there was nothing to update say zero lines changed.
		return 0
	end

	attr_reader :uuid,:name,:numcpu,:memory,:bios,:cpu,:clock,:disk, :mb_id
end

class Network < Device 
	include Singleton
	#Network Data, stored in array of hashes, 1 hash per interface
	def initialize()
		super()
	        big_arr = lshw_arr('network',"*-")

		#map each element to a hash of relevant keys
		@interface = big_arr.map do |arr|
			#populate a new hash for a single interface with entires pulled from the folded array
			#take only the first match should be a string
			tmp_hsh=Hash.new()

			#single line scrapes just want what is after :
			tmp_hsh["desc"] = arr.map{|line| line.split(":",2)[1].strip if /description:/.match(line)}.flatten.compact.first
			tmp_hsh["bus"] = arr.map{|line| line.split(":",2)[1].strip.sub(/pci@/,"") if /bus info:/.match(line)}.flatten.compact.first
			tmp_hsh["name"] = arr.map{|line| line.split(":",2)[1].strip if /logical name:/.match(line)}.flatten.compact.first
			tmp_hsh["mac"] = arr.map{|line| line.split(":",2)[1].strip if /serial:/.match(line)}.flatten.compact.first
			tmp_hsh['driver'] = arr.map{|line| /driver=(\w*)/.match(line).captures[0] if /driver=(\w*)/.match(line)}.flatten.compact.first

			#more complicated scrapes, cast the MD to an array and pull the relevant array entries, we'll get the bus values due to the -numeric keyword
			#
			tmpmat = arr.map{|line| /vendor:(.*)\[(.*)\]/.match(line).to_a}.flatten
			tmp_hsh["vendname"] = tmpmat[1].to_s if tmpmat[1]
			tmp_hsh["vend"] = tmpmat[2].hex if tmpmat[2]
			tmpmat = arr.map{|line| /product:(.*)\[(.*):(.*)\]/.match(line).to_a}.flatten
			tmp_hsh["prodname"] = tmpmat[1].to_s if tmpmat[1]
			tmp_hsh["prod"] = tmpmat[3].hex if tmpmat[3]

			#some warnings about the map! line below. It's easier to warn here than down there.
			LOG.warn("Network.initialize: empty bus information, DATA WILL BE DROPPED ") unless tmp_hsh["bus"]
			LOG.warn("Network.initialize: missing mac for bus #{tmp_hsh["bus"]}, Is the driver loaded? ") unless tmp_hsh["mac"]
			LOG.warn("Network.initialize: missing prod identifiers for mac #{tmp_hsh["mac"]}, DATA WILL BE DROPPED.") unless tmp_hsh["prod"]

			#can't use the return keyword because that is one context up, just invoking tmp_hsh tho will pass that value up to the map as the "result", the 
			#block evaluates to the last statement
			tmp_hsh
		end
		
		#drop any array entries that don't have product identifier infromation. I use map! and compact! since select! doesn't work
		@interface.map!{|hsh| unless hsh['prod'] and hsh['bus'] then nil else hsh end}.compact!
		LOG.debug("Interfaces: #{@interface.join("#\n")}")
	end

	def to_s()
		#pick out the macs, drop the nil entries, and join them with a ","
		return @interface.map{|hsh| hsh["mac"]}.compact.join(",")
	end

	def update(inv_id,mb_id)
		#returns number of changes made
		#inv_id is the inventory gathered from mysql
		#mb_id is the mother board id also take from sql

		#list of headers from device the table
		headers = ["id","inventory_id","device_kind_id","motherboard_id","address","mac","canonical_name"]

		# the sql data array
		sql_data = @interface.map{|hsh| sql_query("devices",headers,Hash["address"=>hsh["bus"],"motherboard_id" => mb_id])}
		
		#join the kindnames if they exist
		kindname=@interface.map{|hsh| Array[hsh["vendname"],hsh["prodname"],hsh["desc"]].compact.join(" ")}

		#the collected data array, bus type is PCI because I'm a network scavenged device
		gat_data = @interface.zip(kindname).map{|arr| [inv_id,get_device_kind(arr[0]["vend"],arr[0]["prod"],arr[1],"PCI",inv_id),mb_id,arr[0]['bus'],arr[0]['mac'],arr[0]['name']]}
		#set missing data to empty string so the inserts work
		gat_data.map!{|arr| arr.map{|ele| ele or ""}}

		#insert if sql_data is empty?	
		insert = sql_data.zip(gat_data).map{|arr| if arr[0].empty? then sql_insert("devices",Hash[headers.last(headers.length-1).zip(arr[1])]) else 0 end}
		
		#zip 2 copines of gat_data into sql_data, 1 for comparison, 1 for updateing. Drop empty sql entries with a reject (should have already been inserted) 
		#then truncate the comparison arrays so they are the same size (drop "id" and "inventory_id" entries since I should be checking those)
		unmatch = sql_data.zip(gat_data,gat_data).reject{|arr| arr[0].empty?}.map{|arr| Array[arr[0].last(arr[0].length-2),arr[1].last(arr[1].length-1),arr[2]]}
		#compare the truncated arrays, and update if they don't match, drop all the nill entiries with a compact
		uphsh = unmatch.map{|arr| Array[arr[0].eql?(arr[1]),arr[2]]}.map{|arr| if arr[0] then nil else Hash[headers.last(headers.length-1).zip(arr[1])] end}.compact

		LOG.debug("Network.update: #{uphsh.length} updates to be made")
		LOG.debug("Update hsh: #{uphsh.join("\n#")}")
		#push the update 
		update = uphsh.map{|hsh| sql_update("devices",hsh,Hash["address"=>hsh["address"],"motherboard_id" => mb_id])}

		#report and return
		changes = insert.inject{|sum,n| sum +n} + (update.inject{|sum,n| sum + n} or 0)
		LOG.debug("Network.update: #{insert.inject{|sum,n| sum +n}} inserts and #{(update.inject{|sum,n| sum + n} or 0)} updates made, total #{changes} changes made")
		return changes
	end

	attr_reader :interface
end

class Usb < Device
	include Singleton
	#Usb Data, stored in array of hashes, 1 hash per device
	def initialize()
		super()
		arr = lsusb_arr()

		#dump entires with no vendor/device address
		arr.reject!{|line| line.include?("hub") or line.include?("ATEN") or line.include?("0000:0000")}

		#map each element to a hash of relevant keys
		@device = arr.map do |line|
			tmp_hsh=Hash.new()
			tmp_hsh['bus']= /Bus\s*(\d\d\d)/.match(line)[1]
			tmp_hsh['devnum']= /Device\s*(\d\d\d)/.match(line)[1]
			tmp_hsh['prod']= /ID\s.*:(....)/.match(line)[1].hex
			tmp_hsh['vend']= /ID\s.*(....):/.match(line)[1].hex
			#name may be empty, thats ok, but the others are cirtical, and I should die if I can't find them
			tmp_hsh['name']= /....:....\s(.*)$/.match(line)[1] if /....:....\s(.*)$/.match(line)
			tmp_hsh
		end
		LOG.debug("Usb.initilize: #{@device.length} devices found")
	end

	def to_s()
		return @device.map{|hsh| hsh['devnum'].to_s + ":" + hsh['vend'].to_s + ":" + hsh['prod'].to_s + " "}.to_s
	end

	def update(inv_id,mb_id)
		#returns number of changes made
		#inv_id is the inventory gathered from mysql
		#mb_id is the mother board id also take from sql
		
		#nothing to update if no usb devices found
		if @device.empty?
			LOG.debug("Usb.update: Device list empty")
			return 0
		end

		#list of headers from device the table, smaller because we have less information
		headers = ["id","inventory_id","device_kind_id","motherboard_id","address"]
		
		#need to get device id first, because I can't look for macs
		gat_data = @device.map{|hsh| [inv_id,get_device_kind(hsh["vend"],hsh["prod"],hsh["name"],"USB",inv_id),mb_id,hsh['bus']+":"+hsh["devnum"]]}
		
		# the sql data array, matched against device id and mb_id, there is a huge flaw here, since this query can be ambigous
		# It must be assumed that onyl a single device of device_kind can be connected at a time to a node, multiple types will break
		# TODO this should probably be based on address for uniformity.
		sql_data = gat_data.map{|arr| sql_query("devices",headers,Hash["device_kind_id"=>arr[1],"motherboard_id"=>arr[2]])}
		
		#insert if sql_data is empty?	
		insert = sql_data.zip(gat_data).map{|arr| if arr[0].empty? then sql_insert("devices",Hash[headers.last(headers.length-1).zip(arr[1])]) else 0 end}
		
		#zip 2 copines of gat_data into sql_data, 1 for comparison, 1 for updateing. Drop empty sql entries with a reject (should have already been inserted) 
		#then truncate the comparison arrays so they are the same size (drop "id" and "inventory_id" entries since I should be checking those)
		unmatch = sql_data.zip(gat_data,gat_data).reject{|arr| arr[0].empty?}.map{|arr| Array[arr[0].last(arr[0].length-2),arr[1].last(arr[1].length-1),arr[2]]}
		#compare the truncated arrays, and update if they don't match, drop all the nill entiries with a compact
		uphsh = unmatch.map{|arr| Array[arr[0].eql?(arr[1]),arr[2]]}.map{|arr| if arr[0] then nil else Hash[headers.last(headers.length-1).zip(arr[1])] end}.compact
		LOG.debug("Usb.update: #{uphsh.length} updates to be made")
		#push the update, for some reason Hash.select returns an array, so I have to cast it as a hash 
		update = uphsh.map{|hsh| sql_update("devices",hsh.reject{|k,v| k == "device_kind_id" or k == "motherboard_id"},Hash[hsh.select{|k,v| k == "device_kind_id" or k == "motherboard_id"}])}

		#report and return
		changes = insert.inject{|sum,n| sum +n} + (update.inject{|sum,n| sum + n} or 0)
		LOG.debug("Usb.update: #{insert.inject{|sum,n| sum +n}} inserts and #{(update.inject{|sum,n| sum + n} or 0)} updates made, total #{changes} changes made")
		return changes
	end
end


if __FILE__ == $0
	#Says Hello
	LOG.info("Main: Begin Gatherer.rb - For more information check www.orbit-lab.org")
	begin
		#Prime the connection
		LOG.info("Main: Connecting to Database #{$options[:server]}")
		LOG.info("Main: connection sucessfull") if Component.connect()
		
		#collect identifiers	
		inv_id = System.instance.get_inv_id()
		loc_id = System.instance.get_loc_id()
		mb_id = Motherboard.instance.get_mb_id()
		node_id = System.instance.get_node_id(loc_id,mb_id)

		
		#display identifiers
		LOG.info("Main: Inventory ID is #{inv_id}")
		LOG.info("Main: Location ID is #{loc_id}")
		LOG.info("Main: Node ID is #{node_id}")
		LOG.info("Main: Mother board ID is #{mb_id}")

		#get the data and check it, report any problems
		LOG.info("Main: Mother board summary #{Motherboard.instance}")
		LOG.info("Main: Macs found: #{Network.instance}")
		LOG.info("Main: Usb Devices  found: #{Usb.instance}")
		LOG.info("Main: Motherboard #{Motherboard.instance.update(inv_id)} device rows changed")
		LOG.info("Main: Network #{Network.instance.update(inv_id,mb_id)} device rows changed")
		LOG.info("Main: Usb #{Usb.instance.update(inv_id,mb_id)} device rows changed")
		LOG.info("Main: checking in, #{System.instance.check_in(loc_id)} rows changed")
	ensure	
		#Must close connection reguardless of results. 
		LOG.info("Main: disconnecting from Database #{$options[:server]}")
		LOG.info("Main: disconnection sucessfull") if Component.disconnect()
	end
	LOG.close
end
