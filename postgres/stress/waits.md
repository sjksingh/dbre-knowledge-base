# 🛠 PostgreSQL Wait Events Cheat Sheet — 

| Wait Type (`wait_event_type`) | Event (`wait_event`) | Meaning | Priority | Suggested Fix |
|-------------------------------|--------------------|---------|---------|---------------|
| **IPC** | BufferIO | Backend waiting on shared buffer pool pages. Often due to many sessions scanning the same table. | High | - Limit concurrent heavy scans (~10 sessions)<br>- Add indexes (partial/covering)<br>- Use materialized views<br>- Partition large tables<br>- Tune `shared_buffers` |
| **IO** | DataFileRead | Backend waiting for disk reads because pages are not in memory. | High | - Avoid repeated full table scans<br>- Add supporting indexes<br>- Materialize frequent queries<br>- Use faster storage (SSD) |
| **LWLock** | BufferMapping | Lightweight lock on buffer mapping structures. Triggered by high concurrency on buffer pool. | High | - Reduce concurrent scans<br>- Add indexes / materialized views<br>- Partition tables<br>- Monitor buffer usage (`shared_buffers`) |
| **IO** | DataFileWrite | Waiting for disk writes (WAL, heap updates, temp writes). | Medium | - Reduce concurrent batch updates<br>- Use UNLOGGED tables for bulk load<br>- Tune `wal_buffers`, `checkpoint_timeout`, `max_wal_size` |
| **Lock** | relation / tuple / transaction | Waiting for row/table-level locks held by other transactions. | High | - Identify blocking queries (`pg_locks`, `pg_stat_activity`)<br>- Shorten transaction duration<br>- Use lower isolation levels where safe<br>- Optimize query patterns |
| **IO** | DataFileReadTemp | Reading temp files due to disk-based sort, join, or hash operations. | Medium | - Increase `work_mem` to reduce spills<br>- Optimize queries (smaller sorts / joins)<br>- Monitor long-running queries |
| **IPC** | ProcArray | Waiting on process array lock, often for transaction visibility / XID assignment. | Medium | - Avoid long-running transactions<br>- Prevent idle-in-transaction sessions<br>- Regular vacuum to free old XIDs |

---

### 🔹 Notes for Staff DBRE

- Priority **High** = major performance impact, tune immediately  
- Priority **Medium** = moderate impact, monitor and optimize  
- Always correlate `sample_queries` with waits for **targeted fixes**  
- Combine this table with `dbre_active_waits` or `dbre_waits_monitor` views for **live analysis**
