#!/usr/bin/ruby1.8 -w
#A Unified logging class that is consistent when instantiated across multiple files. Set log will allow you to swap out the log object, or instantiate a new one. Then any class can ask for an instance 
#the log.
#TODO evaluate this approach vs. using purely class methods

require 'logger'
require 'singleton'

class LOG
	#Unfinfied single log instance
	include Singleton
	def initialize()
		@log = Logger.new(STDOUT)
		@level = Logger::INFO
		@log.level = @level
	end

	def debug(msg)
		@log.debug(msg)
	end

	def info(msg)
		@log.info(msg)
	end

	def warn(msg)
		@log.warn(msg)
	end

	def fatal(msg)
		@log.fatal(msg)
	end
	
	def close()
		@log.close()
	end

	def set_debug()
		@level = Logger::DEBUG
		@log.level = @level
		return true
	end

	def set_info()
		@level = Logger::INFO
		@log.level = @level
		return true
	end

	def get_log()
		return @log
	end

	def set_log(log_object)
		@log = log_object
		@log.level = Logger::INFO
	end

	def set_file(file)
		@log = Logger.new(file)
		@log.level = @level
	end
end
