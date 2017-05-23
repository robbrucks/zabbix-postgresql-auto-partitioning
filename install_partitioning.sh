#!/bin/bash

dbname=zabbix
dbowner=zabbix

#####################################################################
# install_partitioning.sh
# Sets up Automatic PostgreSQL partitioning for Zabbix history and trend tables
#
# Adapted From:
#   https://www.zabbix.org/wiki/Docs/howto/zabbix2_postgresql_autopartitioning
#
# - Must be run as DB super-user
#
# Defaults:
#   "history*" tables:  daily partitions ("day")
#   "trends*"  tables:  monthly partitions ("month")
#
#   You can change the defaults further down in section "add_partition_triggers"
#   
#   Settings available:
#     "day"   - create daily partitions
#     "month" - create monthly partitions
#
#####################################################################

main () {
  echo '================================================================'
  date +"%Y-%m-%d %H:%M:%S %Z"
  echo "Logging to: ${logfile}"
  echo "Settings:"
  echo "   dbname=${dbname}"
  echo "   dbowner=${dbowner}"
  create_partition_schema || exit 1
  create_trigger_function || exit 1
  create_cleanup_function || exit 1
  add_partition_triggers || exit 1
}


create_partition_schema () {
  echo 'create_partition_schema ----------------------------------------'
  date +"%Y-%m-%d %H:%M:%S %Z"
  psql -Xe -v ON_ERROR_STOP=on ${dbname} <<EOF
    CREATE SCHEMA partitions
      AUTHORIZATION ${dbowner};
EOF
  rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "=============================="
    echo " Schema successfully created."
    echo "=============================="
  fi
  return $rc
}


# create this trigger function owned by postgres
create_trigger_function () {
  echo 'create_trigger_function ----------------------------------------'
  date +"%Y-%m-%d %H:%M:%S %Z"
  psql -Xe -v ON_ERROR_STOP=on ${dbname} <<"EOF"
    CREATE OR REPLACE FUNCTION zbx_part_trigger_func() RETURNS trigger AS
    $BODY$
      DECLARE
        prefix     text := 'partitions';
        timeformat text;
        selector   text;
        _interval  interval;
        tablename  text;
        startdate  text;
        enddate    text;
        create_table_part text;
        create_index_part text;

      BEGIN
        BEGIN
          selector = TG_ARGV[0];
     
          IF selector = 'day' THEN
            timeformat := 'YYYY_MM_DD';
          ELSIF selector = 'month' THEN
            timeformat := 'YYYY_MM';
          ELSE
            RAISE EXCEPTION 'zbx_part_trigger_func: Specify "day" or "month" for interval selector instead of "%"', selector;
          END IF;
     
          _interval := '1 ' || selector;
          tablename :=  TG_TABLE_NAME || '_p' || to_char(to_timestamp(NEW.clock), timeformat);
     
          EXECUTE 'INSERT INTO ' || quote_ident(prefix) || '.' || quote_ident(tablename) || ' SELECT ($1).*' USING NEW;
          RETURN NULL;
     
        /* trap when table partition does not yet exist: create the table partition and then insert */
        EXCEPTION
          WHEN undefined_table THEN
            startdate := extract(epoch FROM date_trunc(selector, to_timestamp(NEW.clock)));
            enddate := extract(epoch FROM date_trunc(selector, to_timestamp(NEW.clock) + _interval ));
            create_table_part := 'CREATE TABLE IF NOT EXISTS ' || quote_ident(prefix) || '.' || quote_ident(tablename)
                              || ' (CHECK ((clock >= ' || quote_literal(startdate)
                              || ' AND clock < ' || quote_literal(enddate)
                              || '))) INHERITS (' || TG_TABLE_NAME || ')';
            create_index_part := 'CREATE INDEX IF NOT EXISTS ' || quote_ident(tablename)
                              || '_1 on ' || quote_ident(prefix) || '.' || quote_ident(tablename) || '(itemid,clock)';
            EXECUTE create_table_part;
            EXECUTE create_index_part;
            --insert it again
            EXECUTE 'INSERT INTO ' || quote_ident(prefix) || '.' || quote_ident(tablename) || ' SELECT ($1).*' USING NEW;
            RETURN NULL;
        END;

      /* trap race condition where a parallel thread beat us creating the table partition: re-try the original insert */
      EXCEPTION
        WHEN duplicate_table THEN
          EXECUTE 'INSERT INTO ' || quote_ident(prefix) || '.' || quote_ident(tablename) || ' SELECT ($1).*' USING NEW;
          RETURN NULL;
      END;
    $BODY$
    LANGUAGE plpgsql VOLATILE
    COST 100;
EOF
  rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "=================================================="
    echo " Partition Trigger Function Successfully Created."
    echo "=================================================="
  fi
  return $rc
}


# create this cleanup function owned by postgres
create_cleanup_function () {
  echo 'create_cleanup_function ----------------------------------------'
  date +"%Y-%m-%d %H:%M:%S %Z"
  psql -Xe -v ON_ERROR_STOP=on ${dbname} <<"EOF"
    CREATE OR REPLACE FUNCTION zbx_part_cleanup_func(retention_age interval, partition_interval text) RETURNS text AS
    $BODY$
      DECLARE
        result        record;
        prefix        text      := 'partitions';
        table_ts_len  integer;
        table_ts      timestamp;
        min_ts        timestamp;
    
      BEGIN
        IF partition_interval NOT IN ('day','month') THEN
          RAISE EXCEPTION 'Please specify "day" or "month" for partition_interval instead of "%"', partition_interval;
        END IF;
        IF retention_age < ('1 ' || partition_interval)::interval THEN
          RAISE EXCEPTION 'Retention age "%" cannot be less than "1 %"', retention_age, partition_interval;
        END IF;

        min_ts := date_trunc('day', NOW() - retention_age);
        RAISE NOTICE 'Dropping "%" partitions older than "%" (created before %)', partition_interval, retention_age, min_ts;

        FOR result IN SELECT * FROM pg_tables WHERE schemaname = quote_ident(prefix) LOOP

          table_ts_len := length(substring(result.tablename from '[0-9_]*$'));
          table_ts := to_timestamp(substring(result.tablename from '[0-9_]*$'), 'YYYY_MM_DD');

          IF ( table_ts_len = 10 AND partition_interval = 'day' )
          OR ( table_ts_len = 7  AND partition_interval = 'month' ) THEN

            IF table_ts < min_ts THEN
              RAISE NOTICE '  Dropping partition table %.%', quote_ident(prefix), quote_ident(result.tablename);
              EXECUTE 'DROP TABLE ' || quote_ident(prefix) || '.' || quote_ident(result.tablename) || ';';
            END IF;

          END IF;
        END LOOP;
        RETURN 'OK';
      END;
    $BODY$
    LANGUAGE plpgsql VOLATILE
  COST 100;
EOF
  rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "=================================================="
    echo " Partition Cleanup Function Successfully Created."
    echo "=================================================="
  fi
  return $rc
}


add_partition_triggers () {
  echo 'add_partition_triggers -----------------------------------------'
  date +"%Y-%m-%d %H:%M:%S %Z"
  psql -Xe -v ON_ERROR_STOP=on ${dbname} <<EOF
    SET ROLE ${dbowner};
    CREATE TRIGGER zbx_partition_trg BEFORE INSERT ON history           FOR EACH ROW EXECUTE PROCEDURE zbx_part_trigger_func('day');
    CREATE TRIGGER zbx_partition_trg BEFORE INSERT ON history_uint      FOR EACH ROW EXECUTE PROCEDURE zbx_part_trigger_func('day');
    CREATE TRIGGER zbx_partition_trg BEFORE INSERT ON history_str       FOR EACH ROW EXECUTE PROCEDURE zbx_part_trigger_func('day');
    CREATE TRIGGER zbx_partition_trg BEFORE INSERT ON history_text      FOR EACH ROW EXECUTE PROCEDURE zbx_part_trigger_func('day');
    CREATE TRIGGER zbx_partition_trg BEFORE INSERT ON history_log       FOR EACH ROW EXECUTE PROCEDURE zbx_part_trigger_func('day');
    CREATE TRIGGER zbx_partition_trg BEFORE INSERT ON trends            FOR EACH ROW EXECUTE PROCEDURE zbx_part_trigger_func('month');
    CREATE TRIGGER zbx_partition_trg BEFORE INSERT ON trends_uint       FOR EACH ROW EXECUTE PROCEDURE zbx_part_trigger_func('month');
EOF
  rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "=========================================="
    echo " Partition Triggers Successfully Created."
    echo "=========================================="
  fi
  return $rc
}


#########
# SETUP #
#########

abspath=`cd ${0%/*};pwd`     # get absolute path of script directory
logdir=${abspath}/logs       # set log directory under script directory
logfile=${logdir}/install_partitioning.$(date "+%Y-%m-%d_%H.%M").log

# create log subdirectory if does not exist
if [[ ! -d ${logdir} ]]; then
  mkdir -p ${logdir}
  if [[ $? -ne 0 ]]; then
    echo "ERROR: unable to create log directory \"${logdir}\"" >&2
    exit 2
  fi
fi

main 2>&1 | tee -a ${logfile}

