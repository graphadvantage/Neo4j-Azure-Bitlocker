C:\neo4j/bin/neo4j-import ^
 --input-encoding UTF8 --ignore-empty-strings true --ignore-extra-columns true --skip-duplicate-nodes true --skip-bad-relationships true  ^
 --bad-tolerance 10000 --stacktrace true  ^
 --into F:/data/databases/graph.db  ^
 --nodes:Activity "G:/import/Activity_Header.csv, G:/import/Activity.csv.gz"  ^
 --nodes:Organization "G:/import/Organization_Header.csv, G:/import/Organization.csv.gz"  ^
 --nodes:Individual "G:/import/Individuals_Header.csv, G:/import/Individual.csv.gz"  ^
 --relationships:WORKS_FOR "G:/import/WORKS_FOR_Header.csv, G:/import/WORKS_FOR.csv.gz"  ^
 --relationships:TOUCHED "G:/import/TOUCHED_Header.csv, G:/import/TOUCHED.csv.gz"
