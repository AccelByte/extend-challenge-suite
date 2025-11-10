# Capacity Planning Guide - M2

**Based on:** Performance Baseline Report (PERFORMANCE_BASELINE.md)
**Last Updated:** [FILL IN]

---

## Quick Reference

**Single instance capacity (1 CPU / 1 GB):**
- API: [FILL IN] RPS
- Events: [FILL IN] EPS
- Combined: [FILL IN] RPS + [FILL IN] EPS

---

## Deployment Scenarios

### Scenario 1: Small Game (<10,000 DAU)

**Expected Load:**
- 50-100 RPS
- 500-1,000 EPS
- Peak concurrent users: 500

**Recommended Configuration:**
- Backend Service: 1 CPU, 1 GB RAM
- Event Handler: 1 CPU, 1 GB RAM
- Database: 2 CPU, 4 GB RAM
- Connection pool: 50

**Reasoning:**
[Based on test results, explain why this configuration is sufficient]

**Monthly Cost Estimate:**
- AWS: ~$150/month
- GCP: ~$140/month
- Azure: ~$160/month

**Headroom:**
- Can handle [FILL IN]x expected peak load
- Recommended for games with [FILL IN] expected growth

---

### Scenario 2: Medium Game (100,000 DAU)

**Expected Load:**
- 500-1,000 RPS
- 5,000-10,000 EPS
- Peak concurrent users: 5,000

**Recommended Configuration:**
- Backend Service: 3 instances @ 2 CPU, 2 GB RAM each
- Event Handler: 2 instances @ 2 CPU, 2 GB RAM each
- Database: 4 CPU, 8 GB RAM (RDS/Cloud SQL)
- Connection pool: 150 (50 per backend instance)
- Load balancer: ALB/GLB

**Reasoning:**
[Based on test results, explain the scaling strategy]

**Monthly Cost Estimate:**
- AWS: ~$800/month
- GCP: ~$750/month
- Azure: ~$850/month

**Headroom:**
- Can handle [FILL IN]x expected peak load
- Auto-scaling recommended above [FILL IN] concurrent users

---

### Scenario 3: Large Game (1,000,000 DAU)

**Expected Load:**
- 2,000-5,000 RPS
- 20,000-50,000 EPS
- Peak concurrent users: 50,000

**Recommended Configuration:**
- Backend Service: 10 instances @ 2 CPU, 4 GB RAM each
- Event Handler: 5 instances @ 4 CPU, 4 GB RAM each
- Database: Aurora/Cloud SQL (4 instances, 8 CPU, 16 GB RAM each)
- Connection pool: 300 per instance
- Load balancer: ALB with auto-scaling
- Cache: Redis cluster (3 nodes, 2 GB each)

**Reasoning:**
[Based on test results, explain the multi-instance strategy]

**Monthly Cost Estimate:**
- AWS: ~$5,000/month
- GCP: ~$4,500/month
- Azure: ~$5,500/month

**Headroom:**
- Can handle [FILL IN]x expected peak load
- Auto-scaling triggers: CPU >70%, Connection pool >80%

---

## Scaling Decision Tree

```
Start: What's your expected peak RPS?

< 500 RPS
  └─> 1 instance (1 CPU, 1 GB)
      Expected capacity: [FILL IN] RPS + [FILL IN] EPS
      Cost: $150-200/month

500-1,000 RPS
  ├─> Option A: 1 instance (4 CPU, 4 GB)
  │   Cost: $400-500/month
  │   Use when: Simplicity preferred, single point ok
  │
  └─> Option B: 2-3 instances (2 CPU, 2 GB each)
      Cost: $400-600/month
      Use when: High availability required

1,000-5,000 RPS
  └─> 5-10 instances (2 CPU, 2 GB each) + load balancer
      Cost: $1,500-3,000/month
      Required: Auto-scaling, load balancer, shared cache

> 5,000 RPS
  └─> 10+ instances + auto-scaling + Redis cache + read replicas
      Cost: $5,000+/month
      Required: Full distributed architecture
```

---

## Cost-Performance Trade-offs

| Configuration | Monthly Cost | RPS Capacity | EPS Capacity | Reliability | Complexity |
|--------------|-------------|-------------|-------------|-------------|------------|
| 1×(1CPU,1GB) | $150        | [FILL]      | [FILL]      | Low         | Low        |
| 1×(4CPU,4GB) | $400        | [FILL]      | [FILL]      | Low         | Low        |
| 3×(2CPU,2GB) | $600        | [FILL]      | [FILL]      | High        | Medium     |
| 10×(2CPU,2GB)| $2,000      | [FILL]      | [FILL]      | Very High   | High       |

**Recommendation:**
[Based on test results, recommend vertical vs horizontal scaling]

---

## Scaling Strategies

### Vertical Scaling (Bigger Instances)

**Pros:**
- Simple to implement (no load balancer needed)
- Lower latency (no network hops)
- Easier to debug and monitor

**Cons:**
- Single point of failure
- Limited by maximum instance size
- No high availability

**When to use:**
- Small to medium load (<1,000 RPS)
- Development/staging environments
- When simplicity is more important than availability

**Expected scaling:**
- 1 CPU → 2 CPU: ~2x capacity ([FILL IN] RPS → [FILL IN] RPS)
- 2 CPU → 4 CPU: ~2x capacity ([FILL IN] RPS → [FILL IN] RPS)

---

### Horizontal Scaling (More Instances)

**Pros:**
- High availability (no single point of failure)
- Can scale beyond single instance limits
- Better resource utilization

**Cons:**
- Requires load balancer
- More complex deployment
- Higher operational overhead

**When to use:**
- Medium to large load (>1,000 RPS)
- Production environments requiring HA
- When reliability is critical

**Expected scaling:**
- Linear scaling up to [FILL IN] instances
- Efficiency factor: [FILL IN]% (e.g., 3 instances = 2.7x capacity)

---

## Database Scaling

### Connection Pool Sizing

**Formula:**
```
max_connections = (num_backend_instances × connections_per_instance) + buffer
```

**Current test results:**
- Single instance: 50 connections, saturated at [FILL IN] RPS
- Recommended per instance: [FILL IN] connections
- Buffer: 20% overhead

**Scaling recommendations:**
| Backend Instances | DB Connections | Database Size |
|------------------|----------------|---------------|
| 1                | 50             | 2 CPU, 4 GB   |
| 3                | 150            | 4 CPU, 8 GB   |
| 10               | 300            | 8 CPU, 16 GB  |

---

### Read Replicas

**When to add read replicas:**
- Read:Write ratio > 80:20
- Database CPU > 70%
- Read query latency > 50ms

**Expected benefit:**
- 1 read replica: [FILL IN]% reduction in primary load
- 2 read replicas: [FILL IN]% reduction in primary load

**Note:** Challenge service is write-heavy (progress updates), so read replicas provide limited benefit

---

## Cache Strategy

### When to add Redis cache

**Recommended when:**
- API RPS > [FILL IN]
- Database connection pool saturation
- Repeated reads of same challenges

**Expected benefit:**
- Cache hit rate: [FILL IN]% (estimated)
- Response time reduction: [FILL IN]% for cached requests
- Database load reduction: [FILL IN]%

**Configuration:**
- Small deployment: 1 Redis instance (1 GB)
- Medium deployment: Redis cluster (3 nodes, 2 GB each)
- Large deployment: Redis cluster (5 nodes, 4 GB each)

---

## Auto-Scaling Configuration

### Trigger Metrics

**Scale UP when:**
- CPU utilization > 70% for 5 minutes
- Connection pool > 80% for 3 minutes
- API p95 latency > 500ms for 2 minutes

**Scale DOWN when:**
- CPU utilization < 30% for 10 minutes
- Connection pool < 40% for 10 minutes
- Minimum instances: [FILL IN]

### Scaling Limits

**Backend Service:**
- Minimum instances: [FILL IN]
- Maximum instances: [FILL IN]
- Cooldown period: 5 minutes

**Event Handler:**
- Minimum instances: [FILL IN]
- Maximum instances: [FILL IN]
- Cooldown period: 3 minutes

---

## Regional Deployment

### Single Region

**Use when:**
- All users in one geographic region
- Latency not critical (<200ms acceptable)
- Simpler operations preferred

**Cost:** [FILL IN]% baseline

---

### Multi-Region Active-Passive

**Use when:**
- Users distributed globally
- High availability required
- Budget for 2x infrastructure

**Configuration:**
- Primary region: Full deployment
- Secondary region: Standby (smaller)
- Database replication: Async (lag <5s)

**Cost:** [FILL IN]% baseline (1.5-2x)

---

### Multi-Region Active-Active

**Use when:**
- Users distributed globally
- Low latency critical (<100ms)
- Budget for 3x infrastructure

**Configuration:**
- Multiple regions: Full deployment each
- Database: Multi-region writes
- Challenge: Eventual consistency handling

**Cost:** [FILL IN]% baseline (3x+)

---

## Monitoring and Alerts

### Key Metrics to Monitor

1. **API Response Time**
   - Alert threshold: p95 > 500ms
   - Action: Scale up backend

2. **Event Processing Time**
   - Alert threshold: p95 > 200ms
   - Action: Scale up event handler

3. **Database Connection Pool**
   - Alert threshold: >80% utilization
   - Action: Increase pool size or scale DB

4. **CPU Utilization**
   - Alert threshold: >70% for 5 minutes
   - Action: Scale up instances

5. **Error Rate**
   - Alert threshold: >1% errors
   - Action: Investigate immediately

---

## Cost Optimization

### Tips for Reducing Costs

1. **Use Reserved Instances**
   - Save 30-50% vs on-demand
   - Commit to 1-year term for production

2. **Right-size Instances**
   - Monitor actual usage vs allocated
   - Downsize if consistently <50% utilization

3. **Use Spot Instances (if applicable)**
   - For event handlers (stateless)
   - Save 60-70% vs on-demand
   - Not recommended for backend API

4. **Database Optimization**
   - Tune connection pool (don't over-allocate)
   - Use appropriate instance size
   - Consider Aurora Serverless for variable load

---

## Summary Table

| Game Size | DAU      | RPS   | EPS    | Instances | Cost/Month |
|-----------|----------|-------|--------|-----------|------------|
| Small     | <10K     | 100   | 1K     | 1-2       | $150-300   |
| Medium    | 100K     | 1K    | 10K    | 5-7       | $800-1.2K  |
| Large     | 1M       | 5K    | 50K    | 15-20     | $5K-7K     |

---

**Document Status:** Template - Fill in with test results
