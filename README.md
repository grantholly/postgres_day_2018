DB administration
=================
SCRAM authentication (salted challenge response authentication method)
----------------------------------------------------------------------
  - channel binding (blocks MitM)
    - credentials on the channel cannot be forwarded and used elsewhere
  - built on TLS
    - TLS handshake is part of the hash
      - differing handshakes in the hash prevents man in the middle attacks
  - replaces MD5 passwords
  - introduced in 10

echo "host all all 0.0.0.0/0 scram-sha-256" >> /var/lib/postgresql/data/pg_hba.conf
SET password_encryption='scram-sha-256';
CREATE ROLE me WITH LOGIN;
ALTER ROLE me WITH PASSWORD 'good2go';
SELECT * from pg_authid where rolname = 'me';

WAL segment size configuration without re-compiling postgres
  - 16MB default
  - want to run a microscopic instance?  1MB WALs
  - want to run really large files?
pg_stat_* queryid is not 64-bit
  - less hash collisions
  - good for snapshotting the tables for later analysis
    - uses more space
    
SET STATISTICS now works on expression indices
----------------------------------------------
  - callout columns ordinally
  - increase the sample rate of the expression in the index

CREATE TABLE stats (id serial, name text);

CREATE INDEX ON stats ((lower(name)));

ALTER INDEX names_lower_idx ALTER COLUMN 1 SET STATISTICS 1000;
  
Developer SQL
=============
sha256 supported (384, 512 lengths as well)
  - now a SQL statement
ARRAY's over domains
  - couldn't make domains on composite data types like enums
WINDOW clauses SQL:2011 support
  - could only count rows before
  - RANGE BETWEEN now handles values
    - exclusion clauses
      - break ties
      - in the standard but not used outside of Postgres

      CREATE TABLE nums (i int);
      INSERT INTO nums VALUES ((1), (2), (3), (4));

      SELECT i,
      SUM(i) OVER (ORDER BY i ROWS
      	     	  BETWEEN 2 PRECEDING AND 2 FOLLOWING),
	SUM(i) OVER (ORDER BY i RANGE
	       	    BETWEEN 2 PRECEDING AND 2 FOLLOWING AND 2 EXCLUDE CURRENT ROW) FROM nums;

stored procedures
-----------------
  - functions that returned VOID (almost a proc)
  - uses CALL not SELECT
  - transaction control inside a proc
    - not supported in a function
      - had savepoints but not transaction control

      CREATE TABLE some_table (id int);

      CREATE PROCEDURE thing() LANGUAGE plpgsql AS $$
      BEGIN
	INSERT INTO some_table VALUES (1);
	COMMIT;
	INSERT INTO some_table VALUES (2);
	ROLLBACK;
      END; $$;

      CALL thing();
      SELECT * from some_table;

BACKUP and REPLICATION
======================
advace replciation slots (move replication slots)
  - mainly for management to keep track of where logical replicas are after failover events
    - keep your replication slots in-sync in a cluster
    - could be used by Petroni or repmanager
    SELECT * FROM pg_replication_slot_advance('slot_name', '0/67C032')
    - (second arg is transaction log position)
    - moves the transaction log forward
    - if a replication partner is dead , but you want it to catch up from the log archive
      on the master you can advance the replication slot to avoid accumulating unreplicated logs

PERFORMANCE
===========
9.6 added parallel execution (required large scans)
10 made it more usefule by working on more kinds of queries
parallel aware hash joins

partition level aggregations
----------------------------
- "enable_partitionwise_aggregate" setting allows for it
  - by default it is turned off

  SET enable_partitionwise_aggregate=true;

EXPLAIN SELECT logdate, count(*) FROM events GROUP BY logdate;
                                QUERY PLAN                                
--------------------------------------------------------------------------
 Append  (cost=1.00..3.08 rows=3 width=12)
   ->  HashAggregate  (cost=1.00..1.01 rows=1 width=12)
         Group Key: events_y2016.logdate
         ->  Seq Scan on events_y2016  (cost=0.00..1.00 rows=1 width=4)
   ->  HashAggregate  (cost=1.01..1.02 rows=1 width=12)
         Group Key: events_y2017.logdate
         ->  Seq Scan on events_y2017  (cost=0.00..1.01 rows=1 width=4)
   ->  HashAggregate  (cost=1.01..1.02 rows=1 width=12)
         Group Key: events_landing.logdate
         ->  Seq Scan on events_landing  (cost=0.00..1.01 rows=1 width=4)
(10 rows)

  - each partition does its own aggregations that get rolled up
  - the old plans looks like

  SET enable_partitionwise_aggregate=false;

EXPLAIN SELECT logdate, count(*) FROM events GROUP BY logdate;
                                QUERY PLAN                                
--------------------------------------------------------------------------
 HashAggregate  (cost=3.05..3.08 rows=3 width=12)
   Group Key: events_y2016.logdate
   ->  Append  (cost=0.00..3.03 rows=3 width=4)
         ->  Seq Scan on events_y2016  (cost=0.00..1.00 rows=1 width=4)
         ->  Seq Scan on events_y2017  (cost=0.00..1.01 rows=1 width=4)
         ->  Seq Scan on events_landing  (cost=0.00..1.01 rows=1 width=4)
(6 rows)

parallel CREATE INDEX
---------------------
  - helps with CPU bound work
    - not IO bound index creation
  - only works for B-tree indices
    - max_parallel_maintenance_workers=<number of cores to use>
CREATE TABLE things (stuff text);

INSERT INTO things VALUES ('yup'), ('ok'), ('sure');

CREATE UNIQUE INDEX CONCURRENTLY stuff_index ON things (stuff);

declarative partitioning
------------------------
  - default partitions
    - if a row comes into the partitioned table and it doesn't match any of the paritioning ranges,
      it will go into the deafult partition table
      - can work like a catch all
      - good for loading tables during ETL
  CREATE TABLE thing PARTITION OF other_thing DEFAULT;

  UPDATE can now move rows into other partitions
  - in the past if you updated the value of the parition key column on a row,
    Postgres would throw an error
    - required a delete and a separate insert to move the row into a different partition
    - can move rows into and and out of default paritions

CREATE TABLE events (
    logdate         date not null,
    cost            int,
    attendees       int
) PARTITION BY RANGE (logdate);

CREATE TABLE events_y2016 PARTITION OF events 
FOR VALUES FROM ('2016-01-01') TO ('2017-01-01');

CREATE TABLE events_y2017 PARTITION OF events
FOR VALUES FROM ('2017-01-01') TO ('2018-01-01');

INSERT INTO events (logdate, cost, attendees)
    VALUES ('2016-07-10', 66, 100); -- goes into events_y2016 table

UPDATE events SET logdate='2017-07-10';

CREATE TABLE events_landing PARTITION OF events DEFAULT;

INSERT INTO events (logdate, cost, attendees)
    VALUES ('2018-07-10', 66, 100); -- goes into events_landing

local partitioned indices
  - in the past with partitioned tables, you had to create the same
    indices on your paritions as well as your master table
    - could have cool different indices
  - indices on the master table get automatically created on the sub tables
    -----------------------------------------------------------------------
    CREATE INDEX cost_idx ON events (cost);

    \d+ events_landing
    \d+ events_y2016
    \d+ events_y2017    

    - includes newly created partitions
      - can still create aditional indices on sub tables
      
cross partition UNIQUE constraints
----------------------------------

  ALTER TABLE events ADD PRIMARY KEY (logdate);
  ALTER TABLE events ADD CONSTRAINT must_be_unique UNIQUE (logdate, attendees);

  \d+ events_landing
  \d+ events_y2016
  \d+ events_y2017    
  
  - if primary key and partition key overlap unique contraint can cascade down
  - must include all the partition  keys


hash partitioning
-----------------
  - doesn't work with constraint exclusion (resulting in scanning all partitions)
    - patch on the way right now!

CREATE TABLE hash_parts (words text) PARTITION BY HASH (words);
CREATE TABLE hash_parts_zero PARTITION OF hash_parts FOR VALUES WITH (MODULUS 2, REMAINDER 0);
CREATE TABLE hash_parts_one PARTITION OF hash_parts FOR VALUES WITH (MODULUS 2, REMAINDER 1);

INSERT INTO hash_parts SELECT sha256(stuff::text::bytea) FROM generate_series(0,10000) stuff;

partition-wise join
-------------------
  - optimizer can use the identical partition key to join 2 tables
    - parition key mustbe the exact same on both tables
      - default: off

  SET enable_partitionwise_aggregate=true;
  
