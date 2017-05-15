#!/bin/bash

dbname=zabbix

daily_retention='31 days'
monthly_retention='12 months'

cleanup_log_retention=31   # days

#####################################################################
# daily_partition_cleanup.sh
# Drop old PostgreSQL history and trend partitions from the Zabbix DB
#
# This script will drop old history and trend partitions from
# the zabbix database based on retentions set above.
#
# Adapted from:
#   https://www.zabbix.org/wiki/Docs/howto/zabbix2_postgresql_autopartitioning
#
# - Must be run as DB super-user
# - Should be run daily from cron, but *NOT* during a DB backup
#
# A "logs" directory will be automatically created below the directory
# where this cleanup script is executed. The logs will be purged
# automatically based on the above log retention.
#
#####################################################################

main() {
  # clean up old logs
  find ${logdir} -name "${sscript}.*.log" -mtime +${cleanup_log_retention} -delete
  # begin run
  echo '================================================================'
  date +"%Y-%m-%d %H:%M:%S %Z"
  echo "Script..: ${abspath}/${script}"
  echo "Hostname: `hostname`"
  echo "Logfile.: ${logfile}"
  echo "Settings:"
  echo "   dbname=${dbname}"
  echo "   daily_retention='${daily_retention}'"
  echo "   monthly_retention='${monthly_retention}'"
  echo "   cleanup_log_retention=${cleanup_log_retention}"
  echo
  drop_old_partitions || exit 1
}


drop_old_partitions () {
  echo 'drop_old_partitions --------------------------------------------'
  date +"%Y-%m-%d %H:%M:%S %Z"
  echo
  psql -Xe -v ON_ERROR_STOP=on ${dbname} <<EOF
    SELECT zbx_part_cleanup_func('${daily_retention}', 'day');
    SELECT zbx_part_cleanup_func('${monthly_retention}', 'month');
EOF
  rc=$?
  # error encountered?
  if [[ ${rc} -ne 0 ]]; then
    # force cron to email someone (be sure to set "MAILTO" in crontab)
    # add two blanks to beginning of every line to prevent MS Outlook automatic word-wrapping
    echo "
  ************* ERROR encountered!

  ERROR in Zabbix partition maintenance script!

  Script..: ${abspath}/${script}
  Host....: `hostname`
  Database: ${dbname}
  Log file: ${logfile}
  Date....: `date +'%Y-%m-%d %H:%M:%S %Z'`

  Please investigate!!!


  Tail of log:
  ============
`tail ${logfile}|sed -e 's/^/  /'`
" >&3
    # write to log
    echo '************* ERROR encountered! Exiting...'
  fi
  echo "Ended: `date +'%Y-%m-%d %H:%M:%S %Z'`"
  echo
  return $rc
}


#########
# SETUP #
#########

abspath=`cd ${0%/*};pwd`     # get absolute path of script directory
logdir=${abspath}/logs       # log directory under script directory
script=${0##*/}              # script name
sscript=${script%.*}         # script name without ".sh"
logfile=${logdir}/${sscript}.$(date "+%Y-%m-%d").log

# create log subdirectory if does not exist
if [[ ! -d ${logdir} ]]; then
  mkdir -p ${logdir}
  if [[ $? -ne 0 ]]; then
    echo "`hostname` ${0} ERROR: unable to create log directory" >&2
    exit 2
  fi
fi

# non-interactive?
if [[ $(tty) == "not a tty" ]]; then # run non-interactively (i.e. cron)
  exec 3>&2                          # save stderr descriptor to send error emails from cron
  main >> ${logfile} 2>&1            # everything else to log file
else                                 # run interactively (i.e. human)
  exec 3>/dev/null                   # no need to send email errors
  main 2>&1 | tee -a ${logfile}      # send to both stdout and logfile
fi
exec 3>&- # close descriptor

