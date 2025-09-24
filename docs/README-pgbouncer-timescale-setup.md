# PGBouncer Setup for TimescaleDB on EKS with Read/Write Routing

This guide provides a comprehensive setup for adding PGBouncer to an existing TimescaleDB deployment on Amazon EKS without downtime, including read/write routing to secondary replicas.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [Configuration Files](#configuration-files)
- [Deployment Steps](#deployment-steps)
- [Application Integration](#application-integration)
- [Monitoring and Troubleshooting](#monitoring-and-troubleshooting)
- [Maintenance](#maintenance)

## Overview

This setup provides:
- **Zero-downtime deployment** of PGBouncer alongside existing TimescaleDB
- **Read/write routing** to distribute load across primary and replica nodes
- **Connection pooling** to optimize database connections
- **High availability** with multiple PGBouncer instances
- **Load balancing** across read replicas

## Prerequisites

- Existing TimescaleDB deployment on EKS
- TimescaleDB with configured read replicas
- kubectl access to your EKS cluster
- Basic understanding of Kubernetes manifests

## Architecture

```
Application Layer
       ↓
┌─────────────────┐    ┌─────────────────┐
│  PGBouncer      │    │  PGBouncer      │
│  (Write Pool)   │    │  (Read Pool)    │
└─────────────────┘    └─────────────────┘
       ↓                        ↓
┌─────────────────┐    ┌─────────────────┐
│  TimescaleDB    │    │  TimescaleDB    │
│  Primary        │    │  Read Replicas  │
└─────────────────┘    └─────────────────┘
```

## Quick Start

1. Clone this repository and navigate to the project directory
2. Update the configuration files with your specific values
3. Deploy the configurations in order:
   ```bash
   kubectl apply -f 01-configmaps.yaml
   kubectl apply -f 02-pgbouncer-deployments.yaml
   kubectl apply -f 03-services.yaml
   kubectl apply -f 04-monitoring.yaml
   ```
4. Update your applications to use the new connection endpoints
5. Verify the setup and monitor performance

## Configuration Files

### 1. ConfigMaps (`01-configmaps.yaml`)

#### PGBouncer Write Configuration
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: pgbouncer-write-config
  namespace: your-timescale-namespace
data:
  pgbouncer.ini: |
    [databases]
    # Primary for writes
    * = host=timescale-primary-service port=5432 pool_size=25
    
    [pgbouncer]
    listen_port = 5432
    listen_addr = 0.0.0.0
    auth_type = md5
    auth_file = /etc/pgbouncer/userlist.txt
    pool_mode = transaction
    max_client_conn = 1000
    default_pool_size = 25
    server_lifetime = 3600
    server_idle_timeout = 600
    log_connections = 1
    log_disconnections = 1
    
  userlist.txt: |
    "your_username" "md5_hashed_password"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: pgbouncer-read-config
  namespace: your-timescale-namespace
data:
  pgbouncer.ini: |
    [databases]
    # Read replicas with round-robin load balancing
    * = host=timescale-replica-1-service,timescale-replica-2-service port=5432 pool_size=30
    
    [pgbouncer]
    listen_port = 5432
    listen_addr = 0.0.0.0
    auth_type = md5
    auth_file = /etc/pgbouncer/userlist.txt
    pool_mode = transaction
    max_client_conn = 1500
    default_pool_size = 30
    server_round_robin = 1
    server_lifetime = 3600
    server_idle_timeout = 600
    log_connections = 1
    log_disconnections = 1
    
  userlist.txt: |
    "your_username" "md5_hashed_password"
```

#### Application Database Configuration
```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-database-config
  namespace: your-timescale-namespace
data:
  # Write operations
  DATABASE_WRITE_HOST: "pgbouncer-write-service"
  DATABASE_WRITE_PORT: "5432"
  
  # Read operations  
  DATABASE_READ_HOST: "pgbouncer-read-service"
  DATABASE_READ_PORT: "5432"
  
  # Fallback to write for critical reads
  DATABASE_FALLBACK_HOST: "pgbouncer-write-service"
  DATABASE_FALLBACK_PORT: "5432"
  
  # Database credentials (reference existing secrets)
  DATABASE_NAME: "your_database"
  DATABASE_USER: "your_username"
```

### 2. PGBouncer Deployments (`02-pgbouncer-deployments.yaml`)

#### Write Pool Deployment
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pgbouncer-write
  namespace: your-timescale-namespace
  labels:
    app: pgbouncer-write
    component: database-proxy
spec:
  replicas: 2
  selector:
    matchLabels:
      app: pgbouncer-write
  template:
    metadata:
      labels:
        app: pgbouncer-write
        role: write
    spec:
      containers:
      - name: pgbouncer
        image: pgbouncer/pgbouncer:1.17.0
        ports:
        - containerPort: 5432
          name: postgres
        env:
        - name: DATABASES_HOST
          value: "timescale-primary-service"
        - name: DATABASES_PORT
          value: "5432"
        - name: POOL_MODE
          value: "transaction"
        - name: MAX_CLIENT_CONN
          value: "1000"
        - name: DEFAULT_POOL_SIZE
          value: "25"
        volumeMounts:
        - name: pgbouncer-write-config
          mountPath: /etc/pgbouncer
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          tcpSocket:
            port: 5432
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          tcpSocket:
            port: 5432
          initialDelaySeconds: 5
          periodSeconds: 5
      volumes:
      - name: pgbouncer-write-config
        configMap:
          name: pgbouncer-write-config
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pgbouncer-read
  namespace: your-timescale-namespace
  labels:
    app: pgbouncer-read
    component: database-proxy
spec:
  replicas: 3
  selector:
    matchLabels:
      app: pgbouncer-read
  template:
    metadata:
      labels:
        app: pgbouncer-read
        role: read
    spec:
      containers:
      - name: pgbouncer
        image: pgbouncer/pgbouncer:1.17.0
        ports:
        - containerPort: 5432
          name: postgres
        env:
        - name: DATABASES_HOST
          value: "timescale-replica-service"
        - name: DATABASES_PORT
          value: "5432"
        - name: POOL_MODE
          value: "transaction"
        - name: MAX_CLIENT_CONN
          value: "1500"
        - name: DEFAULT_POOL_SIZE
          value: "30"
        volumeMounts:
        - name: pgbouncer-read-config
          mountPath: /etc/pgbouncer
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          tcpSocket:
            port: 5432
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          tcpSocket:
            port: 5432
          initialDelaySeconds: 5
          periodSeconds: 5
      volumes:
      - name: pgbouncer-read-config
        configMap:
          name: pgbouncer-read-config
```

### 3. Services (`03-services.yaml`)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: pgbouncer-write-service
  namespace: your-timescale-namespace
  labels:
    app: pgbouncer-write
    component: database-proxy
spec:
  selector:
    app: pgbouncer-write
  ports:
  - port: 5432
    targetPort: 5432
    name: postgres
  type: ClusterIP
---
apiVersion: v1
kind: Service
metadata:
  name: pgbouncer-read-service
  namespace: your-timescale-namespace
  labels:
    app: pgbouncer-read
    component: database-proxy
spec:
  selector:
    app: pgbouncer-read
  ports:
  - port: 5432
    targetPort: 5432
    name: postgres
  type: ClusterIP
  sessionAffinity: None
```

### 4. Monitoring Setup (`04-monitoring.yaml`)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: pgbouncer-metrics
  namespace: your-timescale-namespace
  labels:
    app: pgbouncer
    component: monitoring
spec:
  ports:
  - port: 9127
    name: metrics
    targetPort: 9127
  selector:
    app: pgbouncer-exporter
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pgbouncer-exporter
  namespace: your-timescale-namespace
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pgbouncer-exporter
  template:
    metadata:
      labels:
        app: pgbouncer-exporter
    spec:
      containers:
      - name: pgbouncer-exporter
        image: spreaker/prometheus-pgbouncer-exporter:latest
        ports:
        - containerPort: 9127
          name: metrics
        env:
        - name: PGBOUNCER_EXPORTER_HOST
          value: "pgbouncer-write-service"
        - name: PGBOUNCER_EXPORTER_PORT
          value: "5432"
        - name: PGBOUNCER_EXPORTER_DATABASE
          value: "pgbouncer"
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "100m"
```

## Deployment Steps

### Step 1: Prepare Configuration

1. **Update namespace and service names** in all YAML files:
   ```bash
   # Replace placeholder values
   sed -i 's/your-timescale-namespace/production/g' *.yaml
   sed -i 's/timescale-primary-service/your-primary-service-name/g' *.yaml
   sed -i 's/timescale-replica-1-service/your-replica-1-service/g' *.yaml
   sed -i 's/timescale-replica-2-service/your-replica-2-service/g' *.yaml
   ```

2. **Generate password hash** for userlist.txt:
   ```bash
   # Generate MD5 hash for password
   echo -n "passwordusername" | md5sum
   # Replace "md5_hashed_password" with md5 + the hash
   ```

### Step 2: Deploy PGBouncer

1. **Deploy ConfigMaps**:
   ```bash
   kubectl apply -f 01-configmaps.yaml
   ```

2. **Deploy PGBouncer instances**:
   ```bash
   kubectl apply -f 02-pgbouncer-deployments.yaml
   ```

3. **Deploy Services**:
   ```bash
   kubectl apply -f 03-services.yaml
   ```

4. **Deploy Monitoring**:
   ```bash
   kubectl apply -f 04-monitoring.yaml
   ```

### Step 3: Verify Deployment

```bash
# Check pod status
kubectl get pods -l component=database-proxy -n your-timescale-namespace

# Check services
kubectl get services -l component=database-proxy -n your-timescale-namespace

# Test connectivity
kubectl run -it --rm debug --image=postgres:13 --restart=Never -- \
  psql -h pgbouncer-write-service -p 5432 -U your_username -d your_database
```

### Step 4: Gradual Migration

1. **Update one application deployment** to test:
   ```yaml
   spec:
     template:
       spec:
         containers:
         - name: your-app
           env:
           - name: DATABASE_WRITE_URL
             value: "postgresql://user:pass@pgbouncer-write-service:5432/db"
           - name: DATABASE_READ_URL
             value: "postgresql://user:pass@pgbouncer-read-service:5432/db"
   ```

2. **Monitor application logs** and database performance

3. **Gradually update remaining applications**

## Application Integration

### Node.js Example

```javascript
const { Pool } = require('pg');

// Write pool configuration
const writePool = new Pool({
  host: process.env.DATABASE_WRITE_HOST || 'pgbouncer-write-service',
  port: process.env.DATABASE_WRITE_PORT || 5432,
  database: process.env.DATABASE_NAME,
  user: process.env.DATABASE_USER,
  password: process.env.DATABASE_PASSWORD,
  max: 20,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 2000,
});

// Read pool configuration
const readPool = new Pool({
  host: process.env.DATABASE_READ_HOST || 'pgbouncer-read-service',
  port: process.env.DATABASE_READ_PORT || 5432,
  database: process.env.DATABASE_NAME,
  user: process.env.DATABASE_USER,
  password: process.env.DATABASE_PASSWORD,
  max: 30,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 2000,
});

// Database operations
class DatabaseService {
  // Write operations
  async createUser(userData) {
    const query = 'INSERT INTO users (name, email) VALUES ($1, $2) RETURNING *';
    return await writePool.query(query, [userData.name, userData.email]);
  }

  async updateUser(id, userData) {
    const query = 'UPDATE users SET name = $1, email = $2 WHERE id = $3 RETURNING *';
    return await writePool.query(query, [userData.name, userData.email, id]);
  }

  // Read operations
  async getUser(id) {
    const query = 'SELECT * FROM users WHERE id = $1';
    return await readPool.query(query, [id]);
  }

  async getUsers(limit = 100) {
    const query = 'SELECT * FROM users LIMIT $1';
    return await readPool.query(query, [limit]);
  }

  // Critical reads that need consistency
  async getUserForAuth(email) {
    const query = 'SELECT * FROM users WHERE email = $1';
    return await writePool.query(query, [email]); // Use write pool for consistency
  }
}

module.exports = new DatabaseService();
```

### Python Example

```python
import psycopg2
from psycopg2 import pool
import os

class DatabaseManager:
    def __init__(self):
        # Write pool
        self.write_pool = psycopg2.pool.ThreadedConnectionPool(
            minconn=5,
            maxconn=20,
            host=os.getenv('DATABASE_WRITE_HOST', 'pgbouncer-write-service'),
            port=os.getenv('DATABASE_WRITE_PORT', 5432),
            database=os.getenv('DATABASE_NAME'),
            user=os.getenv('DATABASE_USER'),
            password=os.getenv('DATABASE_PASSWORD')
        )
        
        # Read pool
        self.read_pool = psycopg2.pool.ThreadedConnectionPool(
            minconn=10,
            maxconn=30,
            host=os.getenv('DATABASE_READ_HOST', 'pgbouncer-read-service'),
            port=os.getenv('DATABASE_READ_PORT', 5432),
            database=os.getenv('DATABASE_NAME'),
            user=os.getenv('DATABASE_USER'),
            password=os.getenv('DATABASE_PASSWORD')
        )
    
    def execute_write(self, query, params=None):
        conn = self.write_pool.getconn()
        try:
            with conn.cursor() as cursor:
                cursor.execute(query, params)
                conn.commit()
                return cursor.fetchall()
        finally:
            self.write_pool.putconn(conn)
    
    def execute_read(self, query, params=None):
        conn = self.read_pool.getconn()
        try:
            with conn.cursor() as cursor:
                cursor.execute(query, params)
                return cursor.fetchall()
        finally:
            self.read_pool.putconn(conn)

# Usage
db = DatabaseManager()

# Write operation
db.execute_write("INSERT INTO users (name, email) VALUES (%s, %s)", ("John", "john@example.com"))

# Read operation
users = db.execute_read("SELECT * FROM users WHERE active = %s", (True,))
```

### Java Spring Boot Example

```java
@Configuration
public class DatabaseConfig {
    
    @Bean
    @Primary
    @ConfigurationProperties("spring.datasource.write")
    public DataSource writeDataSource() {
        return DataSourceBuilder.create().build();
    }
    
    @Bean
    @ConfigurationProperties("spring.datasource.read")
    public DataSource readDataSource() {
        return DataSourceBuilder.create().build();
    }
    
    @Bean
    @Primary
    public JdbcTemplate writeJdbcTemplate(@Qualifier("writeDataSource") DataSource dataSource) {
        return new JdbcTemplate(dataSource);
    }
    
    @Bean
    public JdbcTemplate readJdbcTemplate(@Qualifier("readDataSource") DataSource dataSource) {
        return new JdbcTemplate(dataSource);
    }
}

@Service
public class UserService {
    
    @Autowired
    @Qualifier("writeJdbcTemplate")
    private JdbcTemplate writeJdbcTemplate;
    
    @Autowired
    @Qualifier("readJdbcTemplate")
    private JdbcTemplate readJdbcTemplate;
    
    public User createUser(User user) {
        String sql = "INSERT INTO users (name, email) VALUES (?, ?) RETURNING *";
        return writeJdbcTemplate.queryForObject(sql, new UserRowMapper(), user.getName(), user.getEmail());
    }
    
    public List<User> getUsers() {
        String sql = "SELECT * FROM users";
        return readJdbcTemplate.query(sql, new UserRowMapper());
    }
}
```

## Monitoring and Troubleshooting

### Key Metrics to Monitor

1. **Connection Pool Metrics**:
   ```bash
   # Connect to PGBouncer admin interface
   psql -h pgbouncer-write-service -p 5432 -U postgres pgbouncer
   
   # Check pool status
   SHOW POOLS;
   SHOW CLIENTS;
   SHOW SERVERS;
   SHOW STATS;
   ```

2. **Prometheus Metrics** (if using the exporter):
   - `pgbouncer_pools_client_active_connections`
   - `pgbouncer_pools_server_active_connections`
   - `pgbouncer_stats_queries_per_second`
   - `pgbouncer_stats_bytes_received_per_second`

### Common Issues and Solutions

#### Connection Refused
```bash
# Check pod status
kubectl get pods -l app=pgbouncer-write -n your-namespace

# Check logs
kubectl logs -l app=pgbouncer-write -n your-namespace

# Check service endpoints
kubectl get endpoints pgbouncer-write-service -n your-namespace
```

#### Authentication Failures
```bash
# Verify userlist.txt configuration
kubectl describe configmap pgbouncer-write-config -n your-namespace

# Test MD5 hash generation
echo -n "passwordusername" | md5sum
```

#### High Connection Count
```bash
# Check current connections
kubectl exec -it <pgbouncer-pod> -- psql -h localhost -p 5432 -U postgres pgbouncer -c "SHOW CLIENTS;"

# Adjust pool settings in configmap
kubectl edit configmap pgbouncer-write-config -n your-namespace
```

### Performance Tuning

#### PGBouncer Configuration Tuning
```ini
# For high-throughput applications
max_client_conn = 2000
default_pool_size = 50
reserve_pool_size = 10
reserve_pool_timeout = 5

# For transaction-heavy workloads
pool_mode = transaction
server_reset_query = DISCARD ALL

# For session-heavy workloads
pool_mode = session
server_reset_query = 
```

#### Resource Optimization
```yaml
# Adjust based on your workload
resources:
  requests:
    memory: "512Mi"
    cpu: "300m"
  limits:
    memory: "1Gi"
    cpu: "800m"
```

### Health Checks

#### Manual Health Check Script
```bash
#!/bin/bash
# healthcheck.sh

WRITE_HOST="pgbouncer-write-service"
READ_HOST="pgbouncer-read-service"
DB_USER="your_username"
DB_NAME="your_database"

echo "Testing write connection..."
if psql -h $WRITE_HOST -U $DB_USER -d $DB_NAME -c "SELECT 1;" > /dev/null 2>&1; then
    echo "✓ Write connection OK"
else
    echo "✗ Write connection FAILED"
    exit 1
fi

echo "Testing read connection..."
if psql -h $READ_HOST -U $DB_USER -d $DB_NAME -c "SELECT 1;" > /dev/null 2>&1; then
    echo "✓ Read connection OK"
else
    echo "✗ Read connection FAILED"
    exit 1
fi

echo "All health checks passed!"
```

#### Kubernetes Health Check
```yaml
# Add to your application deployment
livenessProbe:
  exec:
    command:
    - /bin/sh
    - -c
    - |
      psql -h pgbouncer-write-service -U $DB_USER -d $DB_NAME -c "SELECT 1;" &&
      psql -h pgbouncer-read-service -U $DB_USER -d $DB_NAME -c "SELECT 1;"
  initialDelaySeconds: 30
  periodSeconds: 60
```

## Maintenance

### Updating PGBouncer Configuration

1. **Update ConfigMap**:
   ```bash
   kubectl edit configmap pgbouncer-write-config -n your-namespace
   ```

2. **Restart pods** to pick up new configuration:
   ```bash
   kubectl rollout restart deployment pgbouncer-write -n your-namespace
   kubectl rollout restart deployment pgbouncer-read -n your-namespace
   ```

### Scaling PGBouncer

```bash
# Scale read instances based on load
kubectl scale deployment pgbouncer-read --replicas=5 -n your-namespace

# Scale write instances (usually 2-3 is sufficient)
kubectl scale deployment pgbouncer-write --replicas=3 -n your-namespace
```

### Backup and Restore Configuration

```bash
# Backup current configuration
kubectl get configmap pgbouncer-write-config -o yaml > backup-write-config.yaml
kubectl get configmap pgbouncer-read-config -o yaml > backup-read-config.yaml

# Restore configuration
kubectl apply -f backup-write-config.yaml
kubectl apply -f backup-read-config.yaml
```

### Rolling Updates

```bash
# Update PGBouncer image version
kubectl set image deployment/pgbouncer-write pgbouncer=pgbouncer/pgbouncer:1.18.0 -n your-namespace
kubectl set image deployment/pgbouncer-read pgbouncer=pgbouncer/pgbouncer:1.18.0 -n your-namespace

# Monitor rollout
kubectl rollout status deployment/pgbouncer-write -n your-namespace
kubectl rollout status deployment/pgbouncer-read -n your-namespace
```

## Security Considerations

1. **Use Kubernetes Secrets** for database credentials instead of ConfigMaps
2. **Enable TLS** between PGBouncer and TimescaleDB
3. **Implement network policies** to restrict access
4. **Regular security updates** for PGBouncer images
5. **Monitor access logs** for suspicious activity

## Performance Benchmarks

Before implementing, establish baseline metrics:
- Connection count
- Query response times
- Database CPU/Memory usage
- Application throughput

After implementation, expect:
- Reduced connection overhead on database
- Improved connection reuse
- Better resource utilization
- Faster failover for read operations

## Support and Contributing

For issues and questions:
1. Check the troubleshooting section
2. Review PGBouncer documentation
3. Examine Kubernetes logs
4. Monitor database performance metrics

---

**Note**: Replace all placeholder values (namespace, service names, credentials) with your actual environment values before deployment.
