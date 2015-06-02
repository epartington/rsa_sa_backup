#!/bin/bash
VER=1.0.3
#######################################################################
##
## BACKUP TOOL for RSA Security Analytics 10.3 - 10.4
##
## The script compresses configuration files of all available SA components
## into the backup directory specified in BACKUPPATH.
## Old backups are removed after "n" days specified in RETENTION_DAYS.
##  
##  Author : 	Maxim Siyazov 
##  URL: 		https://github.com/Jazzmax/rsa_sa_backup
##  License:	GNU General Public License v2 (http://www.gnu.org/licenses/)
##
##  Copyright (C) 2015 Maxim Siyazov
##  This script is distributed in the hope that it will be useful, but WITHOUT
##  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
##  FOR A PARTICULAR PURPOSE. 
##
#######################################################################
# # Version History
# 1.0.0		- Initial version
# 1.0.1		+ Code refactoring around service start/stop
#			* Bug fixes
# 1.0.2		* Fixed removing old archives
#			+ SA version check (based on Joshua Newton code)
#			+ Improved user/log output. Added list of components to be backed up
#			+ Improved RabbitMQ configuration backup
#			+ Added support of 10.3
# 			+ Added PestgreSQL backup for 10.3
# 1.0.3		* Fixed SA version check
#----------------------------------------------------------------------
# TO DO:
# - Remote backup files 
# - Check if enough disk space to create a backup
# - RSA-SMS server
# - mcollective ssl
# - CLI options 
# - Encrypt backup file 

#######################################################################
# Initialize Section

BACKUPPATH=/root/sabackups				# The backup directory
LOG=sa_backup.log						# the backup log file
LOG_MAX_DIM=10000000 					# Max size of log file in bytes - 10MB 
RETENTION_DAYS=1						# Local backups retention 
RE_FULLBACKUP=0							# 0 - backup only RE configuration; 1 - full RE backup 

# Nothing to change below this line
#===============================================================
HOST="$(hostname)"
timestamp=$(date +%Y.%m.%d.%H.%M) 
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SCRIPT_NAME="$(basename "$(test -L "$0" && readlink "$0" || echo "$0")")"
BACKUP="${BACKUPPATH}/${HOST}-$(date +%Y-%m-%d-%H-%M)"
SYSLOG_PRIORITY=local0.alert
TARVERBOSE="-v"
PID_FILE=sa_backup.pid

# Colouring output
COL_BLUE="\x1b[34;01m"
COL_GREEN="\x1b[32;01m"
COL_RED="\x1b[31;01m"
COL_YELLOW="\x1b[33;01m"
COL_CYAN="\x1b[36;01m"
COL_RESET="\x1b[39;49;00m"  

COREAPP=/etc/netwitness/ng
NWLOGS=/var/log/netwitness
REPORTING=/home/rsasoc/rsa/soc/reporting-engine
SASERVER1=/var/lib/netwitness/uax
JETTYSRV=/opt/rsa/jetty9/etc
PUPPET1=/var/lib/puppet
PUPPET2=/etc/puppet
RSAMALWARE=/var/lib/netwitness/rsamalware
ESASERVER1=/opt/rsa/esa
IM=/opt/rsa/im
LOGCOL=/var/netwitness/logcollector
RABBITMQ=/var/lib/rabbitmq
WHC=/var/netwitness/warehouseconnector
POSTGRESQL=/var/lib/pgsql
declare -A COMPONENT

####################################################################
# Syslog a message
####################################################################
function syslogMessage()
{
	MESSAGE=$1
	logger -p $SYSLOG_PRIORITY "$HOST: $MESSAGE"
}
  
####################################################################
# Write to a log file
function writeLog()
{
    echo "$(date '+%Y-%m-%d %H:%M:%S %z') | $$ | $1" >> $LOG 
    echo -e "$1" 
}

####################################################################
# If the supplied return value indicates an error, exit immediately
####################################################################
function exitOnError() {
	RETVAL=$1
	if [ $RETVAL != 0 ]; then
		syslogMessage "SA Appliance Backup Failed [$RETVAL] - Log File: $LOG"
        echo -e ${COL_RED}"$2"${COL_RESET}
		exit 1 # $RETVAL
	fi
}

####################################################################
# If the supplied return value indicates an error, syslog a message but not exit
####################################################################
function syslogOnError() {
	RETVAL=$1
	if [ $RETVAL != 0 ]; then
		syslogMessage "$2"
        echo -e "${COL_RED}$2 - exit code: [$RETVAL] - Log File: $LOG${COL_RESET}"
	fi
}
####################################################################
# Check is run as root
####################################################################
check_root(){
  if [ "$(id -u)" != "0" ]; then
    echo "ERROR: This script must be run as root!"
    echo ""
    exit 1
  fi
}

####################################################################
## Cleanup the Backup Staging Area
####################################################################
function do_Cleanup {
    find ${BACKUPPATH} -maxdepth 1 -type d -mtime +$RETENTION_DAYS -exec rm -Rf {} \; 2>&1 | tee -a $LOG;
    rm -f $PID_FILE
}
trap do_Cleanup HUP INT QUIT TERM EXIT
####################################################################
# Check if another instance is running
####################################################################
function check_isRun() {
    if [ -f $PID_FILE ]; then
       OLD_PID=$(cat $PID_FILE)
       DRES=$( ps auxwww | grep $OLD_PID | grep "$1" | grep -v grep | wc -l)
       if [[ "$DRES" = "1" ]]; then
          writeLog "ERROR: Exit because process sa_backup.sh is already running with pid $OLD_PID"
          exit 1
       else
          writeLog "INFO: Clean pid file because related to a dead process"
       fi
     fi
    echo $$ > $PID_FILE
}
####################################################################
# Rotate log file based on dimension
####################################################################
function rotate_Logs() {
	if [ -f $LOG ]; then
	   DIM=$(ls -la $LOG|awk '{print $5}')
	   if [ $DIM -gt $LOG_MAX_DIM ]; then
		  writeLog "INFO: Rotating log because of max size - $LOG is $DIM byte"
		  mv $LOG $LOG.old
	   fi
	fi
}
####################################################################
# Check if the SA version is 10.3 or higher 
####################################################################
check_SAVersion() {
	SA_APP_VER_TEMP=`mktemp`
	# Get the (apparent) installed SA version
	SA_APP_TYPE_TEMP=$(rpm -qa --qf '%{NAME}\n' | grep -E '^(nw|jetty|rsa-[a-z,A-Z]*|rsa[m,M]|re-server)' | grep -Ev 'rsa-sa-gpg-pubkeys')
	for SA_PKG_NAME in ${SA_APP_TYPE_TEMP} ; do
		rpm -q "${SA_PKG_NAME}" --qf '%{VERSION}\n' 2> /dev/null >> "${SA_APP_VER_TEMP}"
	done

	SA_RELEASE_VER=$(cat ${SA_APP_VER_TEMP} | grep '^10\.' | sort -Vr | head -n 1)
	rm -f "${SA_APP_VER_TEMP}"
	# Sanity check to make sure version string looks like a version number
	if [ -z "${SA_RELEASE_VER}" ] ; then
	   exitOnError 1 "Could not determine appliance type from installed packages. Is this a Security Analytics\nappliance? This tool does not function on NetWitness appliances.\nPlease examine your installed packages.\n"
	fi
	OIFS=$IFS
	IFS='.'
	SA_VER_ARRAY=($SA_RELEASE_VER)
    IFS=$OIFS
	SAMAJOR=${SA_VER_ARRAY[0]}
	SAMINOR=${SA_VER_ARRAY[1]}
	BUILDTYPE=${SA_VER_ARRAY[2]}
	RELEASENUM=${SA_VER_ARRAY[3]}
	writeLog "Found RSA Security Analytics $SAMAJOR.$SAMINOR.$BUILDTYPE" 
	if [[ $SAMAJOR != 10 || !( $SAMINOR =~ ^3|4$ ) ]]; then 
		writeLog "SA Backup script can only work on SA version 10.3 or 10.4" 
		exit 1
	fi 
}
####################################################################
# Returns original service's status 
# ARGUMENTS:
# 1 - Service name
# 2 - Service type (upstart|init)
# 3 - Return variable (stop|start)
# Returns 1 - service started; 0 - stopped  
####################################################################
function check_ServiceStatus() {
	local _SERVICE=$1
	local _SERVICE_TYPE=$2
	local _RESULTVAR=$3
	local _RETURNVAL=0
	local __RESTART=""
	[[ "$_SERVICE_TYPE" = "init" ]] && _RETURNVAL=$(service ${_SERVICE} status | grep -E "is running|running_applications" | wc -l);
	[[ "$_SERVICE_TYPE" = "upstart" ]] && _RETURNVAL=$(status ${_SERVICE} | grep "start/running" | wc -l);
	if [ $_RETURNVAL -eq 1 ]; then 
		__RESTART="start"
	else 
		__RESTART="stop"
	fi
	eval $_RESULTVAR="'$__RESTART'"
	return $_RETURNVAL 
}

####################################################################
# Determine components present on the box
####################################################################
function what_to_backup() {
	COMPONENT+=([OS configuration]="backup_etc")
	
	if [ -d /var/lib/puppet ]; then
		COMPONENT+=([Puppet]="backup_Puppet")
	fi
	if [ -d /var/lib/rabbitmq ]; then
		COMPONENT+=([RabbitMQ server]="backup_RabbitMQ")
	fi
	if [ -d /etc/netwitness/ng ]; then
		COMPONENT+=([Core Appliance Services]="backup_CoreAppliance")
	fi
	if [ -f /usr/bin/mongodump ]; then
		COMPONENT+=([MongoDB]="backup_Mongo")
	fi
	if [ -d /var/lib/netwitness/uax ]; then
		COMPONENT+=([SA Server]="backup_Jetty")
	fi
	if [ -d /home/rsasoc/rsa/soc/reporting-engine ]; then
		COMPONENT+=([Reporting Engine]="backup_RE")
	fi
	if [ -d /var/lib/netwitness/rsamalware ]; then
		COMPONENT+=([Malware Analysis]="backup_Malware")
	fi
	if [ -d /opt/rsa/esa ]; then
		COMPONENT+=([Event Stream Analysis]="backup_ESA")
	fi
	if [ -d /opt/rsa/im ]; then
		COMPONENT+=([Incident Management server]="backup_IM")
	fi	
	if [ -d /var/netwitness/logcollector ]; then
		COMPONENT+=([Log Collector]="backup_LC")
	fi
	if [ -d /var/netwitness/warehouseconnector ]; then
		COMPONENT+=([Warehouse Connector]="backup_WHC")
	fi
	if [ -d /var/lib/pgsql ]; then
		COMPONENT+=([PestgreSQL Database]="backup_PostgreSQL")
	fi	
} 

####################################################################
## CORE APPLIANCE SERVICES CONFIGURATION: 
# Log Decoder, Archiver, Decoder, Concentrator, Broker, Log Collector, IPDBExtrator 
# COREAPP=/etc/netwitness/
####################################################################
function backup_CoreAppliance() {
	local _RESTART
	local _SERVICE_RESTART=()
	writeLog "============================================================="
	writeLog "Backup of Core appliance ${COREAPP}"
	writeLog "Stopping SA Core services."
	NWSERVICES=('nwconcentrator' 'nwarchiver' 'nwdecoder' 'nwbroker' 'nwlogcollector' 'nwlogdecoder' 'nwipdbextractor')
	for i in "${NWSERVICES[@]}"
	do
		if ! check_ServiceStatus $i upstart _RESTART; then 
			stop $i 2>&1 | tee -a $LOG
			_SERVICE_RESTART+=("$i") 
		fi
	done
	echo "${_SERVICE_RESTART[@]}"	
	writeLog "tar -C / --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-etc-netwitness.$timestamp.tar.gz ${COREAPP}"
	tar -C / --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-etc-netwitness.$timestamp.tar.gz ${COREAPP} --exclude=${COREAPP}/Geo*.dat --exclude=${COREAPP}/envision/etc/devices 2>&1 | tee -a $LOG
		syslogOnError ${PIPESTATUS[0]} "SA backup failed to archive Core appliance configuration files ${COREAPP}."
		
	writeLog "Starting SA Core services"	
	for i in "${_SERVICE_RESTART[@]}"; do
		start "${i}" 2>&1 | tee -a $LOG
	done

}	
####################################################################
# REPORTING ENGINE 
# REPORTING=/home/rsasoc/rsa/soc/reporting-engine
####################################################################
# Reporting Engine 
function backup_RE {
	writeLog "============================================================="
	writeLog "Backup of Reporting Engine ${REPORTING}"
	local EXCL_FILES=''
	local _RESTART
	#Backup only last 2 DB archives. Creating an exclude parameter for old DB archives files   
	for i in $(ls -1tr ${REPORTING}/archives | head -n -2)
	  do
		EXCL_FILES+=" --exclude=${REPORTING}/archives/${i}"
	  done 

	check_ServiceStatus rsasoc_re upstart _RESTART || stop rsasoc_re 2>&1 | tee -a $LOG
	  
	if [ "$RE_FULLBACKUP" -eq 0 ]; then 
		writeLog "Backing up Reporting Engine configuration files..."
		writeLog "tar --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-home-rsasoc-rsa-soc-reporting-engine.$timestamp.tar.gz ${REPORTING}"
			tar --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-home-rsasoc-rsa-soc-reporting-engine.$timestamp.tar.gz ${REPORTING} \
			--exclude=${REPORTING}/formattedReports \
			--exclude=${REPORTING}/resultstore \
			--exclude=${REPORTING}/livecharts \
			--exclude=${REPORTING}/statusdb \
			--exclude=${REPORTING}/subreports \
			--exclude=${REPORTING}/temp \
			--exclude=${REPORTING}/logs \
			${EXCL_FILES} 2>&1 | tee -a $LOG
			syslogOnError ${PIPESTATUS[0]} "SA backup failed to archive Reporting engine conf files ${REPORTING}."		
	else 
		writeLog "Full RE backup enabled."
		writeLog "tar --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-home-rsasoc-rsa-soc-reporting-engine.$timestamp.tar.gz ${REPORTING}"
		tar --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-home-rsasoc-rsa-soc-reporting-engine.$timestamp.tar.gz ${REPORTING} --exclude=${REPORTING}/temp 2>&1 | tee -a $LOG
			syslogOnError ${PIPESTATUS[0]} "SA backup failed to archive Reporting engine files ${REPORTING}."	
		fi;

	$_RESTART rsasoc_re 2>&1 | tee -a $LOG
}

####################################################
## SA SERVER and JETTY 
# SASERVER1=/var/lib/netwitness/uax
# JETTYSRV=/opt/rsa/jetty9/etc	
####################################################
function backup_Jetty() {
	local _RESTART
	writeLog "============================================================="
	writeLog "Backup of SA server ${SASERVER1}"
	check_ServiceStatus jettysrv upstart _RESTART || stop jettysrv 2>&1  && sleep 5 | tee -a $LOG
	local EXCL_FILES=""
	#Backup only last 2 H2 DB archives. Creating an exclude parameter for old H2 DB archives files   
	for i in $(ls -1tr ${SASERVER1}/db/*.zip | head -n -2)
	  do
		EXCL_FILES+=" --exclude=${i}"
	  done 
	writeLog "tar -C / --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-var-lib-netwitness-uax.$timestamp.tar.gz ${SASERVER1}"		 
	tar -C / --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-var-lib-netwitness-uax.$timestamp.tar.gz ${SASERVER1} \
		--exclude=${SASERVER1}/temp \
		--exclude=${SASERVER1}/trustedStorage \
		--exclude=${SASERVER1}/cache \
		--exclude=${SASERVER1}/yum \
		--exclude=${SASERVER1}/logs/*_index \
		--exclude=${SASERVER1}/content \
		--exclude=${SASERVER1}/lib \
		--exclude=${SASERVER1}/scheduler \
		${EXCL_FILES} 2>&1 | tee -a $LOG
		syslogOnError ${PIPESTATUS[0]} "SA backup failed to archive SA server conf files ${SASERVER1}"	

	writeLog "Restarting jetty server"		
	$_RESTART jettysrv 2>&1 | tee -a $LOG
	
	# Backup Jetty key store
	writeLog "============================================================="
	writeLog "Backup of Jetty keystore"
	writeLog "tar -C / --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-opt-rsa-jetty9-etc.$timestamp.tar.gz ${JETTYSRV}/keystore ${JETTYSRV}/jetty-ssl.xml"
	tar -C / --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-opt-rsa-jetty9-etc.$timestamp.tar.gz ${JETTYSRV}/keystore ${JETTYSRV}/jetty-ssl.xml 2>&1 | tee -a $LOG
		syslogOnError ${PIPESTATUS[0]} "SA backup failed to archive Jetty keystore files ${JETTYSRV}"	
}
	
####################################################
## MONGODB INSTANCE
####################################################
function backup_Mongo() {
	local _RESTART
	writeLog "============================================================="
	writeLog "Backup of MongoDB."
	# MongoDB must be running. 
	check_ServiceStatus tokumx init _RESTART && service tokumx start 2>&1  && sleep 10 | tee -a $LOG
	# Lazy solution. If ESA server then temporarily disable auth to dump entire instance. 
	if [ -d /opt/rsa/esa ]; then 
		sed -i "s/\(auth *= *\).*/\1false/" /etc/tokumx.conf 
		service tokumx restart 2>&1 | tee -a $LOG
		sleep 10
	fi

	#Force file synchronization and lock writes
	writeLog "Force file synchronization and lock writes"
	mongo admin --eval "printjson(db.fsyncLock())" 2>&1 | tee -a $LOG
	writeLog "mongodump --out ${BACKUP}/$HOST-mongodb-dump.$timestamp"
	mongodump --out ${BACKUP}/$HOST-mongodb-dump.$timestamp 2>&1 | tee -a $LOG
		syslogOnError ${PIPESTATUS[0]} "SA backup failed to dump the Mongo DB."	
	#Unlock database writes
	writeLog "Unlocking database writes"
	mongo admin --eval "printjson(db.fsyncUnlock())" 2>&1 | tee -a $LOG

	if [ -d /opt/rsa/esa ]; then 
		sed -i "s/\(auth *= *\).*/\1true/" /etc/tokumx.conf 
		service tokumx restart 2>&1 | tee -a $LOG
	fi	

	service tokumx $_RESTART 2>&1 | tee -a $LOG
	
	writeLog "tar -C / --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-mongodb-dump.$timestamp.tar.gz ${BACKUP}/$HOST-mongodb-dump.$timestamp"
	tar -C ${BACKUP} --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-mongodb-dump.$timestamp.tar.gz $HOST-mongodb-dump.$timestamp 2>&1 | tee -a $LOG
		syslogOnError ${PIPESTATUS[0]} "SA backup failed to archive MongoDB dump."		
	rm -Rf ${BACKUP}/$HOST-mongodb-dump.$timestamp
}	
	
####################################################################
## ESA
# ESASERVER1=/opt/rsa/esa
####################################################################
function backup_ESA() {
	local _RESTART
	writeLog "============================================================="	
	writeLog "Backup of ESA server: ${ESASERVER1}"
	check_ServiceStatus rsa-esa init _RESTART || service rsa-esa stop 2>&1 | tee -a $LOG

	writeLog "tar -C / --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-opt-rsa-esa.$timestamp.tar.gz $ESASERVER1 --exclude=${ESASERVER1}/lib --exclude=${ESASERVER1}/bin 	--exclude=${ESASERVER1}/geoip --exclude=${ESASERVER1}/db --exclude=${ESASERVER1}/temp --exclude=${ESASERVER1}/client"
	tar -C / --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-opt-rsa-esa.$timestamp.tar.gz $ESASERVER1 \
		--exclude=${ESASERVER1}/lib \
		--exclude=${ESASERVER1}/bin \
		--exclude=${ESASERVER1}/geoip \
		--exclude=${ESASERVER1}/db \
		--exclude=${ESASERVER1}/temp \
		--exclude=${ESASERVER1}/client 2>&1 | tee -a $LOG
		syslogOnError ${PIPESTATUS[0]} "SA backup failed to archive ESA files ${ESASERVER1}."
		
	service rsa-esa $_RESTART 2>&1 | tee -a $LOG		
} 

####################################################################
## Incident Management
# IM=/opt/rsa/im
####################################################################
function backup_IM() {
	local _RESTART
	writeLog "============================================================="
	writeLog "Backup of Incident Management ${IM}"
	check_ServiceStatus rsa-im init _RESTART || service rsa-im stop 2>&1 | tee -a $LOG	

	writeLog "tar -C / --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-opt-rsa-im.$timestamp.tar.gz ${IM} --exclude=${IM}/lib --exclude=${IM}/bin --exclude=${IM}/scripts --exclude=${IM}/db"
	tar -C / --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-opt-rsa-im.$timestamp.tar.gz ${IM} \
		--exclude=${IM}/lib \
		--exclude=${IM}/bin \
		--exclude=${IM}/scripts \
		--exclude=${IM}/db  2>&1 | tee -a $LOG
		syslogOnError ${PIPESTATUS[0]} "SA backup failed to archive RSA IM files ${IM}."	

		service rsa-im $_RESTART 2>&1 | tee -a $LOG		
} 
 
####################################################################
## RSAMALWARE
# RSAMALWARE=/var/lib/netwitness/rsamalware
####################################################################
function backup_Malware() {
	local _RESTART
	writeLog "============================================================="
	writeLog "Backup of Malware Analysis ${RSAMALWARE}"
	check_ServiceStatus rsaMalwareDevice upstart _RESTART || stop rsaMalwareDevice 2>&1 && sleep 5 | tee -a $LOG	
	
	writeLog "tar -C / --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-var-lib-netwitness-rsamalware.$timestamp.tar.gz $RSAMALWARE"
	tar -C / --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-var-lib-netwitness-rsamalware.$timestamp.tar.gz $RSAMALWARE \
		--exclude=${RSAMALWARE}/jetty/javadoc \
		--exclude=${RSAMALWARE}/jetty/lib \
		--exclude=${RSAMALWARE}/jetty/logs \
		--exclude=${RSAMALWARE}/jetty/webapps \
		--exclude=${RSAMALWARE}/jetty/bin \
		--exclude=${RSAMALWARE}/lib \
		--exclude=${RSAMALWARE}/spectrum/yara \
		--exclude=${RSAMALWARE}/spectrum/logs \
		--exclude=${RSAMALWARE}/spectrum/cache \
		--exclude=${RSAMALWARE}/spectrum/temp \
		--exclude=${RSAMALWARE}/spectrum/lib \
		--exclude=${RSAMALWARE}/spectrum/repository \
		--exclude=${RSAMALWARE}/spectrum/infectedZipWatch \
		--exclude=${RSAMALWARE}/spectrum/index \
		--exclude=${RSAMALWARE}/saw 2>&1 | tee -a $LOG
		syslogOnError ${PIPESTATUS[0]} "SA backup failed to archive the RSA Malware files ${RSAMALWARE}."	

	$_RESTART rsaMalwareDevice 2>&1 | tee -a $LOG	
}
  
####################################################################
## LOG COLLECTOR
# LOGCOL=/var/netwitness/logcollector
####################################################################  
function backup_LC() {
	writeLog "============================================================="
	writeLog "Backup of Log Collector ${LOGCOL}"
	check_ServiceStatus nwlogcollector upstart _RESTART || stop nwlogcollector 2>&1  && sleep 5	| tee -a $LOG

	writeLog "tar --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-var-netwitness-logcollector.$timestamp.tar.gz $LOGCOL"
	
    tar -C / --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-var-netwitness-logcollector.$timestamp.tar.gz $LOGCOL --exclude=$LOGCOL/metadb/core.* 2>&1 | tee -a $LOG
		syslogOnError ${PIPESTATUS[0]} "SA backup failed to archive the Log Collector files ${LOGCOL}."	

	$_RESTART nwlogcollector 2>&1 | tee -a $LOG	
}

####################################################################
## WAREHOUSE CONNECTOR
# WHC=/var/netwitness/warehouseconnector
####################################################################
function backup_WHC() {  
	local _RESTART
	writeLog "============================================================="
	writeLog "Backup of Warehouse Connector ${WHC}"
	check_ServiceStatus nwwarehouseconnector upstart _RESTART || stop nwwarehouseconnector 2>&1 | tee -a $LOG	

	writeLog "tar -C / --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-var-netwitness-warehouseconnector.$timestamp.tar.gz $WHC"
    tar -C / --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-var-netwitness-warehouseconnector.$timestamp.tar.gz $WHC 2>&1 | tee -a $LOG
		syslogOnError ${PIPESTATUS[0]} "SA backup failed to archive the Warehouse connector files ${WHC}."	
	$_RESTART nwwarehouseconnector 2>&1 | tee -a $LOG	
}  

####################################################################
## Operating System configuration files in /etc
# /etc/sysconfig/network-scripts/ifcfg-eth* 
# /etc/sysconfig/network 
# /etc/hosts 
# /etc/resolv.conf 
# /etc/ntp.conf 
# /etc/fstab - renamed to fstab.$ to prevent overwriting the original fstab on restore
# /etc/krb5.conf
#################################################################### 
function backup_etc() { 
	writeLog "============================================================="
    writeLog "Backup of OS files /etc"
	cp /etc/fstab /etc/fstab.$HOST
    writeLog "tar -C / --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-etc.$timestamp.tar.gz /etc/sysconfig/network-scripts/ifcfg-eth* /etc/sysconfig/network /etc/hosts /etc/resolv.conf /etc/ntp.conf /etc/fstab /etc/krb5.conf"
    tar -C / --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-etc.$timestamp.tar.gz /etc/sysconfig/network-scripts/ifcfg-eth* /etc/sysconfig/network /etc/hosts /etc/resolv.conf /etc/ntp.conf /etc/fstab.$HOST /etc/krb5.conf 2>&1 | tee -a $LOG
		syslogOnError ${PIPESTATUS[0]} "SA backup failed to archive system configuration files."
	rm -f /etc/fstab.$HOST
}

####################################################################
## PUPPET
# PUPPET1=/var/lib/puppet
# PUPPET2=/etc/puppet
####################################################################
function backup_Puppet() {	
	local _RESTART
	writeLog "============================================================="
	writeLog "Backup of Puppet"
	if [ -d "${PUPPET1}" ]; then
		check_ServiceStatus puppetmaster init _RESTART || service puppetmaster stop 2>&1 | tee -a $LOG	

		writeLog "tar -C / --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-var-lib-puppet-etc.$timestamp.tar.gz ${PUPPET1}/ssl ${PUPPET1}/node_id ${PUPPET2}/puppet.conf ${PUPPET2}/csr_attributes.yaml" 
		tar -C / --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-var-lib-puppet-etc.$timestamp.tar.gz ${PUPPET1}/ssl ${PUPPET1}/node_id ${PUPPET2}/puppet.conf ${PUPPET2}/csr_attributes.yaml 2>&1 | tee -a $LOG
			syslogOnError ${PIPESTATUS[0]} "SA backup failed to archive the Puppet conf files ${PUPPET1}."	

		service puppetmaster $_RESTART 2>&1 | tee -a $LOG		
	fi;		
}	

####################################################################
## RABBITMQ
# RABBITMQ=/var/lib/rabbitmq
####################################################################
function backup_RabbitMQ() {
	local _RESTART
	writeLog "============================================================="
	writeLog "Backup of RabbitMQ DB - ${RABBITMQ}" 
	check_ServiceStatus rabbitmq-server init _RESTART || service rabbitmq-server stop 2>&1 && sleep 10 | tee -a $LOG	

	writeLog "tar -czvf ${BACKUP}/$HOST-var-lib-rabbitmq.$timestamp.tar.gz ${RABBITMQ}" 
	tar -C / --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-var-lib-rabbitmq.$timestamp.tar.gz ${RABBITMQ} 2>&1 | tee -a $LOG
		syslogOnError ${PIPESTATUS[0]} "SA backup failed to archive the RabbitMQ files ${RABBITMQ}."	

	# Backup the RabbitMQ configuration for 10.3 
	if [[ ! -h /etc/netwitness/ng/rabbitmq && $SAMINOR -eq 3 ]]; then 
		writeLog "Backup of RabbitMQ Configuration - /etc/rabbitmq" 
		tar -C / --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-etc-rabbitmq.$timestamp.tar.gz /etc/rabbitmq 2>&1 | tee -a $LOG
	fi 
	service rabbitmq-server $_RESTART 2>&1 | tee -a $LOG	
}
####################################################################
## POSTGRESQL=/var/lib/pgsql
####################################################################
function backup_PostgreSQL() {
	local _RESTART
	writeLog "============================================================="
	writeLog "Backup of PostgreSQL"
	
	PGDATA=$(find /etc/init.d/ -name postgresql* -exec cat {} \;  | grep -m 1 "PGDATA=" | sed 's/^PGDATA=//')
	if [[ -z ${PGDATA} ]]; then 
		syslogMessage  1 "Could determine the data directory. PestgreSQL will not be backed up"
		return 1
	fi
	
	if [[ $(find /etc/init.d/ -name postgresql* -exec {} status \; | grep -E "is running|running_applications" | wc -l) -eq 1 ]]; then 
		_RESTART="start"
		find /etc/init.d/ -name postgresql* -exec {} stop \; 2>&1 | tee -a $LOG
	else 
		_RESTART="stop"
	fi
	
	tar -C / --atime-preserve --recursion -cphzf ${BACKUP}/$HOST-var-lib-pgsql.$timestamp.tar.gz ${PGDATA} 2>&1 | tee -a $LOG
		syslogOnError ${PIPESTATUS[0]} "SA backup failed to archive PostgreSQL database ${PGDATA}."
	
	
	find /etc/init.d/ -name postgresql* -exec {} $_RESTART \; 2>&1 | tee -a $LOG
	
}

do_Backup() {
	writeLog "The components to back up:"
	for i in "${!COMPONENT[@]}"; do writeLog "- $i"; done

	if [[ $SAMINOR -ge 4 ]]; then 
		writeLog "Stopping Puppet agent."
		service puppet stop 2>&1 | tee -a $LOG
	fi

	for i in "${COMPONENT[@]}"
	do
		$i  
	done
	
	if [[ $SAMINOR -ge 4 ]]; then 
		writeLog "Starting Puppet agent."
		service puppet start 2>&1 | tee -a $LOG
	fi	
	
	writeLog "END $HOST BACKUP"
}

main(){
	writeLog "STARTING $HOST BACKUP"
	mkdir -p ${BACKUP}

	check_root
	check_isRun $SCRIPT_NAME
	check_SAVersion
	rotate_Logs 
#	get_Agrs TO DO
	what_to_backup
	
	do_Backup
#	do_RemoteBackup  TO DO
	do_Cleanup
}

if [ x"${0}" != x"-bash" ]; then 
	main
	exit 0 
fi
	