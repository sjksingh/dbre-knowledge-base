# Parameters That Actually Speed Up VACUUM ANALYZE

## 1. Overview

These are the parameters and table settings that directly impact the
speed and effectiveness of `VACUUM` and `VACUUM ANALYZE`.

------------------------------------------------------------------------

## 2. Key Autovacuum Parameters

### **autovacuum_vacuum_cost_limit**

-   Higher limit → vacuum runs faster\
-   Default is too low for large tables\
-   Recommended: **3000--8000**

### **autovacuum_vacuum_cost_delay**

-   Lower delay → vacuum runs more aggressively\
-   Recommended: **1 ms**

### **autovacuum_vacuum_scale_factor**

-   Controls when vacuum triggers\
-   Default: **0.2 (20%)**, terrible for large tables\
-   Recommended: **0.01** for multi-GB tables

### **autovacuum_vacuum_threshold**

-   Minimum dead rows before vacuum starts\
-   Recommended: **1000**

------------------------------------------------------------------------

## 3. ANALYZE Parameters (Very Important for Query Plans)

### **autovacuum_analyze_threshold**

-   Default is **50K** --- OK for small tables\
-   Not OK for large ones\
-   Your table had `1,000,000` which is too high\
-   Recommended: **10,000**

### **autovacuum_analyze_scale_factor**

-   Default: **0.1 (10%)**\
-   Too high for large tables\
-   Recommended: **0.01**

------------------------------------------------------------------------

## 4. Fillfactor Considerations

Your table:

    avd.issue_types
    Size: 74 GB
    Dead rows: 110k
    Dead_pct ≈ 0%

This table is not update-heavy.

### fillfactor = 80

This wastes 20% of every page. Not needed.

### Recommended:

    fillfactor = 100

------------------------------------------------------------------------

## 5. DBRE Recommended Final Settings

``` sql
ALTER TABLE avd.issue_types SET (
    fillfactor = 100,
    autovacuum_enabled = true,
    autovacuum_vacuum_threshold = 1000,
    autovacuum_vacuum_scale_factor = 0.01,
    autovacuum_vacuum_cost_delay = 1,
    autovacuum_vacuum_cost_limit = 5000,
    autovacuum_analyze_threshold = 10000,
    autovacuum_analyze_scale_factor = 0.01
);
```

------------------------------------------------------------------------

## 6. Why These Changes Matter

-   Faster vacuum cycles\
-   More frequent ANALYZE → better query plans\
-   Less table bloat\
-   Lower storage and IO load\
-   Better cache hit ratios\
-   Reduced vacuum lag

------------------------------------------------------------------------

## 7. Optional Enhancements

I can also generate for you:

-   A `dbre_autovacuum_health` view\
-   A bloat detection view\
-   A tracking dashboard for vacuum/ANALYZE events
