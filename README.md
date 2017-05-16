# zabbix-postgresql-auto-partitioning

Scripts to install, manage, and remove PostgreSQL partitioning for Zabbix DB

Adapted from https://www.zabbix.org/wiki/Docs/howto/zabbix2_postgresql_autopartitioning

The above wiki only had raw SQL scripts, I've wrapped them with bash so you can
fire and go. I also changed the names of the triggers and functions to make
them a bit more meaningful.

This implementation of partitioning is nice because it will automatically
create new partitions as it needs them, but it will **not** automatically drop
them. You need to be sure to run the script `daily_partition_cleanup.sh` on a
daily basis to purge expired partitions.

These functions are *only* meant to be used with a PostgreSQL Zabbix DB.

As with anything from the internet, thoroughly test it before using it in
production.

## The scripts

* **install\_partitioning.sh:** installs the partitioning objects
* **UNinstall\_partitioning.sh:** removes the partitioning (but leaves the data)
* **daily\_partition\_cleanup.sh:** manages the partition retention (when run daily from cron)

## Assumptions

### Default Settings

```
* Run the scripts as...........:  postgres
* Zabbix Database Name.........:  zabbix
* Zabbix Database Owner........:  zabbix
* "Daily" partition retention..:  31 days
* "Monthly" partition retention:  12 months
* Partitioning defaults........:
```

| Zabbix Table | Default Partitionng |
| --- | :---: |
| `history` | Daily | 
| `history_uint` | Daily | 
| `history_str` | Daily | 
| `history_text` | Daily | 
| `history_log` | Daily | 
| `trends` | Monthly | 
| `trends_uint` | Monthly | 

## Notes

### Logging

**`daily_partition_cleanup.sh`**

* Creates a "logs" sub-directory under the directory where it resides
* Keeps only 31 days of logs (by default; configurable in the script)
* If run interactively it will send output to both stdout and the logs
* If run non-interactively (like from cron) will only write to logs, unless an
  error occurs, then it will write an error message to stderr so an email
  can be sent from cron (don't forget to set `MAILTO` in the crontab)

---
## The Scripts

### install\_partitioning.sh

This will install the schema, functions, and triggers to automatically create
and manage partitions.

**This script performs the following actions:**
* creates `partitions` schema
* creates `zbx_part_trigger_func` trigger function
* creates `zbx_part_cleanup_func` cleanup function
* creates triggers on the Zabbix history and trend tables

Based on my testing, you can run this on a "live" Zabbix system as long as it
isn't extremely busy. It will need exclusive locks on the history and trend
tables for about one second to add the triggers.

---
### UNinstall\_partitioning.sh

This will *only* remove the triggers and drop the trigger function, disabling
the auto-partitioning.  The child partition tables and cleanup function are
left in place.

#### BE SURE you re-enable the Zabbix housekeeper settings for history and trends if they have been disabled.
After uninstalling the partitioning, be sure that the Zabbix "housekeeper" is
enabled so that it will purge old stats from the tables.

#### Manual Uninstallation Steps
This script will **NOT** drop the existing partitions or the cleanup function.
This allows Zabbix to continue to query the data in the partition tables, but
no new data will be written to the partitions and no new partitions will be
created. The cleanup function can still be executed to drop partitions as they
expire.

**After running this script you will need to choose one of these cleanup
options:**

1. :zap: Manually copy the partitioned table data back to the parent tables (small
   systems only with plenty of disk space)
2. :+1: Allow the `daily_partition_cleanup.sh` script to continue running daily to
   purge the partitions as they expire

**_If you choose option #1:_** You may use the generated SQL file
`copy_and_drop.sql` to perform the cleanup. :boom: **This method not
recommended if there is more than 1gb of data!** You will also need
**double the disk space** available in the database copy the data over.

**_If you choose option #2:_** *After all the partitions have expired* you can
come back and drop the `partitions` schema, drop the `zbx_part_cleanup_func`
function, and remove the `daily_partition_cleanup.sh` script from the crontab.

This script will also generate a SQL file called `copy_and_drop.sql` to allow
you to manually copy the data back to the parent tables, drop the partitions
schema, and drop the cleanup function (option 1).  It is up to you whether this
makes sense for your system.  This method is **NOT** advised for large amounts
of data (more than about 1gb).

---
### daily\_partition\_cleanup.sh

This script will drop partitions automatically as they expire, based on
expirations set in variables at the top of the script.  The script will also
automatically create a `logs` directory under the home directory of the script,
where logs from each script run will be saved. The script will automatically
manage the retention of the script logs.

It should be set up as a daily cron job run by the postgres user.

**DO NOT** schedule the cleanup to run at the same time as the DB backup job.

You can change the retentions for history and trends by editing the script and
changing the `detail_retention` and `trend_retention` values at the top of the
script. Remember that these variables need to be set to valid PostgreSQL
interval value syntax.

---
## Caveats

### Downtime

Based on my testing you should be able to run these scripts on a "live" Zabbix
system as long as it is not extremely busy. The scripts will need exclusive
locks on the history and trend tables for about one second to add or remove the
triggers or partitions.

### DB Backups

You should probably avoid having a DB backup running at, or just after,
midnight (based on the timezone of the DB server), since the backup could cause
lock contention as new partitions are created.

Also, you should not run the cleanup job at the same time as a DB backup since
the cleanup will be dropping partitions. It is recommended to run the cleanup
script just before the backup so you don't waste resources backing up obsolete
partitions.

### Crontab setup for PostgreSQL on a active/passive cluster

If you have PostgreSQL clustered under Pacemaker or some other
OS clustering tool then you need to make your crontab a little more intelligent
when running the daily cleanup script.
This is because you don't want the script to run on inactive nodes and then
email you with connection errors every day.

You need to set up crontab to only run the cleanup on the active node of the cluster.

This is easily done by checking if the PostgreSQL socket file exists. It will
only exist on the active node of the cluster (unless PG has crashed hard on
an inactive node).  This is easier to set up and more efficient than a `psql`
connection test.

* Redhat / Centos based distros:

  `59 23 * * *  test -S /tmp/.s.PGSQL.5432 && daily_partition_cleanup.sh`
  
* Debian / Ubuntu based distros:

  `59 23 * * *  test -S /var/run/postgresql/.s.PGSQL.5432 && daily_partition_cleanup.sh`
  

