-- SCRAM setup
-- you'll also need to setup pg_hba.conf
-- echo "host all all 0.0.0.0/0 scram-sha-256" >> /var/lib/postgresql/data/pg_hba.conf

SET password_encryption='scram-sha-256';

CREATER ROLE me WITH LOGIN;

ALTER ROLE me WITH PASSWORD 'good2go';

SELECT * from pg_authid where rolname = 'me';

-- Statistics for expression indices

CREATE TABLE stats (id serial, name text);

CREATE INDEX ON stats ((lower(name)));

ALTER INDEX names_lower_idx ALTER COLUMN 1 SET STATISTICS 1000;

-- stored procedures

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

-- declarative partitions

CREATE TABLE events (
    logdate         date not null,
    cost            int,
    attendees       int
) PARTITION BY RANGE (logdate);

CREATE TABLE events_y2016 PARTITION OF events 
FOR VALUES FROM ('2016-01-01') TO ('2017-01-01');

CREATE TABLE events_y2017 PARTITION OF events
FOR VALUES FROM ('2017-01-01') TO ('2018-01-01');

-- default partitions

CREATE TABLE events_landing PARTITION OF events DEFAULT;

-- update now moves rows between partitions

INSERT INTO events (logdate, cost, attendees)
    VALUES ('2016-07-10', 66, 100); -- goes into events_y2016 table

UPDATE events SET logdate='2017-07-10';

SELECT * FROM events_y2017;
SELECT * FROM events_y2016;

UPDATE events SET logdate='2018-07-10';

SELECT * FROM events_landing;

-- locally partitioned indices

CREATE INDEX cost_idx ON events (cost);

\d+ events_landing
\d+ events_y2016
\d+ events_y2017

-- cross partition UNIQUE constraints

ALTER TABLE events ADD PRIMARY KEY (logdate);
ALTER TABLE events ADD CONSTRAINT must_be_unique UNIQUE (logdate, attendees);

\d+ events_landing
\d+ events_y2016
\d+ events_y2017

-- hash partitioning

CREATE TABLE hash_parts (words text) PARTITION BY HASH (words);
CREATE TABLE hash_parts_zero PARTITION OF hash_parts FOR VALUES WITH (MODULUS 2, REMAINDER 0);
CREATE TABLE hash_parts_one PARTITION OF hash_parts FOR VALUES WITH (MODULUS 2, REMAINDER 1);

INSERT INTO hash_parts SELECT sha256(stuff::text::bytea) FROM generate_series(0,10000) stuff;

-- partitionwise aggregation

-- note: this is the default anyway
SET enable_partitionwise_aggregate=false;

EXPLAIN SELECT logdate, count(*) FROM events GROUP BY logdate;

/*
                                QUERY PLAN                                
--------------------------------------------------------------------------
 HashAggregate  (cost=3.05..3.08 rows=3 width=12)
   Group Key: events_y2016.logdate
   ->  Append  (cost=0.00..3.03 rows=3 width=4)
         ->  Seq Scan on events_y2016  (cost=0.00..1.00 rows=1 width=4)
         ->  Seq Scan on events_y2017  (cost=0.00..1.01 rows=1 width=4)
         ->  Seq Scan on events_landing  (cost=0.00..1.01 rows=1 width=4)
(6 rows)
*/

-- now enable it
SET enable_partitionwise_aggregate=true;

EXPLAIN SELECT logdate, count(*) FROM events GROUP BY logdate;

/*
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
*/

-- partitionwise join

SET enable_partitionwise_aggregate=true;
