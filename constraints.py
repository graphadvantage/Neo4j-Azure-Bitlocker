#pip install neo4j-driver

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
