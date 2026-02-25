# Redis — Complete Reference Documentation
> Architecture · Data Types · Use Cases · Operations · Best Practices

---

## Table of Contents
1. [What is Redis?](#1-what-is-redis)
2. [Why Do We Need Redis?](#2-why-do-we-need-redis)
3. [How Redis Operates](#3-how-redis-operates)
4. [Redis Data Types](#4-redis-data-types)
5. [Redis Deployment Types](#5-redis-deployment-types)
6. [Real-World Use Cases](#6-real-world-use-cases)
7. [Operations & Monitoring](#7-operations--monitoring)
8. [Best Practices](#8-best-practices)
9. [Redis vs Alternatives](#9-redis-vs-alternatives)

---

## 1. What is Redis?

Redis (**Re**mote **Di**ctionary **S**erver) is an open-source, in-memory data structure store. Unlike traditional databases that store data on disk, Redis keeps all data in RAM — making it extraordinarily fast, capable of handling millions of operations per second with sub-millisecond latency.

Redis was created by Salvatore Sanfilippo in 2009 and is now maintained by Redis Ltd. It is one of the most popular databases in the world, used by Twitter, GitHub, Snapchat, Craigslist, and Stack Overflow.

| Property | Value |
|----------|-------|
| Created | 2009 by Salvatore Sanfilippo |
| Language | C |
| License | BSD (open source) |
| Storage | In-memory (RAM) with optional persistence |
| Latency | Sub-millisecond (<1ms) |
| Throughput | Millions of ops/sec on a single node |
| Data Model | Key-Value (with rich value types) |

---

## 2. Why Do We Need Redis?

Traditional databases (PostgreSQL, MySQL) are disk-based. Every query involves I/O — reading from disk, which is **100,000x slower** than reading from RAM. Redis solves this performance bottleneck by sitting between your application and the database.

> **Analogy:** Your database is a library warehouse in another city. Redis is a shelf of frequently-read books right next to your desk. You get those books instantly.

### Common Pain Points Redis Solves

- Slow database queries repeated thousands of times per second
- Need for real-time features like live counters, leaderboards, notifications
- Background job queues for async processing
- Session storage across multiple application servers
- Rate limiting API endpoints
- Pub/Sub messaging between microservices

---

## 3. How Redis Operates

### 3.1 Single-Threaded Event Loop

Redis processes commands using a **single-threaded event loop**. This eliminates the overhead of context switching and locking that multi-threaded systems suffer from. All commands are **atomic** — no two commands can interfere with each other.

> **Note:** Redis 6.0+ introduced multi-threading for I/O operations, but command processing itself remains single-threaded.

### 3.2 Memory Storage Model

All data lives in RAM. When you `SET` a key, it goes directly into memory. When you `GET` a key, it is read from memory. No disk access is involved in the hot path.

| Operation | Redis (RAM) | PostgreSQL (Disk) | Why the difference |
|-----------|-------------|-------------------|--------------------|
| Simple GET | ~0.1ms | ~1-10ms | RAM vs disk access |
| 1M ops/sec | Achievable on 1 node | Requires heavy sharding | No I/O bottleneck |
| Atomic counter | Native `INCR` command | Transaction + lock | Built-in primitives |

### 3.3 Persistence Options

Although Redis is in-memory, it supports optional persistence to survive restarts:

| Mode | How it works | Data Loss Risk | Best For |
|------|-------------|----------------|----------|
| No persistence | Pure in-memory, lost on restart | 100% on restart | Pure cache |
| RDB (Snapshot) | Periodic full snapshot to disk | Minutes of data | Backups, less critical data |
| AOF (Append Only File) | Logs every write command | Seconds or none | Critical data |
| RDB + AOF | Both combined | Minimal | **Production recommended** |

### 3.4 Expiry & Eviction

Every key in Redis can have a **TTL (Time To Live)**. After the TTL expires, Redis automatically deletes the key.

```bash
SET session:user123 '{...}' EX 3600   # expires in 1 hour
```

- Redis uses **lazy expiry** (delete on access) + **active expiry** (periodic cleanup)
- When memory is full, **eviction policies** decide what to remove (LRU, LFU, etc.)
- Recommended policy for caching: `allkeys-lru`

---

## 4. Redis Data Types

Redis is not just a simple key-value store. It supports **8 rich data structures** natively, each with purpose-built commands optimized for specific use cases.

---

### 4.1 String

The simplest type. A key maps to a single value — text, number, or binary data (up to 512MB).

| Command | Description | Example |
|---------|-------------|---------|
| `SET key value` | Store a value | `SET name 'vishav'` |
| `GET key` | Retrieve a value | `GET name` |
| `INCR key` | Atomic increment | `INCR page_views` |
| `EXPIRE key secs` | Set TTL | `EXPIRE session:1 3600` |
| `SETNX key value` | Set if not exists | `SETNX lock:job 1` |

**Use cases:** Caching, counters, rate limiting, distributed locks, session tokens

---

### 4.2 Hash

A map of field-value pairs stored under a single key. Perfect for representing objects.

| Command | Description | Example |
|---------|-------------|---------|
| `HSET key field value` | Set a field | `HSET user:1 name 'vishav'` |
| `HGET key field` | Get a field | `HGET user:1 name` |
| `HGETALL key` | Get all fields | `HGETALL user:1` |
| `HDEL key field` | Delete a field | `HDEL user:1 age` |
| `HINCRBY key field n` | Increment field | `HINCRBY user:1 score 10` |

**Use cases:** User profiles, product details, configuration objects, session data

---

### 4.3 List

An ordered sequence of strings. Can be used as a **stack (LIFO)** or **queue (FIFO)**. Elements can be added/removed from both ends efficiently.

| Command | Description | Example |
|---------|-------------|---------|
| `LPUSH key val` | Push to left (head) | `LPUSH jobs 'send_email'` |
| `RPUSH key val` | Push to right (tail) | `RPUSH jobs 'send_email'` |
| `LPOP key` | Pop from left | `LPOP jobs` |
| `RPOP key` | Pop from right | `RPOP jobs` |
| `LRANGE key s e` | Get range | `LRANGE jobs 0 -1` |
| `BRPOP key timeout` | Blocking pop (waits for data) | `BRPOP jobs 0` |

**Use cases:** Task queues (Celery), activity feeds, message logs, undo history

---

### 4.4 Set

An **unordered collection of unique strings**. Supports powerful set operations like union, intersection, and difference.

| Command | Description | Example |
|---------|-------------|---------|
| `SADD key member` | Add to set | `SADD online_users 'user1'` |
| `SREM key member` | Remove from set | `SREM online_users 'user1'` |
| `SMEMBERS key` | Get all members | `SMEMBERS online_users` |
| `SISMEMBER key m` | Check membership | `SISMEMBER online_users 'user1'` |
| `SINTER key1 key2` | Intersection | `SINTER followers:1 followers:2` |
| `SUNION key1 key2` | Union | `SUNION tags:post1 tags:post2` |

**Use cases:** Unique visitors, tags, friend lists, mutual followers

---

### 4.5 Sorted Set (ZSet)

Like a Set, but every member has a **score**. Members are automatically ordered by score — perfect for leaderboards and priority queues.

| Command | Description | Example |
|---------|-------------|---------|
| `ZADD key score member` | Add with score | `ZADD leaderboard 1500 'vishav'` |
| `ZRANK key member` | Get rank (0-indexed) | `ZRANK leaderboard 'vishav'` |
| `ZRANGE key s e` | Get range by rank | `ZRANGE leaderboard 0 9` |
| `ZREVRANGE key s e` | Get range descending | `ZREVRANGE leaderboard 0 9` |
| `ZSCORE key member` | Get member score | `ZSCORE leaderboard 'vishav'` |
| `ZINCRBY key n member` | Increment score | `ZINCRBY leaderboard 100 'vishav'` |

**Use cases:** Leaderboards, priority queues, rate limiting by time window, trending content

---

### 4.6 Bitmap

Not a separate data type — operations on Strings treating the value as a sequence of bits. Extremely **space-efficient** for tracking boolean states at scale.

```bash
SETBIT user_active:20240101 1001 1     # mark user 1001 as active
GETBIT user_active:20240101 1001       # check if user was active
BITCOUNT user_active:20240101          # count all active users that day
```

**Use cases:** Daily active users, feature flags, attendance tracking

---

### 4.7 HyperLogLog

A **probabilistic data structure** for counting unique elements with very low memory usage (~12KB regardless of cardinality). Has ~0.81% error rate.

```bash
PFADD visitors 'user1' 'user2' 'user3'   # add elements
PFCOUNT visitors                          # estimate unique count
```

**Use cases:** Unique page views, unique search queries, approximate analytics

---

### 4.8 Stream

A **log-like data structure** for event streaming. Similar to Kafka topics but built into Redis. Supports consumer groups for distributed processing.

```bash
XADD events '*' action 'purchase' user 'user1'   # append event
XREAD COUNT 10 STREAMS events 0                   # read events
```

**Use cases:** Event sourcing, audit logs, real-time analytics pipelines

---

### Data Types Summary

| Data Type | Best Use Case | Key Commands |
|-----------|---------------|--------------|
| String | Cache, counters, locks | `SET`, `GET`, `INCR`, `EXPIRE` |
| Hash | Object storage (user profiles) | `HSET`, `HGET`, `HGETALL` |
| List | Queues, activity feeds | `LPUSH`, `RPOP`, `BRPOP` |
| Set | Unique items, tags, relations | `SADD`, `SMEMBERS`, `SINTER` |
| Sorted Set | Leaderboards, rankings | `ZADD`, `ZRANGE`, `ZRANK` |
| Bitmap | User tracking at scale | `SETBIT`, `BITCOUNT` |
| HyperLogLog | Approximate unique counts | `PFADD`, `PFCOUNT` |
| Stream | Event log, message bus | `XADD`, `XREAD` |

---

## 5. Redis Deployment Types

### 5.1 Standalone (Single Node)

A single Redis instance. Simple to operate. No redundancy.

- **Pros:** Simple, zero overhead, maximum performance
- **Cons:** Single point of failure, limited by single machine memory
- **Use when:** Development, low-stakes caching, budget environments

---

### 5.2 Master-Replica ✅ (Your eks-zorcs-prod setup)

One master handles all **writes**. One or more replicas sync from master and handle **reads**.

```
Your setup:
  redis-prod-master-0    → handles writes
  redis-prod-replicas-0  → handles reads, synced from master
```

- **Pros:** Read scalability, data redundancy, replica can be promoted if master fails
- **Cons:** Writes still go to single master, manual failover without Sentinel
- **Replication is asynchronous** — small risk of data loss if master crashes before sync

---

### 5.3 Redis Sentinel

Adds **automatic high availability** on top of Master-Replica. Sentinel processes monitor the master and automatically promote a replica if the master fails.

- Sentinel monitors master health with heartbeats
- If master is unreachable, Sentinels **vote** to elect a new master
- Clients connect to Sentinel to discover current master address
- Requires minimum **3 Sentinel nodes** to avoid split-brain
- **Use when:** You need automatic failover without Cluster overhead

---

### 5.4 Redis Cluster

**Horizontal sharding** across multiple master nodes. Data is partitioned using **16384 hash slots** distributed across masters. Each master can have replicas.

| Feature | Standalone | Master-Replica | Sentinel | Cluster |
|---------|-----------|----------------|----------|---------|
| High Availability | No | Manual failover | Automatic | Automatic |
| Horizontal Scale | No | Reads only | Reads only | Reads + Writes |
| Data Sharding | No | No | No | Yes (16384 slots) |
| Complexity | Low | Low | Medium | High |
| Min Nodes | 1 | 2 | 5 (3 Sentinel) | 6 (3M + 3R) |

---

### 5.5 Bitnami Redis (Helm Chart)

Bitnami packages Redis as a **Helm chart for Kubernetes** with pre-configured best practices.

- Default deployment is **Master-Replica**
- Includes **Prometheus metrics exporter** out of the box
- Handles `PersistentVolumeClaims` for data persistence automatically
- ConfigMaps and Secrets managed natively

```bash
# Install
helm install redis bitnami/redis -n prod

# Check values
helm show values bitnami/redis
```

---

## 6. Real-World Use Cases

### 6.1 Caching (Most Common)

Cache expensive DB query results. On cache hit, return from Redis instantly. On miss, query DB and store in Redis with TTL.

> **Cache-Aside Pattern:** App checks Redis first → Miss → Query DB → Store in Redis with TTL → Return result

```python
def get_user(user_id):
    cached = redis.get(f"user:{user_id}")
    if cached:
        return json.loads(cached)          # cache hit
    user = db.query(User).get(user_id)    # cache miss
    redis.setex(f"user:{user_id}", 3600, json.dumps(user))
    return user
```

---

### 6.2 Celery Task Queue (Your Django/FastAPI apps)

Your `django-platform` and FastAPI services use Redis as a Celery broker. Tasks are pushed as List entries and workers pop and execute them asynchronously.

```
Producer (Django view) → LPUSH celery queue → Redis List
Worker (Celery)        → BRPOP celery 0     → executes task
```

> Your `django-cron-*` pods are Celery periodic tasks scheduled via Redis Beat.

---

### 6.3 Session Storage

Store user session data in Redis instead of the database. Sessions expire automatically via TTL. Works across multiple app server instances seamlessly.

```bash
SET session:abc123 '{"user_id": 1, "role": "admin"}' EX 86400
```

---

### 6.4 Rate Limiting

Use `INCR` + `EXPIRE` to count requests per user per time window. Atomic `INCR` ensures accuracy under high concurrency.

```python
key = f"rate:{user_id}:minute"
count = redis.incr(key)
if count == 1:
    redis.expire(key, 60)    # start the 1-minute window
if count > 100:
    raise RateLimitExceeded()
```

---

### 6.5 Pub/Sub Messaging

Publishers send messages to channels. All subscribers receive messages instantly. Unlike Lists, messages are **not persisted**.

```bash
PUBLISH  notifications 'order_placed:order123'    # publisher
SUBSCRIBE notifications                            # subscriber
```

**Use when:** Real-time notifications, live updates, broadcasting events across microservices

---

### 6.6 Distributed Lock

Use `SETNX` (Set if Not Exists) with an expiry to prevent race conditions across multiple app servers.

```bash
SETNX  lock:payment:order123 1    # acquire lock (fails if already locked)
EXPIRE lock:payment:order123 30   # auto-release after 30s
```

Only one server gets the lock. Others retry or fail fast — preventing double payments, duplicate jobs, etc.

---

## 7. Operations & Monitoring

### 7.1 Useful CLI Commands

| Command | Purpose |
|---------|---------|
| `redis-cli -h host -p 6379` | Connect to Redis |
| `AUTH password` | Authenticate |
| `INFO` | Full server stats (memory, clients, replication) |
| `INFO replication` | Master/replica sync status |
| `MONITOR` | Real-time command stream (**use carefully in prod**) |
| `DBSIZE` | Number of keys in current DB |
| `CONFIG GET maxmemory` | Check memory limit |
| `SLOWLOG GET 10` | Last 10 slow commands |
| `SCAN 0 MATCH pattern COUNT 100` | Safe key iteration (use instead of KEYS) |
| `KEYS pattern` | Find keys (**NEVER use in prod on large DBs**) |
| `TTL keyname` | Remaining TTL of a key |
| `TYPE keyname` | Data type of a key |
| `FLUSHDB` | Delete all keys in current DB (**DANGEROUS**) |

---

### 7.2 Accessing Redis in Your Kubernetes Cluster

```bash
# Connect to master pod
kubectl exec -it redis-prod-master-0 -n prod -- redis-cli

# Check replication status (look for master_link_status:up)
kubectl exec -it redis-prod-master-0 -n prod -- redis-cli INFO replication

# Check memory usage
kubectl exec -it redis-prod-master-0 -n prod -- redis-cli INFO memory

# Monitor live commands
kubectl exec -it redis-prod-master-0 -n prod -- redis-cli MONITOR
```

---

### 7.3 Key Metrics to Monitor

| Metric | What it means | Alert if |
|--------|--------------|----------|
| `used_memory` | RAM consumed by Redis | > 80% of maxmemory |
| `connected_clients` | Active client connections | Unexpectedly high |
| `instantaneous_ops_per_sec` | Commands/sec | Sudden spike or drop |
| `keyspace_hits` / `keyspace_misses` | Cache hit rate | Hit rate < 80% |
| `master_link_status` | Replica sync health | Not `up` |
| `rdb_last_bgsave_status` | Last snapshot status | Not `ok` |
| `evicted_keys` | Keys removed due to memory pressure | Any evictions |
| `rejected_connections` | Connections refused | Any rejections |

---

## 8. Best Practices

### 8.1 Key Naming

Use consistent namespacing: `object-type:id:field`

```
user:1001:session
order:9922:status
rate:192.168.1.1:minute
cache:product:4521
lock:payment:order123
```

- Avoid spaces and special characters
- Keep key names short but descriptive

### 8.2 Memory Management

- Always set `maxmemory` and an eviction policy (`allkeys-lru` recommended for cache)
- Set **TTLs on all cache keys** — never store cache data forever
- Use `SCAN` instead of `KEYS` in production — `KEYS` blocks the entire server
- Monitor memory usage; eviction silently drops data

### 8.3 Security

- Always require authentication (`requirepass` in config)
- Bind Redis to **internal network only** — never expose port 6379 to the internet
- Use **TLS** for Redis connections in production
- Disable dangerous commands in production: `FLUSHALL`, `CONFIG`, `DEBUG`

### 8.4 Performance

- Use **pipelining** to batch multiple commands in one round trip
- Use `MGET`/`MSET` for multiple key operations instead of individual `GET`/`SET`
- Avoid storing very large values (>1MB) — impacts memory and latency
- Use **connection pooling** in your app — don't open new connections per request

---

## 9. Redis vs Alternatives

| | Redis | Memcached | Database (PostgreSQL) | Kafka |
|--|-------|-----------|----------------------|-------|
| **Data Types** | Rich (8 types) | String only | Full SQL | Bytes (messages) |
| **Persistence** | Optional | No | Yes | Yes |
| **Pub/Sub** | Yes | No | No | Yes (primary use) |
| **Clustering** | Yes (native) | Yes | Yes | Yes |
| **Throughput** | 1M+ ops/sec | 1M+ ops/sec | 10K-100K/sec | 1M+ msgs/sec |
| **Best For** | Cache + more | Pure cache | Persistence needed | Event streaming |

---

## Your Stack Summary

> In your infrastructure, Redis (Bitnami Master-Replica) is used as:
> - **Celery broker** — `django-cron-*` and background worker pods push/pop tasks via Redis Lists
> - **Cache layer** — Django and FastAPI services cache query results with TTLs
>
> Current deployment: `redis-prod-master-0` (writes) + `redis-prod-replicas-0` (reads)
>
> For production-grade HA as load grows, consider adding **Redis Sentinel** for automatic failover, or migrating to **Redis Cluster** for horizontal write scalability.

---

*Internal Engineering Documentation*