#!/bin/bash

dbname=zabbix

#####################################################################
# UNinstall_partitioning.sh
# Removes PostgreSQL partitioning for Zabbix history and trend tables
#
# Adapted From:
#   https://www.zabbix.org/wiki/Docs/howto/zabbix2_postgresql_autopartitioning
#
# - Must be run as DB super-user
#####################################################################

main () {
  echo '================================================================'
  date +"%Y-%m-%d %H:%M:%S %Z"
  echo "Logging to: ${logfile}"
  echo "Settings:"
  echo "   dbname=${dbname}"
  drop_partition_triggers || exit 1
  drop_trigger_function || exit 1
  echo 'BEGIN;' > copy_and_drop.sql
  gen_copy_sql >> copy_and_drop.sql || exit 1
  echo 'DROP SCHEMA partitions CASCADE;' >> copy_and_drop.sql
  echo 'DROP FUNCTION zbx_part_cleanup_func(interval, text);' >> copy_and_drop.sql
  echo 'COMMIT;' >> copy_and_drop.sql
  echo "${notice1}"
}


drop_partition_triggers () {
  echo 'drop_partitions ------------------------------------------------'
  date +"%Y-%m-%d %H:%M:%S %Z"
  psql -Xe -v ON_ERROR_STOP=on ${dbname} <<EOF
    DROP TRIGGER zbx_partition_trg ON history;
    DROP TRIGGER zbx_partition_trg ON history_uint;
    DROP TRIGGER zbx_partition_trg ON history_str;
    DROP TRIGGER zbx_partition_trg ON history_text;
    DROP TRIGGER zbx_partition_trg ON history_log;
    DROP TRIGGER zbx_partition_trg ON trends;
    DROP TRIGGER zbx_partition_trg ON trends_uint;
EOF
  rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "================================"
    echo " Triggers successfully dropped."
    echo "================================"
  fi
  return $rc
}


drop_trigger_function () {
  echo 'drop_trigger_function ------------------------------------------'
  date +"%Y-%m-%d %H:%M:%S %Z"
  psql -Xe -v ON_ERROR_STOP=on ${dbname} <<EOF
    DROP FUNCTION zbx_part_trigger_func();
EOF
  rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "========================================"
    echo " Trigger function successfully dropped."
    echo "========================================"
  fi
  return $rc
}


gen_copy_sql () {
  echo '-- gen_copy_sql ---------------------------------------------------'
  date +"-- %Y-%m-%d %H:%M:%S %Z"
  psql -Xqt -v ON_ERROR_STOP=on ${dbname} <<EOF | egrep -v '^$'
    SELECT 'INSERT INTO public.history SELECT * from partitions.' || table_name ||';'
      FROM information_schema.tables
     WHERE table_schema = 'partitions'
       AND table_name LIKE 'history_p%'
     ORDER BY 1;
    SELECT 'INSERT INTO public.history_log SELECT * from partitions.' || table_name ||';'
      FROM information_schema.tables
     WHERE table_schema = 'partitions'
       AND table_name LIKE 'history_log_p%'
     ORDER BY 1;
    SELECT 'INSERT INTO public.history_str SELECT * from partitions.' || table_name ||';'
      FROM information_schema.tables
     WHERE table_schema = 'partitions'
       AND table_name LIKE 'history_str_p%'
     ORDER BY 1;
    SELECT 'INSERT INTO public.history_text SELECT * from partitions.' || table_name ||';'
      FROM information_schema.tables
     WHERE table_schema = 'partitions'
       AND table_name LIKE 'history_text_p%'
     ORDER BY 1;
    SELECT 'INSERT INTO public.history_uint SELECT * from partitions.' || table_name ||';'
      FROM information_schema.tables
     WHERE table_schema = 'partitions'
       AND table_name LIKE 'history_uint_p%'
     ORDER BY 1;
    SELECT 'INSERT INTO public.trends SELECT * from partitions.' || table_name ||';'
      FROM information_schema.tables
     WHERE table_schema = 'partitions'
       AND table_name LIKE 'trends_p%'
     ORDER BY 1;
    SELECT 'INSERT INTO public.trends_uint SELECT * from partitions.' || table_name ||';'
      FROM information_schema.tables
     WHERE table_schema = 'partitions'
       AND table_name LIKE 'trends_uint_p%'
     ORDER BY 1;
EOF
  return ${PIPESTATUS[0]}
}


#########
# SETUP #
#########

notice1='
============================================================

                        =========
                        NOTICE!!!
                        =========

The "daily_partition_cleanup.sh" function, "partitions"
schema, and partitioned tables were *NOT DROPPED*.  You will
need to decide how to save the history and trend data.

You can either:

1. Run the generated "copy_and_drop.sql" SQL file against
   the zabbix database (*NOT RECOMMENDED* for more than 1gb
   of partitioned data).

*OR*

2. Allow the "daily_partition_cleanup.sh" script to continue
   running from cron to automatically drop the partitions as
   they age out.

If you choose option #2, you will need to execute the
following steps manually (weeks or months later) after all
the partitions been dropped by the cleanup script:
  * Remove the cleanup job from the crontab
  * Drop the "partitions" schema and the cleanup function

The SQL for option #1 has been written to file
"copy_and_drop.sql" in your current working directory.

=================
  BE SURE TO... 
=================
If the housekeeper was disabled in Zabbix, be sure to
re-enable it to purge the history and trend data from the
main tables.

============================================================
'

logfile=UNinstall_partitioning.$(date "+%Y-%m-%d_%H.%M").log

main 2>&1 | tee -a ${logfile}

