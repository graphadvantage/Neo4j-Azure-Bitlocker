

### Neo4j 3.1 Performance on Azure VM with Bitlocker Disk Encryption

# 2 Billion Relationships, 450M Nodes on an Azure VM

## Introduction

I recently completed an interesting POC of Neo4j 3.1 on Azure, and along the way I discovered that there's not much in the way of documentation out there.
This Gist provides some notes on how to deploy Neo4j on Azure in enterprise settings, examines the impact of Bitlocker disk encryption on Neo4j performance for command tasks.  
I hope you find it useful!

## TopLine

No significant impact was seen on Neo4j read/write performance on Azure VM due to Bitlocker disk encryption.

## Azure VM Configuration

Our goal was to optimize Neo4j as much as possible for read write tasks, and still operate within our POC budget. The machine we provisioned was an Azure D15v2 with 20 cores, 140GB RAM, and a Premium Storage account with 3 additional 1TB attached SSD drives.  Host caching was set to none.  Windows Server 2012 R2.

Note: This was actually the second time we provisioned this machine, the first time we started with Standard Storage HDD and upgraded the attached disks to SDD because we saw poor disk I/O - interestingly the upgrade didn't really work.  There was no improvement in I/O - still capping out at 20-30 MB/sec even with SSDs.  When we reprovisioned the machine with all disks (C: and attached drives F:,G:,H:) in Premium Storage from the start then we saw sustained disk I/O in the range of 175-230 MB/sec.

## Neo4j Configuration

We installed pre-release Neo4j 3.1 Enterprise M08 test latest improvements in the Neo4j Import Tool as well as the new role-based access control (RBAC) features.

To minimize disk contention, Neo4j was installed on C:, /data on  F:, /import on G:, /logs on H:.  For this machine, I set both the min and max Java heap to 32750 MB (to reduce garbage collection), and set the page cache to 98250 MB, which left 9 GB for OS and apps.


```
# Paths of directories in the installation.
dbms.directories.data=F:/data
#dbms.directories.plugins=plugins
#dbms.directories.certificates=certificates
dbms.directories.logs=H:/logs
dbms.directories.import=G:/import

...

# Java Heap Size: by default the Java heap size is dynamically
# calculated based on available system resources.
# Uncomment these lines to set specific initial and maximum
# heap size in MB.

dbms.memory.heap.initial_size=32750

dbms.memory.heap.max_size=32750

# The amount of memory to use for mapping the store files, in bytes (or
# kilobytes with the 'k' suffix, megabytes with 'm' and gigabytes with 'g').
# If Neo4j is running on a dedicated server, then it is generally recommended
# to leave about 2-4 gigabytes for the operating system, give the JVM enough
# heap to hold all your transaction state and query context, and then leave the
# rest for the page cache.
# The default page cache memory assumes the machine is dedicated to running
# Neo4j, and is heuristically set to 50% of RAM minus the max Java heap size.

dbms.memory.pagecache.size=98250m

```

## Other

Anaconda3 Python for scripting using new Bolt driver and the Azure storage module

```
pip install neo4j-driver

pip install azure-storage

```


## The Data

One of the objectives of this POC was to see if we could even fit the test graph on a single Azure attached drive - a limitation of Azure is that the attached drives come in only 1TB sizes, and Neo4j doesn't shard.

The test graph describes B2B marketing activities targeted to people who work for a company.  

```
(:Activity)-[:TOUCHED]->(:Individual)-[:WORKS_FOR]->(:Organization)
```

However, there were a lot of records - 458 million nodes, and 2.17 Billion relationships

Nodes:
* Individuals: 196 M records (67.9 GB, 16 GB compressed)
* Organizations: 261 M records (40.4 GB, 10.5 GB compressed)
* Activity: 254 records - (14.8KB, 3.3KB compressed)

Relationships:
* TOUCHED: 1.87 B records (73.5 GB, 9.6 GB compressed)
* WORKS_FOR: 306 M records (5.8 GB, 2.1GB compressed)

The (:Activity) nodes are dense nodes, with an average of 7.3M [:TOUCHED] relationships per node.

Gunzip compressed CSV files extracted to Azure Blob Storage and then copied to the G:\import using a python script:

```
pip install azure-storage

from azure.storage.blob import BlockBlobService

block_blob_service = BlockBlobService(account_name='ACCOUNT_NAME', account_key='******************')

# list blob directory contents
generator = block_blob_service.list_blobs('BLOB_NAME')
for blob in generator:
    print(blob.name)

# copy files from blob to G:\import
block_blob_service.get_blob_to_path('BLOB_NAME', 'BLOB_DIRECTORY/Activity.csv.gz', 'G:/import/Activity.csv.gz')

block_blob_service.get_blob_to_path('BLOB_NAME', 'BLOB_DIRECTORY/Individual.csv.gz', 'G:/import/Individual.csv.gz')

block_blob_service.get_blob_to_path('BLOB_NAME', 'BLOB_DIRECTORY/Organization.csv.gz', 'G:/import/Organization.csv.gz')

block_blob_service.get_blob_to_path('BLOB_NAME', 'BLOB_DIRECTORY/TOUCHED.csv.gz', 'G:/import/TOUCHED.csv.gz')

block_blob_service.get_blob_to_path('BLOB_NAME', 'BLOB_DIRECTORY/WORKS_FOR.csv.gz', 'G:/import/WORKS_FOR.csv.gz')

```

## The Tests

Neo4j does not provide database encryption, however Azure VMs offer disk encryption using Bitlocker, which can be managed using a centralized Azure key vault.  

I devised three real-world performance tests representing common Neo4j tasks, which were run before & after applying Bitlocker to the Azure VM.

### Test 1: Neo4j Import Tool

This a test of pure read/write speed, we .gz compressed CSV files to get maximum import speed.  

Header files are handy because they allow you to rename properties and cast data types.  

Each data file had a integer primary key that was unique within the scope of the label, and so the header file was configured as:

```
ActivityKey:Integer:ID(Activity), activityName, etc, etc
```

Neo4j Import-Tool was invoked from Powershell using a Windows .cmd script:


```
C:\neo4j/bin/neo4j-import ^
 --input-encoding UTF8 --ignore-empty-strings true --ignore-extra-columns true --skip-duplicate-nodes true --skip-bad-relationships true  ^
 --bad-tolerance 10000 --stacktrace true  ^
 --into F:/data/databases/graph.db  ^
 --nodes:Activity "G:/import/Activity_Header.csv, G:/import/Activity.csv.gz"  ^
 --nodes:Organization "G:/import/Organization_Header.csv, G:/import/Organization.csv.gz"  ^
 --nodes:Individual "G:/import/Individuals_Header.csv, G:/import/Individual.csv.gz"  ^
 --relationships:WORKS_FOR "G:/import/WORKS_FOR_Header.csv, G:/import/WORKS_FOR.csv.gz"  ^
 --relationships:TOUCHED "G:/import/TOUCHED_Header.csv, G:/import/TOUCHED.csv.gz"

```

### Test 2: Setting Constraints and Property Indexes

This test involves reading all nodes for a label and then writing indexes.

This was a Bolt Python script that set constraints on each Label key, and a couple of other property indexes:

```
pip install neo4j-driver

import time

from neo4j.v1 import GraphDatabase, basic_auth, TRUST_ON_FIRST_USE, CypherError

driver = GraphDatabase.driver("bolt://localhost",
                              auth=basic_auth("NEO4J_USERNAME", "NEO4J_PASSWORD"),
                              encrypted=False,
                              trust=TRUST_ON_FIRST_USE)

session = driver.session()

query1 = '''
CREATE CONSTRAINT ON (n:Activity) ASSERT n.ActivityKey IS UNIQUE;
'''

session = driver.session()
t0 = time.time()
result = session.run(query1)
summary = result.consume()
counters = summary.counters
print(summary)
print(counters)
print(round((time.time() - t0)*1000,1), " ms elapsed time")
session.close()

# next constraint ...

```

### Test 3: Graph Warmup

This test reads as much data from disk as will fit into Neo4j's page cache memory.

For this test I used the Warmup procedure from the APOC procedures plugin.

```
pip install neo4j-driver

import time

from neo4j.v1 import GraphDatabase, basic_auth, TRUST_ON_FIRST_USE, CypherError

driver = GraphDatabase.driver("bolt://localhost",
                              auth=basic_auth("NEO4J_USERNAME", "NEO4J_PASSWORD"),
                              encrypted=False,
                              trust=TRUST_ON_FIRST_USE)

session = driver.session()

query2 = '''
CALL apoc.warmup.run();
'''
t0 = time.time()

result = session.run(query2)
for record in result:
    print("%s" % (record))

print(round((time.time() - t0)*1000,1), " ms elapsed time")
session.close()

```


## The Results

**Test 1: Neo4j Import Tool**

The import completed in about an 1.5 hours, a very impressive result. During the import disk I/O was sustained at 175-230 MB/sec.

Interestingly, Neo4j Import actually ran 4 minutes faster with Bitlocker applied.

The total database size was 315GB, which fits easily on the 1TB Azure attached drives.

![neo4j-import-bitlocker-total](https://cloud.githubusercontent.com/assets/5991751/18564520/b888735c-7b40-11e6-8927-fa894b8ea487.png)


![neo4j-import-tool-bitlocker](https://cloud.githubusercontent.com/assets/5991751/18562390/568c451e-7b38-11e6-8a71-4a325edfdfff.png)


Full results below:

Initialization (Same for both tests)

```
PS G:\import> .\ImportCommandPPEGMEDFull

G:\import>C:\neo4j/bin/neo4j-import  --input-encoding UTF8 --ignore-empty-strings true --ignore-extra-columns true --ski
p-duplicate-nodes true --skip-bad-relationships true   --bad-tolerance 10000 --stacktrace true
--into F:/data/databases/graph.db
--nodes:Activity "G:/import/Activity_Header.csv, G:/import/Activity.csv.gz"
--nodes:Organization "G:/import/Organization_Header.csv, G:/import/Organization.csv.gz"
--nodes:Individual "G:/import/Individuals_Header.csv, G:/import/Individual.csv.gz"
--relationships:WORKS_FOR "G:/import/WORKS_FOR_Header.csv, G:/import/WORKS_FOR.csv.gz"
--relationships:TOUCHED "G:/import/TOUCHED_Header.csv, G:/import/TOUCHED.csv.gz"

Neo4j version: 3.1.0-M08
Importing the contents of these files into F:\data\databases\mpaa-graph-bulk-450M.db:
Nodes:
  :Activity
  G:\import\Activity_Header.csv
  G:\import\Activitiy.csv.gz

  :Organization
  G:\import\Organization_Header.csv
  G:\import\Organization.csv.gz

  :Individual
  G:\import\Individual_Header.csv
  G:\import\Individual.csv.gz
Relationships:
  :WORKS_FOR
  G:\import\WORKS_FOR_Header.csv
  G:\import\WORKS_FOR.csv.gz

  :TOUCHED
  G:\import\TOUCHED_Header.csv
  G:\import\TOUCHED.csv.gz

Available resources:
  Free machine memory: 135.70 GB
  Max heap memory : 26.67 GB
  Processors: 20
```


No Bitlocker

```
Nodes
[PROPERTIES(2)===========|NODE:3.4|LABE|*v:105.15 MB/s----------------------------------------] 458M
Done in 28m 3s 696ms
Prepare node index
[*DETECT:9.40 GB------------------------------------------------------------------------------] 454M
Done in 3m 8s 547ms
Calculate dense nodes
[>:119.80 |TYPE-------|*PREPARE(20)======================================|CALCULATE(2)========]2.17B
Done in 11m 18s 65ms
Relationships [:TOUCHED] (1/2)
[>|PREPARE(18)============|RECORD|PROPERTIES(|RELATIO|*v:75.91 MB/s---------------------------]1.86B
Done in 29m 21s 436ms
Node --> Relationship [:TOUCHED] (1/2)
[*>----------------------------------------------------------------------------------|LI|v:945]1.67M
Done in 28s 83ms
Relationship --> Relationship [:TOUCHED] (1/2)
[*>:151.45 MB/s--------------------------------------|LINK(2)=====|v:151.44 MB/s--------------]1.86B
Done in 6m 40s 844ms
Relationships [:WORKS_FOR] (2/2)
[>:|*PREPARE(20)=====================|RECORD|PR|RELATIONSHIP---------------------|v:47.23 MB/s] 304M
Done in 3m 31s 569ms
Node --> Relationship [:WORKS_FOR] (2/2)
[*>-----------------------------------------------------------------------|LI|v:614.40 kB/s---] 838K
Done in 21s 177ms
Relationship --> Relationship [:WORKS_FOR] (2/2)
[*>:167.05 MB/s-------------------------------|LINK(3)===================|v:86.60 MB/s--------] 298M
Done in 1m 100ms
Node --> Relationship Sparse
[*>--------------------------------------------------------------------|LI|v:101.28 MB/s------] 353M
Done in 52s 418ms
Relationship --> Relationship Sparse
[>:277.78 MB/s----------------------------|LINK(3)==|*v:259.11 MB/s---------------------------]2.17B
Done in 4m 14s 273ms
Count groups
[*>:??----------------------------------------------------------------------------------------]    0
Done in 359ms
Gather
[*>:??----------------------------------------------------------------------------------------]    0
Done in 563ms
Write

Done in 1s
Node --> Group
[>:2|FIRST--------------------|*v:4.00 MB/s---------------------------------------------------]1.11M
Done in 4s 875ms
Node counts
[>:183.29 MB/s---------------------------------|*COUNT:3.28 GB--------------------------------] 435M
Done in 35s 955ms
Relationship counts
[*>:405.51 MB/s-----------------------------------|COUNT(6)===================================]2.17B
Done in 2m 54s 263ms

IMPORT DONE in 1h 33m 5s 343ms.
Imported:
  458356377 nodes
  2176603843 relationships
  9064981812 properties
Peak memory usage: 9.46 GB
PS G:\import>

```

Bitlocker Applied

```
Nodes
[PROPERTIES(4)===|NODE:3.41 GB|LABEL S|*v:108.20 MB/s-----------------------------------------] 457M
Done in 27m 15s 757ms
Prepare node index
[*DETECT:9.40 GB------------------------------------------------------------------------------] 458M
Done in 3m 13s 206ms
Calculate dense nodes
[>:120.56 MB/s|TYPE----------|*PREPARE(20)=========================================|CALCULATE-]2.17B
Done in 11m 13s 844ms
Relationships [:TOUCHED] (1/2)
[>|PREPARE(18)================|RECOR|PROPERT|RELA|*v:78.66 MB/s-------------------------------]1.86B
Done in 28m 19s 921ms
Node --> Relationship [:TOUCHED] (1/2)
[*>-----------------------------------------------------------------------------------|LI|v:87]1.67M
Done in 29s 971ms
Relationship --> Relationship [:TOUCHED] (1/2)
[*>:217.77 MB/s------------------------------------------------|LINK(2)==|v:217.75 MB/s-------]1.86B
Done in 4m 39s 444ms
Relationships [:WORKS_FOR] (2/2)
[*PREPARE(20)================================|RECORDS|PRO|RELATIONSHIP(2)======|v:44.34 MB/s--] 304M
Done in 3m 44s 549ms
Node --> Relationship [:WORKS_FOR] (2/2)
[*>-----------------------------------------------------------------------------|L|v:877.71 kB]1.67M
Done in 28s 108ms
Relationship --> Relationship [:WORKS_FOR] (2/2)
[*>:167.80 MB/s--------------------------------|LINK(3)====================|v:87.43 MB/s------] 294M
Done in 59s 831ms
Node --> Relationship Sparse
[*>------------------------------------------------------|LINK|v:100.56 MB/s------------------] 351M
Done in 50s 924ms
Relationship --> Relationship Sparse
[*>:295.78 MB/s--------------------------------|LINK(3)====|v:276.18 MB/s---------------------]2.16B
Done in 3m 58s 446ms
Count groups
[*>:??----------------------------------------------------------------------------------------]    0
Done in 437ms
Gather
[*>:??----------------------------------------------------------------------------------------]    0
Done in 547ms
Write

Done in 781ms
Node --> Group
[>:2|FIRST------------------------|*v:5.00 MB/s-----------------------------------------------]1.39M
Done in 5s 78ms
Node counts
[>:178.83 MB/s--------------------------------|*COUNT:3.35 GB---------------------------------] 450M
Done in 36s 752ms
Relationship counts
[*>:409.98 MB/s---------------------------------------------|COUNT(6)=========================]2.16B
Done in 2m 52s 476ms

IMPORT DONE in 1h 29m 16s 530ms.
Imported:
  458356377 nodes
  2176603843 relationships
  9064981812 properties
Peak memory usage: 9.46 GB
PS G:\import>
```

**Test 2: Constraints and Property indexes**

Four constraints and two property indexes were applied, which completed in 100-113 minutes.

Constraint and Indexing time was 13 minutes faster with Bitlocker.

![neo4j-indexing-bitlocker](https://cloud.githubusercontent.com/assets/5991751/18564506/99d172b0-7b40-11e6-990b-d8a86f66d939.png)


Results:

No Bitlocker

```
processing...
<neo4j.v1.session.ResultSummary object at 0x000000350B2E6048>
{'constraints_added': 1}
126881.5  ms elapsed time
-----------------
processing...
<neo4j.v1.session.ResultSummary object at 0x000000350B2E60B8>
{'constraints_added': 1}
3747893.2  ms elapsed time
-----------------
processing...
<neo4j.v1.session.ResultSummary object at 0x000000350B3D3B00>
{'constraints_added': 1}
2795132.0  ms elapsed time
-----------------
processing...
<neo4j.v1.session.ResultSummary object at 0x000000350B31FF60>
{'constraints_added': 1}
117785.5  ms elapsed time
-----------------
processing...
<neo4j.v1.session.ResultSummary object at 0x000000350B2F9160>
{'indexes_added': 1}
15.7  ms elapsed time
-----------------
processing...
<neo4j.v1.session.ResultSummary object at 0x000000350B2F9240>
{'indexes_added': 1}
0.0  ms elapsed time
-----------------
```

Bitlocker applied

```
Test #2 Constraints & Indexing
processing...
<neo4j.v1.session.ResultSummary object at 0x0000002A857D1198>
{'constraints_added': 1}
115009.8  ms elapsed time
-----------------
processing...
<neo4j.v1.session.ResultSummary object at 0x0000002A857D1208>
{'constraints_added': 1}
3145294.5  ms elapsed time
-----------------
processing...
<neo4j.v1.session.ResultSummary object at 0x0000002A8580A160>
{'constraints_added': 1}
2623787.3  ms elapsed time
-----------------
processing...
<neo4j.v1.session.ResultSummary object at 0x0000002A8580A438>
{'constraints_added': 1}
115801.3  ms elapsed time
-----------------
processing...
<neo4j.v1.session.ResultSummary object at 0x0000002A8572A2E8>
{'indexes_added': 1}
22.0  ms elapsed time
-----------------
processing...
<neo4j.v1.session.ResultSummary object at 0x0000002A8572A1D0>
{'indexes_added': 1}
13.0  ms elapsed time
-----------------
```

**Test 3: Graph Warmup***

Warmup completed in about 40 minutes.

For this VM apoc.warmup.run() was able to load 117GB of data into page cache, achieving 82% memory utilization with 839K nodes and 914K relationships.

Without Bitlocker disk I/O was in the range of 28-32MB/sec during warmup, and with Bitlocker I/O in the range of 39-42MB/sec.

Warmup was 9 minutes faster with Bitlocker

![neo4j-warmup-bitlocker](https://cloud.githubusercontent.com/assets/5991751/18564424/445f9aa0-7b40-11e6-9001-50b11393d455.png)


Warmup result

```
pageSize=8192 nodesPerPage=546 nodesTotal=458356617 nodesLoaded=839481 nodesTime=4 relsPerPage=240 relsTotal=2194184487 relsLoaded=914243
```

No Bitlocker

```
2613720.9 ms elapsed time
```

Bitlocker Applied

```
2073610.1 ms elapsed time
```


##Neo4j on Azure with Bitlocker

From these tests it's clear that Bitlocker isn't making Neo4j run slower, which was my expectation.  
On real hardware, Bitlocker is expected to add "a single digit performace impact" according to MSFT docs, however these tests don't reveal that.
It could be that the performance impacts of Azure virtualization greatly exceed, and are more variable, than whatever the Bitlocker overhead is.
A better approach would be to run several batteries of tests, perhaps at different times of day or after a specified amount of VM uptime, unfortunately I didn't have that opportunity. However, the good news that Bitlocker is certainly not killing Neo4j performance and can be recommended for encrypting data at rest in Azure environments.

Other notes - we got great data compression with Neo4j's inherent sparcity, coming in at 315GB.

Using SSDs with Premium storage is the key to good throughput, and it appears to work better if the VM is initially provisioned with all drives in Premium storage.

Using headers and compressed CSV files greatly speeds up import times for the Neo4j Import Tool.  
For comparison, this same load using uncompressed files took 8.5 hours.

## Thanks

Special thanks to Michael Kilgore for helping out with this work.
