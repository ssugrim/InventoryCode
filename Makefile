#First attempt at making a make file for version control on Scripts
#Main target should be a syntax check and install should scp the targets to nfsroot
#clean should do nothing?

CHECK_SYNTAX = ruby -w -c 

check : gatherer.rb log_wrap.rb rest_db.rb
	$(CHECK_SYNTAX) gatherer.rb
	$(CHECK_SYNTAX) rest_db.rb
	$(CHECK_SYNTAX) log_wrap.rb

.PHONY : install clean

install : check
	echo "scp something"

clean : 

